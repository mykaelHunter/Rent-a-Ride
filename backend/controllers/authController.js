import User from "../models/userModel.js";
import bcryptjs from "bcryptjs";
import { errorHandler } from "../utils/error.js";
import Jwt from "jsonwebtoken";
import logger from "../utils/logger.js";

const expireDate = new Date(Date.now() + 3600000);

export const signUp = async (req, res, next) => {
  const { username, email, password } = req.body;

  // i put hashedPassword and newUser in try because if emty value comes the exicution dosenot stop

  try {
    const hashedPassword = bcryptjs.hashSync(password, 10);
    const newUser = new User({
      username,
      email,
      password: hashedPassword,
      isUser: true,
    });
    await newUser.save();
    res.status(200).json({ message: "newUser added successfully" });
  } catch (error) {
    next(error);
  }
};

//refreshTokens
export const refreshToken = async (req, res, next) => {
  // INC-005 fix: parse the auth header defensively instead of assuming
  // "Bearer <refresh>,<access>" is always present, which previously threw
  // if the header was missing or in a standard "Bearer <token>" form.
  const header = req.headers.authorization;
  if (!header || !header.startsWith("Bearer ")) {
    return next(errorHandler(403, "bad request no header provided"));
  }

  const value = header.slice("Bearer ".length).trim();
  const [refreshToken, accessToken] = value.includes(",")
    ? value.split(",")
    : [value, undefined];

  if (!refreshToken) {
    // res.clearCookie("access_token", "refresh_token");
    return next(errorHandler(401, "You are not authenticated"));
  }

  try {
    const decoded = Jwt.verify(refreshToken, process.env.REFRESH_TOKEN);
    const user = await User.findById(decoded.id);

    if (!user) return next(errorHandler(403, "Invalid refresh token"));
    if (user.refreshToken !== refreshToken) {
      // res.clearCookie("access_token", "refresh_token");
      return next(errorHandler(403, "Invalid refresh token"));
    }

    const newAccessToken = Jwt.sign(
      { id: user._id },
      process.env.ACCESS_TOKEN,
      { expiresIn: "15m" }
    );
    const newRefreshToken = Jwt.sign(
      { id: user._id },
      process.env.REFRESH_TOKEN,
      { expiresIn: "7d" }
    );

    // Update the refresh token in the database for the user
    await User.updateOne({ _id: user._id }, { refreshToken: newRefreshToken });

    res
      .cookie("access_token", newAccessToken, {
        httpOnly: true,
        maxAge: 900000,
        sameSite: "None",
        secure: true,
        domain: "rent-a-ride-two.vercel.app",
      }) // 15 minutes
      .cookie("refresh_token", newRefreshToken, {
        httpOnly: true,
        maxAge: 604800000,
        sameSite: "None",
        secure: true,
        domain: "rent-a-ride-two.vercel.app",
      }) // 7 days
      .status(200)
      .json({ accessToken: newAccessToken, refreshToken: newRefreshToken });
  } catch (error) {
    next(errorHandler(500, "error in refreshToken controller in server"));
  }
};

export const signIn = async (req, res, next) => {
  const { email, password } = req.body;
  try {
    const validUser = await User.findOne({ email });
    if (!validUser) return next(errorHandler(404, "user not found"));
    const validPassword = bcryptjs.compareSync(password, validUser.password);
    if (!validPassword) return next(errorHandler(401, "wrong credentials"));
    let accessToken = "";
    let refreshToken = "";
    accessToken = Jwt.sign({ id: validUser._id }, process.env.ACCESS_TOKEN, {
      expiresIn: "15m",
    }); //accessToken expires in 15 minutes
    refreshToken = Jwt.sign({ id: validUser._id }, process.env.REFRESH_TOKEN, {
      expiresIn: "7d",
    }); //refreshToken expires in 7 days

    const updatedData = await User.findByIdAndUpdate(
      { _id: validUser._id },
      { refreshToken },
      { new: true }
    ); //store the refresh token in db

    //separating password from the updatedData
    const { password: hashedPassword, isAdmin, ...rest } = updatedData._doc;

    //not sending users hashed password to frontend
    const responsePayload = {
      refreshToken: refreshToken,
      accessToken,
      isAdmin,
      ...rest,
    };

    req.user = {
      ...rest,
      isAdmin: validUser.isAdmin,
      isUser: validUser.isUser,
    };

    //the code for the cookie
    // .cookie("access_token", accessToken, {
    //   httpOnly: true,
    //   maxAge: 900000,
    //   sameSite: "None",
    //   secure: true,
    //   domain: "rent-a-ride-two.vercel.app"
    // }) // 15 minutes
    // .cookie("refresh_token", refreshToken, {
    //   httpOnly: true,
    //   maxAge: 604800000,
    //   sameSite: "None",
    //   secure: true,
    //   domain: "rent-a-ride-two.vercel.app"
    // })
    // 7 days

    res.status(200).json(responsePayload);

    next();
  } catch (error) {
    next(error);
    logger.error({ err: error });
  }
};

export const google = async (req, res, next) => {
  try {
    const user = await User.findOne({ email: req.body.email }).lean();
    if (user && !user.isUser) {
      return next(errorHandler(409, "email already in use as a vendor"));
    }
    if (user) {
      const { password: hashedPassword, ...rest } = user;
      const token = Jwt.sign({ id: user._id }, process.env.ACCESS_TOKEN);

      res
        .cookie("access_token", token, {
          httpOnly: true,
          expires: expireDate,
          SameSite: "None",
          Domain: ".vercel.app",
        })
        .status(200)
        .json(rest);
    } else {
      const generatedPassword =
        Math.random().toString(36).slice(-8) +
        Math.random().toString(36).slice(-8); //we are generating a random password since there is no password in result
      const hashedPassword = bcryptjs.hashSync(generatedPassword, 10);
      const newUser = new User({
        profilePicture: req.body.photo,
        password: hashedPassword,
        username:
          req.body.name.split(" ").join("").toLowerCase() +
          Math.random().toString(36).slice(-8) +
          Math.random().toString(36).slice(-8),
        email: req.body.email,
        isUser: true,
        //we cannot set username to req.body.name because other user may also have same name so we generate a random value and concat it to name
        //36 in toString(36) means random value from 0-9 and a-z
      });
      const savedUser = await newUser.save();
      const userObject = savedUser.toObject();

      const token = Jwt.sign({ id: newUser._id }, process.env.ACCESS_TOKEN);
      const { password: hashedPassword2, ...rest } = userObject;
      res
        .cookie("access_token", token, {
          httpOnly: true,
          expires: expireDate,
          sameSite: "None",
          secure: true,
          domain: ".vercel.app",
        })
        .status(200)
        .json(rest);
    }
  } catch (error) {
    next(error);
  }
};
