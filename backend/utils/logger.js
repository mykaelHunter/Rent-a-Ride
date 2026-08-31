import pino from "pino";

// Structured JSON logs to stdout. Docker's log driver (see
// docker-compose.yml) captures stdout/stderr directly, so there's no file
// path to manage inside the (read-only, non-root) container - `pino`'s
// default transport is exactly this: write JSON lines to stdout.
//
// Level is configurable via LOG_LEVEL (falls back to "debug" outside
// production, "info" in production) so verbosity can be turned up for
// troubleshooting without a code change or rebuild.
const logger = pino({
  level: process.env.LOG_LEVEL || (process.env.NODE_ENV === "production" ? "info" : "debug"),
  timestamp: pino.stdTimeFunctions.isoTime,
  redact: {
    // Never let a logged request/error accidentally leak credentials.
    paths: [
      "req.headers.authorization",
      "req.headers.cookie",
      "*.password",
      "*.hashedPassword",
      "*.token",
      "*.accessToken",
      "*.refreshToken",
    ],
    censor: "[redacted]",
  },
});

export default logger;
