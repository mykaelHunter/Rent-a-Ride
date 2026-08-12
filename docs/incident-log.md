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

**Status:** all 5 Critical items and the highest-impact of the High/Medium
items (INC-006, 007, 008, 011, 015, 019) are resolved. Remaining open items
are hardening/cleanup and are not considered deployment blockers, with the
exception of INC-009/INC-010, which are worth a follow-up pass before this
handles real user data at scale.
