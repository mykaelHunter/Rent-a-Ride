FROM node:24.19.0-alpine AS deps
WORKDIR /app

RUN apk update && apk upgrade --no-cache

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM gcr.io/distroless/nodejs24-debian13:nonroot AS runtime
WORKDIR /app
ENV NODE_ENV=production

COPY --from=deps --chown=nonroot:nonroot /app/node_modules ./node_modules
COPY --chown=nonroot:nonroot package.json ./
COPY --chown=nonroot:nonroot backend ./backend

USER nonroot

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["node", "-e", "require('http').get('http://127.0.0.1:3000/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]

CMD ["backend/server.js"]
