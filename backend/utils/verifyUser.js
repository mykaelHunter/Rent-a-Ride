import jwt from "jsonwebtoken";
import { errorHandler } from "./error.js";
import User from "../models/userModel.js";

// Accepts either the app's "Bearer <refresh>,<access>" header format or a
// standard "Bearer <token>" header (treated as an access token). Never
// throws on a missing/malformed header - callers just get {refreshToken:
// undefined, accessToken: undefined} and fall through to the 401 path.
const parseAuthHeader = (req) => {
  const header = req.headers.authorization;
  if (!header || !header.startsWith("Bearer ")) {
    return { refreshToken: undefined, accessToken: undefined };
  }
  const value = header.slice("Bearer ".length).trim();
  if (value.includes(",")) {
    const [refreshToken, accessToken] = value.split(",");
    return { refreshToken: refreshToken || undefined, accessToken: accessToken || undefined };
  }
  // Standard single-token header: treat it as an access token.
  return { refreshToken: undefined, accessToken: value || undefined };
};

// Issues a fresh access/refresh token pair for a user, persists the new
// refresh token, and attaches req.user (the full decoded id) before calling
// next(). Shared by both the "no access token" and "expired access token"
// paths so refresh logic isn't duplicated.
const refreshAndProceed = async (refreshToken, req, res, next) => {
  const decoded = jwt.verify(refreshToken, process.env.REFRESH_TOKEN);
  const user = await User.findById(decoded.id);

  if (!user) return next(errorHandler(403, "Invalid refresh token"));
  if (user.refreshToken !== refreshToken) {
    return next(errorHandler(403, "Invalid refresh token"));
  }

  const newAccessToken = jwt.sign({ id: user._id }, process.env.ACCESS_TOKEN, {
    expiresIn: "15m",
  });
  const newRefreshToken = jwt.sign({ id: user._id }, process.env.REFRESH_TOKEN, {
    expiresIn: "7d",
  });

  await User.updateOne({ _id: user._id }, { refreshToken: newRefreshToken });

  res.set("x-access-token", newAccessToken);
  res.set("x-refresh-token", newRefreshToken);

  req.user = decoded.id;
  req.userDoc = user;
  next();
};

export const verifyToken = async (req, res, next) => {
  const { refreshToken, accessToken } = parseAuthHeader(req);

  if (!accessToken) {
    if (!refreshToken) {
      return next(errorHandler(401, "You are not authenticated"));
    }
    try {
      await refreshAndProceed(refreshToken, req, res, next);
    } catch (error) {
      return next(errorHandler(403, "Invalid refresh token"));
    }
    return;
  }

  try {
    const decoded = jwt.verify(accessToken, process.env.ACCESS_TOKEN);
    req.user = decoded.id; //setting req.user so that next middleware in this cycle can acess it
    return next();
  } catch (error) {
    if (error.name !== "TokenExpiredError") {
      return next(errorHandler(403, "Token is not valid"));
    }
    // Access token expired - fall back to the refresh token instead of
    // hanging the request with no response (INC-004).
    if (!refreshToken) {
      return next(errorHandler(401, "You are not authenticated"));
    }
    try {
      await refreshAndProceed(refreshToken, req, res, next);
    } catch (refreshError) {
      return next(errorHandler(403, "Invalid refresh token"));
    }
  }
};

// Loads the authenticated user and requires isAdmin === true. Must run
// after verifyToken, which sets req.user to the decoded user id.
export const requireAdmin = async (req, res, next) => {
  try {
    const user = req.userDoc || (await User.findById(req.user));
    if (!user) return next(errorHandler(403, "Invalid user"));
    if (!user.isAdmin) {
      return next(errorHandler(403, "only access for admins"));
    }
    req.userDoc = user;
    next();
  } catch (error) {
    next(error);
  }
};
