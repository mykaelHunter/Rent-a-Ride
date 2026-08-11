# --- build stage ---
FROM node:20-alpine AS build
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install

COPY . .

# Vite bakes VITE_* variables into the build at build time, so they must be
# passed as build args (docker-compose.yml does this from client/.env).
ARG VITE_PRODUCTION_BACKEND_URL
ARG VITE_FIREBASE_API_KEY
ARG VITE_RAZORPAY_KEY_ID
ENV VITE_PRODUCTION_BACKEND_URL=$VITE_PRODUCTION_BACKEND_URL
ENV VITE_FIREBASE_API_KEY=$VITE_FIREBASE_API_KEY
ENV VITE_RAZORPAY_KEY_ID=$VITE_RAZORPAY_KEY_ID

RUN npm run build

# --- serve stage ---
FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
# SPA fallback so client-side routes (react-router) don't 404 on refresh,
# plus a reverse proxy for /api so the app's same-origin fetch("/api/...")
# calls reach the backend container. Without this, fetch gets nginx's HTML
# fallback back instead of JSON, and res.json() throws - which is exactly
# what caused "something went wrong" on register/sign-in in this compose
# setup (see docs/incident-log.md INC-020).
RUN printf 'server {\n\
    listen 80;\n\
    root /usr/share/nginx/html;\n\
    location /api/ {\n\
        proxy_pass http://backend:3000;\n\
        proxy_set_header Host $host;\n\
        proxy_set_header X-Real-IP $remote_addr;\n\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n\
        proxy_set_header X-Forwarded-Proto $scheme;\n\
    }\n\
    location / {\n\
        try_files $uri /index.html;\n\
    }\n\
}\n' > /etc/nginx/conf.d/default.conf

EXPOSE 80
