import { v2 as cloudinary, uploader, config } from "cloudinary";

// INC-011 fix: plain init function called once at startup (see server.js)
// instead of a middleware re-run on every request. dotenv.config() is no
// longer called here - server.js already loads it before this module runs.
export const cloudinaryConfig = () => {
  config({
    cloud_name: process.env.CLOUD_NAME,
    api_key: process.env.API_KEY,
    api_secret: process.env.API_SECRET,
  });
};

export { uploader, cloudinary };
