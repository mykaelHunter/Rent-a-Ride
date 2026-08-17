# Rent-a-Ride — Pre-Deployment Incident Log

Findings from a code review of the codebase, before deployment. Each finding
has a stable incident code (`INC-NNN`) for reference in commits/PRs. File
paths are relative to repo root.

**Status legend:** ✅ Resolved · ⬜ Open

| Code | Severity | Status | Summary |
|------|----------|--------|---------|
| INC-001 | Critical | ✅ Resolved | Admin routes had no auth middleware |
| INC-002 | Critical | ✅ Resolved | `/api/admin/dashboard` auth logic broken |
| INC-003 | Critical | ✅ Resolved | Env vars read before `dotenv.config()` ran |
| INC-004 | Critical | ✅ Resolved | Token-refresh dead branch hung requests |
| INC-005 | Critical | ✅ Resolved | Auth header parsing crashed on missing/standard headers |
| INC-006 | High | ✅ Resolved | Port not read from environment |
| INC-007 | High | ✅ Resolved | Public GET endpoint seeded/mutated the database |
| INC-008 | High | ✅ Resolved | CORS/cookie domain hardcoded to one Vercel URL |
| INC-009 | High | ⬜ Open | Inconsistent cookie attributes across auth flows |
| INC-010 | High | ⬜ Open | No input validation on auth/user endpoints |
| INC-011 | Medium | ✅ Resolved | Cloudinary re-configured on every request |
| INC-012 | Medium | ⬜ Open | Deprecated `new Buffer.from(...)` usage |
| INC-013 | Medium | ⬜ Open | Duplicated upload/base64 helper code |
| INC-014 | Medium | ⬜ Open | Mixed Vite + Create React App tooling in client |
| INC-015 | Medium | ✅ Resolved | No `.env.example` for required variables |
| INC-016 | Low | ⬜ Open | Typos in error responses (`succes`) |
| INC-017 | Low | ⬜ Open | Stray commented-out code |
| INC-018 | Medium | ⬜ Open | `RAZORPAY_KEY_ID` read client-side without Vite's required `VITE_` prefix |
| INC-019 | Low | ✅ Resolved | No Docker/compose setup for local parity or deployment |
| INC-020 | Critical | ✅ Resolved | Dockerized client had no `/api` reverse proxy, breaking every fetch call |
| INC-021 | Critical | ✅ Resolved | Non-sparse unique index on optional `phoneNumber` broke every signup after the first |
| INC-022 | High | ✅ Resolved | Backend Dockerfile was single-stage and ran as root |
| INC-023 | High | ✅ Resolved | Client (nginx) container ran its master process as root |
| INC-024 | Medium | ✅ Resolved | Docker builds used `npm install` instead of locked, reproducible `npm ci` |
| INC-025 | Medium | ✅ Resolved | Frontend/dev-only packages shipped inside backend's production dependencies |
| INC-026 | High | ✅ Resolved | No `.dockerignore`, risking secrets baked into image layers |
| INC-027 | Medium | ⬜ Open | Known vulnerabilities in production dependencies (nodemailer, image-size, uuid) |
| INC-028 | Medium | ✅ Resolved | No structured application logging — scattered `console.log`, some leaking request bodies, errors failing silently |
| INC-029 | Medium | ✅ Resolved | Compose had no explicit backend healthcheck; client started before backend was actually ready |
| INC-030 | Medium | ✅ Resolved | No Docker log rotation configured — container logs could grow unbounded |
| INC-031 | Critical | ✅ Resolved | Backend HEALTHCHECK used bare `node`, unresolvable via PATH in distroless — container stuck permanently unhealthy |

---

## Critical — resolved this pass

### INC-001 — Admin routes had no authentication middleware ✅
`backend/routes/adminRoute.js` — `/addProduct`, `/deleteVehicle/:id`,
`/editVehicle/:id`, `/allBookings`, `/changeStatus`,
`/fetchVendorVehilceRequests`, `/approveVendorVehicleRequest`,
`/rejectVendorVehicleRequest`, `/dummyData`, `/getVehicleModels` were
registered with no auth check at all.

**Fix:** every route in `adminRoute.js` now runs `verifyToken` (valid
access/refresh token) followed by a new `requireAdmin` middleware
(`backend/utils/verifyUser.js`) that loads the user and checks
`isAdmin === true` before the handler runs.

