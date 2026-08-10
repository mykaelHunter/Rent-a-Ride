FROM node:20-alpine

WORKDIR /app

# Root package.json holds the backend's dependencies (this repo doesn't
# separate a backend/package.json), so build context is the repo root.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY backend ./backend

ENV NODE_ENV=production
EXPOSE 3000

CMD ["node", "backend/server.js"]
