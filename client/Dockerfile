
FROM node:24.19.0-alpine AS build
WORKDIR /app

RUN apk update && apk upgrade --no-cache

COPY package.json package-lock.json ./
RUN npm ci && npm cache clean --force

COPY . .

# Vite bakes VITE_* variables into the build at build time, so they must be
# passed as build args (docker-compose.yml does this from a root .env).
ARG VITE_PRODUCTION_BACKEND_URL
ARG VITE_FIREBASE_API_KEY
ARG VITE_RAZORPAY_KEY_ID
ENV VITE_PRODUCTION_BACKEND_URL=$VITE_PRODUCTION_BACKEND_URL
ENV VITE_FIREBASE_API_KEY=$VITE_FIREBASE_API_KEY
ENV VITE_RAZORPAY_KEY_ID=$VITE_RAZORPAY_KEY_ID

RUN npm run build

FROM nginxinc/nginx-unprivileged:1.30-alpine AS runtime

COPY --from=build --chown=nginx:nginx /app/dist /usr/share/nginx/html

COPY --chown=nginx:nginx nginx.conf /etc/nginx/conf.d/default.conf

USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["wget", "--quiet", "--spider", "http://127.0.0.1:8080/"]