### INC-002 — `/api/admin/dashboard` auth logic was broken ✅
The route chained the `signIn` *controller* as middleware
(`router.post('/dashboard', signIn, adminAuth)`), but `signIn` sends its own
response and calls `next()` afterward, so `adminAuth` ran (or errored) after
headers were already sent — there was no real admin gate.

**Fix:** `/dashboard` now uses the same `verifyToken` + `requireAdmin` chain
as every other admin route; `adminAuth` (`adminController.js`) was updated
to check the already-loaded `req.userDoc.isAdmin` instead of the
non-existent `req.user.isAdmin`.

### INC-003 — Env vars read before they were loaded ✅
`backend/server.js` called `mongoose.connect(process.env.mongo_uri)` before
`dotenv.config()` ran.

**Fix:** `dotenv.config()` is now the first thing `server.js` executes,
before any other import or `process.env` read.

### INC-004 — Broken token-refresh path hung requests ✅
`verifyUser.js`'s `TokenExpiredError` branch had a comment ("try to refresh
it") but no code — no refresh, no `next()`, no response. The request just
hung.

**Fix:** extracted a shared `refreshAndProceed()` helper used by both the
"no access token" and "expired access token" paths, so an expired access
token with a valid refresh token now actually issues new tokens (returned
via `x-access-token`/`x-refresh-token` response headers) and calls `next()`.
Every other exit path now returns a proper error response instead of
hanging.

### INC-005 — Auth header parsing crashed on missing/non-standard headers ✅
Both `verifyUser.js` and `authController.refreshToken` did
`req.headers.authorization.split(" ")[1].split(",")[0/1]`, which threw if
the header was absent or in the standard `Bearer <token>` form.

**Fix:** both now use defensive parsing (`parseAuthHeader` in
`verifyUser.js`; inlined equivalent in `authController.js`) that returns
`undefined` instead of throwing when the header is missing, and accepts
either the app's `Bearer <refresh>,<access>` format or a plain
`Bearer <token>` (treated as an access token).

---

## High

### INC-006 — Port not read from environment ✅
`server.js` hardcoded `const port = 3000`, which breaks on hosts (Render,
Railway, Heroku, etc.) that inject their own `PORT`.

**Fix:** `const port = process.env.PORT || 3000`. Documented in
`backend/.env.example`.

### INC-007 — Public GET endpoint seeded/mutated the database ✅
`GET /api/admin/dummyData` → `insertDummyData` was unauthenticated and a
`GET` route that writes to the database.

**Fix:** now behind the same `verifyToken` + `requireAdmin` chain as the
rest of `adminRoute.js` (resolved as part of INC-001), and changed to
`POST` since it performs a write. No client code referenced this endpoint.

### INC-008 — CORS/cookie domain hardcoded to one Vercel URL ✅
`allowedOrigins` in `server.js` was hardcoded to
`https://rent-a-ride-two.vercel.app`, so deploying to any other domain
silently broke auth with no config surface.

**Fix:** `allowedOrigins` now reads from a comma-separated
`ALLOWED_ORIGINS` env var, falling back to the previous defaults if unset.
Documented in `backend/.env.example`.

### INC-009 — Inconsistent cookie attributes across auth flows ⬜
`google()` uses wrong casing (`SameSite`/`Domain` instead of
`sameSite`/`domain`) in one of its two branches, and `signIn()`'s
cookie-setting code is commented out entirely, so tokens are only returned
in the JSON body there while other flows rely on cookies. Left open — this
needs a decision on cookie-based vs. bearer-token auth as the single source
of truth before touching it, which is a bigger change than a targeted fix.

### INC-010 — No input validation on auth/user endpoints ⬜
`signUp`/`signIn`/vendor equivalents trust `req.body` directly. Left open —
recommend adding a validation layer (e.g. `zod`, already a client
dependency) at the route level.

---

## Medium

### INC-011 — Cloudinary re-configured on every request ✅
`App.use('*', cloudinaryConfig)` ran Cloudinary's `config()` on every
incoming request.

**Fix:** `cloudinaryConfig` is now a plain function called once at startup
in `server.js`, instead of Express middleware run per-request.

