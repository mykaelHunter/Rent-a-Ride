import express from "express";
import mongoose from "mongoose";
import dotenv from "dotenv";
import userRoute from "./routes/userRoute.js";
import authRoute from "./routes/authRoute.js";
import adminRoute from './routes/adminRoute.js'
import vendorRoute from './routes/venderRoute.js'
import cors from 'cors'
import cookieParser from "cookie-parser";
import { cloudinaryConfig } from "./utils/cloudinaryConfig.js";

// INC-003 fix: dotenv must load before anything reads process.env below.
dotenv.config();

const App = express();

// INC-011 fix: configure Cloudinary once at startup instead of on every request.
cloudinaryConfig();

App.use(express.json());
App.use(cookieParser())

// INC-006 fix: bind to the platform-provided PORT when present, falling
// back to 3000 for local dev.
const port = process.env.PORT || 3000;

mongoose
  .connect(process.env.mongo_uri)
  .then(() => console.log("connected"))
  .catch((error) => console.error(error));

// INC-008 fix: allowed origins are configurable via env instead of a single
// hardcoded Vercel URL, so this can deploy to a different domain without a
// source change. Falls back to sensible local/prod defaults if unset.
const allowedOrigins = (process.env.ALLOWED_ORIGINS
  ? process.env.ALLOWED_ORIGINS.split(",").map((origin) => origin.trim())
  : ['https://rent-a-ride-two.vercel.app', 'http://localhost:5173']);

App.use(
  cors({
    origin: allowedOrigins,
    methods:['GET', 'PUT', 'POST' ,'PATCH','DELETE'],
    credentials: true, // Enables the Access-Control-Allow-Credentials header
  })
);

App.use("/api/user", userRoute);
App.use("/api/auth", authRoute);
App.use("/api/admin",adminRoute);
App.use("/api/vendor",vendorRoute)

// INC-022: lightweight, unauthenticated health endpoint for the container
// HEALTHCHECK (see backend/Dockerfile) and any orchestrator liveness probe.
// Reports Mongo connection state instead of just "process is alive", since
// a process that's up but can't reach the database isn't actually healthy.
App.get("/healthz", (req, res) => {
  const dbReady = mongoose.connection.readyState === 1; // 1 = connected
  res.status(dbReady ? 200 : 503).json({ status: dbReady ? "ok" : "degraded" });
});



App.use((err, req, res, next) => {
  const statusCode = err.statusCode || 500;
  const message = err.message || "internal server error";
  return res.status(statusCode).json({
    succes: false,
    message,
    statusCode,
  });
});

App.listen(port, () => {
  console.log(`server listening on port ${port} !`);
});
