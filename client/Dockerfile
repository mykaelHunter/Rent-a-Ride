# syntax=docker/dockerfile:1

# ---- Stage 1: install deps + build the static bundle ----
FROM node:24.19.0-alpine AS build
WORKDIR /app

RUN apk update && apk upgrade --no-cache

# Full dependency tree needed here (Vite, plugins, etc. are devDependencies)
# - none of this ships, it only produces /app/dist below.
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

# ---- Stage 2: minimal, non-root static file server ----
# nginxinc/nginx-unprivileged is the same nginx build as the official image,
# repackaged to listen on 8080 and run as a non-root user (uid 101) by
# default - the stock nginx image's master process runs as root even though
# its workers drop privileges, which unprivileged avoids entirely. Pinned to
# the current nginx stable line (1.30.x) rather than 1.27, which has since
# been superseded.
FROM nginxinc/nginx-unprivileged:1.30-alpine AS runtime

COPY --from=build --chown=nginx:nginx /app/dist /usr/share/nginx/html

# Config lives in its own file (nginx.conf, next to this Dockerfile) rather
# than an inline heredoc - easier to read, diff, and lint on its own.
# Listens on 8080, matching the unprivileged base image's default (ports
# below 1024 need root to bind, which this image deliberately doesn't have).
COPY --chown=nginx:nginx nginx.conf /etc/nginx/conf.d/default.conf

# Explicit even though the base image already defaults to this user -
# hardening should be visible in the Dockerfile, not just inherited quietly
# (same reasoning as backend/Dockerfile's USER nonroot).
USER nginx

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["wget", "--quiet", "--spider", "http://127.0.0.1:8080/"]