### INC-012 — Deprecated `new Buffer.from(...)` usage ⬜
`backend/utils/multer.js` uses the deprecated `new Buffer.from(...)`
constructor. Left open (low risk, not deployment-blocking, but should
become `Buffer.from(...)` without `new`).

### INC-013 — Duplicated upload/base64 helper code ⬜
`multerUploads`/`multerMultipleUploads` and `dataUri`/`base64Converter` in
`multer.js` are identical. Left open — cleanup, not a bug.

### INC-014 — Mixed Vite + Create React App tooling ⬜
`client/package.json` depends on both `vite` and `react-scripts` despite
being a Vite project. Left open — needs a decision on whether
`react-scripts` is still needed for anything before removing it.

### INC-015 — No `.env.example` ✅
Neither `backend/` nor `client/` documented required env vars.

**Fix:** added `backend/.env.example`, `client/.env.example`, and a root
`.env.example` (for `docker-compose.yml` build-arg substitution), covering
every `process.env.*` / `import.meta.env.*` reference found in the
codebase.

---

## Low

### INC-016 — Typos in error responses ⬜
`succes: false` (missing "s") in error responses. Left open, cosmetic.

### INC-017 — Stray commented-out code ⬜
Large commented-out blocks in `authController.js`/`verifyUser.js`. Left
open, cosmetic/readability.

### INC-018 — `RAZORPAY_KEY_ID` missing required Vite prefix ⬜
*(Newly found while writing `.env.example` files.)* Client code reads
`import.meta.env.RAZORPAY_KEY_ID`, but Vite only exposes env vars prefixed
with `VITE_` to browser code by default (`vite.config.js` doesn't override
`envPrefix`), so this value is `undefined` at runtime wherever it's used.
Documented in `client/.env.example` as `VITE_RAZORPAY_KEY_ID`; the source
reference in the Razorpay checkout code still needs updating to match.
Left open — not touched this pass since it's a rename, not purely additive.

### INC-019 — No Docker/compose setup ✅
No `Dockerfile`s or `docker-compose.yml` existed, so there was no
reproducible way to run the full stack (API + Mongo + client) locally or
deploy it as containers.

**Fix:** added `backend/Dockerfile`, `client/Dockerfile` (multi-stage
build served via nginx, with an SPA fallback for client-side routing), and
a root `docker-compose.yml` wiring up `mongo`, `backend`, and `client`
services. `backend` reads secrets from `backend/.env`; `client`'s
`VITE_*` build args come from a root `.env` (see `.env.example`).

### INC-020 — Dockerized client had no `/api` reverse proxy ✅
*(Found after deploying via `docker-compose`.)* Every fetch call in the
client (`SignUp.jsx`, `SignIn.jsx`, `Vehicles.jsx`, etc.) uses a
same-origin relative path like `fetch("/api/auth/signup")`. In local
`npm run dev`, Vite's dev-server proxy (`vite.config.js`) forwards `/api`
to the backend — but that proxy only exists in Vite's dev server, not in
a production build. The `client` Dockerfile served the built app through
plain nginx with no knowledge of `/api`, so those requests hit nginx's SPA
fallback and got back `index.html` instead of JSON. `res.json()` then threw,
which the client's generic `catch` block surfaced as "something went wrong"
on register (and would affect every other API call the same way — sign in,
booking, vehicle listing, etc.).

Symptom seen: backend `GET /` returning "Cannot GET /" is expected (no root
route is defined - the API only exposes `/api/*`), but it's worth noting
here since it was reported alongside INC-020 and could look related.

**Fix:** `client/Dockerfile`'s nginx config now proxies `location /api/`
to `http://backend:3000` (the `backend` service's hostname on the
`docker-compose` network), in addition to the existing SPA fallback for
client-side routes.

### INC-021 — Non-sparse unique index on optional `phoneNumber` broke every signup after the first ✅
*(Found while investigating a "vendor signup: something went wrong" report
after rebuilding images with an updated Node Alpine version.)*
`backend/models/userModel.js` declared `phoneNumber: { type: String,
unique: true }` — optional (no `required`) but with a unique index and no
`sparse` option. Neither `signUp` (`authController.js`) nor `vendorSignup`
(`vendorController.js`) ever set `phoneNumber`. MongoDB's default
behavior for a non-sparse unique index is to treat every document missing
that field as having the same value, `null` — so the very first account
ever created (regular user or vendor, whichever came first) claimed
`phoneNumber: null` successfully, and every signup after that hit a
duplicate-key error on that index. The client's generic catch block
surfaced this as "something went wrong," with no indication of the real
cause.

