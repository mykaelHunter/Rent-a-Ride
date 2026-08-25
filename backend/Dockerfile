# syntax=docker/dockerfile:1

# ---- Stage 1: install production dependencies ----
# node:24-alpine (Node 24 is the current Active LTS line as of writing,
# supported through Apr 2028) is only used to run `npm ci` - it never ships.
FROM node:24.19.0-alpine AS deps
WORKDIR /app

# Patch any OS package CVEs baked into the base image layer at build time,
# on top of whatever the base image already had at publish time.
RUN apk update && apk upgrade --no-cache

# Root package.json holds the backend's dependencies (this repo doesn't
# separate a backend/package.json), so build context is the repo root.
# package-lock.json is required here: `npm ci` (unlike `npm install`)
# installs the exact locked versions and fails hard on any mismatch,
# instead of silently re-resolving ranges on every build.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---- Stage 2: minimal, non-root runtime ----
# Distroless has no shell, no package manager, and no OS tooling beyond the
# Node runtime itself - a much smaller attack surface than alpine, and
# nothing left for an attacker with RCE to pull further tools with. The
# ":nonroot" variant already runs as an unprivileged user (uid/gid 65532)
# with no further setup required. Its ENTRYPOINT is already "node", so CMD
# below only needs to supply the script path.
FROM gcr.io/distroless/nodejs24-debian13:nonroot AS runtime
WORKDIR /app
ENV NODE_ENV=production

COPY --from=deps --chown=nonroot:nonroot /app/node_modules ./node_modules
COPY --chown=nonroot:nonroot package.json ./
COPY --chown=nonroot:nonroot backend ./backend

# Explicit even though the ":nonroot" base already defaults to this user -
# hardening should be visible in the Dockerfile, not just inherited quietly.
USER nonroot

EXPOSE 3000

# Exec-form CMD/HEALTHCHECK (JSON array) run without a shell, which matters
# here since distroless has none. Uses the node binary's absolute path
# rather than bare "node": distroless's ENTRYPOINT is hardcoded to
# /nodejs/bin/node (not resolved via PATH), and a bare command name in an
# exec-form instruction DOES require a PATH lookup - which isn't guaranteed
# to resolve here. A bare "node" here made the healthcheck itself fail to
# launch even though the app was running fine, permanently marking the
# container unhealthy and blocking anything depending on it (see
# docs/incident-log.md INC-031). Hits the /healthz route added alongside
# this Dockerfile (see backend/server.js, INC-022) - it reports Mongo
# connectivity, not just "the process is still running".
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["/nodejs/bin/node", "-e", "require('http').get('http://127.0.0.1:3000/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]

CMD ["backend/server.js"]