**Fix:** added `sparse: true` to the `phoneNumber` field, which excludes
documents that don't set the field from the uniqueness check entirely.
Existing MongoDB deployments still need the old (non-sparse) index rebuilt
— either drop the local dev volume (`docker compose down -v`) or drop just
that index (`db.users.dropIndex('phoneNumber_1')`) and let Mongoose
recreate it as sparse on next connect; the schema change alone does not
retroactively fix an index that already exists in a running database.

---

## August 14, 2026 — Container Hardening & Image Size Reduction

Both Dockerfiles were reworked for size, base image currency, and running
as non-root, plus a supporting cleanup of what actually ships in the
backend's dependency tree.

### INC-022 — Backend Dockerfile was single-stage and ran as root ✅
`backend/Dockerfile` copied the repo, ran `npm install`, and ran the app
in the same `node:24-alpine` layer used to install dependencies — no
separation between build-time tooling and the runtime image, and no `USER`
directive, so the container ran as root (uid 0) by default.

**Fix:** split into two stages. Stage 1 (`node:24.19.0-alpine`) runs
`apk upgrade` to patch any OS package CVEs baked into the base layer, then
`npm ci --omit=dev` (reproducible install from the lockfile — see
INC-024). Stage 2 copies only `node_modules` and the application code into
`gcr.io/distroless/nodejs24-debian13:nonroot` — an image with no shell, no
package manager, and no OS tooling beyond the Node runtime itself, running
as uid/gid 65532 by default. `USER nonroot` is set explicitly even though
the base image already defaults to it, so the non-root requirement is
visible in the Dockerfile rather than implicit. Added a `HEALTHCHECK`
hitting a new `/healthz` route (`backend/server.js`) that reports MongoDB
connection state, not just process liveness.

### INC-023 — Client (nginx) container ran its master process as root ✅
`client/Dockerfile`'s runtime stage used the stock `nginx:1.27-alpine`
image. Stock nginx images run their master process as root even though
worker processes drop privileges — the container as a whole is still
root-owned. The nginx version itself (1.27) was also from an nginx stable
branch that has since been superseded.

**Fix:** switched to `nginxinc/nginx-unprivileged:1.30-alpine` — same
nginx build, repackaged to listen on port 8080 and run entirely as a
non-root user (uid 101) with no additional configuration required. Updated
the nginx config's `listen` directive from 80 to 8080 to match, and updated
`docker-compose.yml`'s port mapping (`5173:8080`) accordingly. Added
`server_tokens off;` to stop nginx announcing its exact version in
response headers, and a `HEALTHCHECK` using `wget --spider`. The config
itself was pulled out into its own `client/nginx.conf` file, copied in via
`COPY nginx.conf /etc/nginx/conf.d/default.conf`, instead of living as an
inline `printf` heredoc in the Dockerfile — easier to read and diff on
its own.

### INC-024 — Docker builds used `npm install` instead of a locked, reproducible `npm ci` ✅
Neither the repo root nor `client/` had a committed `package-lock.json`
(both are gitignored), so every Docker build re-resolved semver ranges
against whatever was current on the npm registry at build time — different
builds of the same source could pull different transitive dependency
versions, undermining reproducibility and making "it worked yesterday"
failures possible.

**Fix:** generated `package-lock.json` for both the root and `client/`
projects and switched both Dockerfiles from `npm install` to `npm ci`,
which installs exactly what's in the lockfile and fails the build outright
on any mismatch instead of silently re-resolving.

### INC-025 — Frontend/dev-only packages shipped inside the backend's production dependencies ✅
The root `package.json`'s `dependencies` (not `devDependencies`) included
`nodemon`, `framer-motion`, `clsx`, and `tailwind-merge` — none of which
are imported anywhere under `backend/` (confirmed by search). Because
`npm ci --omit=dev` only excludes `devDependencies`, all four were being
installed into the production image regardless, adding unnecessary size
and extra transitive dependencies to track for vulnerabilities.

**Fix:** moved all four to `devDependencies` in `package.json` and
regenerated the lockfile. Verified with `npm ls --omit=dev` that none of
the four appear in a production install. `npm run dev` (which still uses
`nodemon`) is unaffected since dev tooling installs still include
`devDependencies`.

### INC-026 — No `.dockerignore`, risking secrets baked into image layers ✅
Neither the repo root nor `client/` had a `.dockerignore`. `client/Dockerfile`
does `COPY . .` for the build stage — without a `.dockerignore`, a local
`.env` file, `.git` history, or `node_modules` sitting in the build context
would be copied into the image's build layers. A layer isn't removed by a
later layer deleting the file from the final filesystem view — it can still
be extracted from the image history.

**Fix:** added `.dockerignore` at the repo root (backend's build context)
and inside `client/`, explicitly excluding `.env*` files (while allowing
`*.env.example` through), `.git`, `node_modules`, and other local-only
files.

### INC-027 — Known vulnerabilities in production dependencies (Open) ⬜
Running `npm audit --omit=dev` against the newly-generated root lockfile
surfaced high-severity advisories in `nodemailer` (SMTP command injection
and related issues across several CVEs) and `image-size` (via `datauri` →
denial of service), plus a moderate advisory in `uuid`. All three fixes
are available only via `npm audit fix --force`, which pulls in breaking
major-version bumps (`nodemailer@9`, `datauri@0.8.0`, `uuid@14`). Left
open this pass since upgrading them needs testing against the app's actual
usage (nodemailer transport config, datauri's API surface) rather than a
blind version bump alongside a container-hardening pass. The client's
`npm audit` also reported 32 vulnerabilities, overwhelmingly in
`react-scripts`' dev-time dependency tree (see INC-014) — these do not
ship in the built static output, but they do add risk during the build
stage itself.

---

## August 17, 2026 — Healthchecks, Logging, and Restart Policy Review

Follow-up pass focused specifically on observability and resilience:
healthchecks on the database and backend containers, application-wide
logging, and confirming restart policies are set where they're needed.

### INC-028 — No structured application logging ✅
Severity: Medium | Status: Resolved
Files: `backend/utils/logger.js` (new), `backend/server.js`, and ~11
controller/service files across `backend/controllers/` and
`backend/services/`

**Issue encountered:** the backend had no centralized logging. Error
handling was ~40 scattered `console.log(error)` / `console.error(error)`
calls with no consistent format, no timestamps, and no log levels — and no
request logging at all, so there was no record of what was actually being
called against the API. Several calls were debug leftovers with no
diagnostic value (`console.log("hello")`, `console.log("hi")`), and one
(`console.log(req.body)` in a booking controller) logged entire request
bodies verbatim, a real risk of leaking user data into logs. The global
error-handling middleware in `server.js` didn't log anything at all before
responding — failures were only visible to the client, not in the server's
own output.

**Solution applied:**
- Added `backend/utils/logger.js`, a structured JSON logger (`pino`)
  writing to stdout — the natural fit for containers, since Docker's log
  driver captures stdout/stderr directly with no file path to manage
  inside the read-only, non-root backend container. Configured with
  `redact` rules so passwords, tokens, and auth headers can never end up
  in a log line even by accident.
- Added `pino-http` request-logging middleware in `server.js`, ahead of
  every route, so every request is logged (method, path, status, response
  time) as structured JSON — except `/healthz`, excluded from access logs
  since it fires every 30 seconds and adds noise rather than signal.
- Added Mongoose connection lifecycle logging (`connected`, `error`,
  `disconnected`, `reconnected`) and `uncaughtException` /
  `unhandledRejection` handlers that log via `logger.fatal` before exiting
  — important given `restart: unless-stopped` (INC-030 below): without
  this, a crashing container just restarts silently with no record of why.
- The global error-handling middleware now logs every error it handles,
  with request context (method, URL, status code), before responding to
  the client.
- Swept all ~40 existing `console.*` calls across `backend/controllers/`
  and `backend/services/`: error-context calls converted to
  `logger.error(...)`, informational ones to `logger.info(...)`, and pure
  debug leftovers (including the one logging raw request bodies) deleted
  outright.
- Verified `pino`/`pino-http` introduce no native addons (checked via
  `find node_modules -name "*.node"`) — required since the backend's
  `node_modules` are built on Alpine (musl libc) and copied into a
  distroless (glibc) runtime image; a native addon would silently break
  across that boundary.

### INC-029 — Compose had no explicit backend healthcheck; client started before backend was ready ✅
Severity: Medium | Status: Resolved
Files: `docker-compose.yml`

**Issue encountered:** `backend/Dockerfile` already had a `HEALTHCHECK`
instruction (added during the August 14 hardening pass), and Mongo already
had an explicit `healthcheck:` block in `docker-compose.yml` — but the
backend service itself had no matching `healthcheck:` override in compose,
and `client`'s `depends_on: [backend]` only waited for the backend
container to *start*, not to actually be ready (Mongo-connected and
serving traffic). In a slow-starting environment, the client could come up
before the backend was able to serve any request.

**Solution applied:** added an explicit `healthcheck:` block to the
`backend` service in `docker-compose.yml` (same check as the Dockerfile's,
made visible at the compose level for consistency with `mongo`'s), and
changed `client`'s `depends_on` to `backend: condition: service_healthy` —
the client container now only starts once the backend's `/healthz` check
is passing.

### INC-030 — No Docker log rotation configured ✅
Severity: Medium | Status: Resolved
Files: `docker-compose.yml`

**Issue encountered:** none of the three services had a `logging:` driver
configuration, so Docker's default `json-file` driver was in play with no
size or file cap — container logs (now considerably more verbose thanks to
INC-028's request logging) could grow unbounded and, over a long-running
deployment, fill the host disk.

**Solution applied:** added a shared `x-logging` anchor (`json-file`
driver, `max-size: 10m`, `max-file: 3` — 30MB cap per container) applied
to `mongo`, `backend`, and `client`.

### Restart policies — confirmed, no change needed
All three services (`mongo`, `backend`, `client`) already had
`restart: unless-stopped` set during the August 14 hardening pass. Reviewed
again as part of this pass and confirmed no additional service needs a
different policy (no one-off/init containers exist in this compose file
that should run-once-and-exit).

### INC-031 — Backend HEALTHCHECK used bare `node`, unresolvable via PATH in distroless ✅
Severity: Critical | Status: Resolved
Files: `backend/Dockerfile`, `docker-compose.yml`

**Symptom:** after rebuilding with the INC-028–030 changes,
`docker compose up` failed with `Container rent-a-ride-backend-1 Error
dependency backend failed to start`. `docker compose logs backend` showed
the app itself starting cleanly — `server listening on port 3000` and
`MongoDB connected` both logged — so the application was never the
problem.

**Root cause:** the backend's `HEALTHCHECK` (both in `backend/Dockerfile`
and mirrored in `docker-compose.yml`, added as part of INC-022/INC-029)
invoked the health check script as `CMD ["node", "-e", "..."]` — a bare
command name. Distroless's own `ENTRYPOINT` is hardcoded to the Node
binary's absolute path (`/nodejs/bin/node`), set at the base image level
and never resolved via `PATH` — which is why the application itself
started fine. But a bare command name in an exec-form `CMD`/`HEALTHCHECK`
instruction *does* require a `PATH` lookup, and that isn't guaranteed to
resolve inside a distroless image. The healthcheck process itself
therefore failed to launch on every attempt, permanently marking the
otherwise-healthy backend container as unhealthy — which, now that
`client`'s `depends_on` correctly gates on `service_healthy` (INC-029),
blocked the whole stack from starting. This bug existed since INC-022
(August 14) but was invisible until INC-029 made anything actually depend
on the backend's health status.

**Fix:** changed both the Dockerfile's `HEALTHCHECK` and the compose
file's mirrored `healthcheck.test` to invoke the Node binary by its
absolute path, `/nodejs/bin/node`, instead of the bare `node` command
name.

---

**Status:** all 5 Critical items from the initial review, INC-020, and
INC-021 are resolved — 7/7 Critical issues closed. The August 14 hardening
pass resolved 5 additional items (INC-022 through INC-026) and surfaced one
new open item (INC-027, dependency vulnerabilities, not container-related).
The August 17 pass resolved 3 more (INC-028 through INC-030) covering
logging, healthcheck wiring, and log rotation, plus one further Critical
fix (INC-031) found while validating that pass — 8/8 Critical issues now
closed. Remaining open items are hardening/cleanup and are not considered
deployment blockers, with the exception of INC-009/INC-010, which are worth
a follow-up pass before this handles real user data at scale.
