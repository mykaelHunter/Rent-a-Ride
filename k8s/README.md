# Rent-a-Ride on kind (EC2)

Manifests to run Rent-a-Ride on a `kind` cluster on your EC2 instance,
pulling the images your Jenkins pipeline already pushed to Docker Hub
(`mykaelhunter/rent-a-ride-backend`, `mykaelhunter/rent-a-ride-client`).

**If this is a brand new cluster, skip straight to [Fresh install](#fresh-install).**
Everything else in this file is reference material.

## Files

| File | Purpose |
|---|---|
| `kind-config.yaml` | 1 control-plane + 2 worker node cluster, with host ports 30080/30300 mapped in |
| `00-namespace.yaml` | `rent-a-ride` namespace |
| `10-mongo-config.yaml` | Mongo non-secret ConfigMap only (`mongo-config`) |
| `11-mongo-statefulset.yaml` | Mongo 7 StatefulSet with a per-pod PVC (`volumeClaimTemplates`) + headless Service |
| `20-backend-config.yaml` | Backend non-secret ConfigMap only (`backend-config`) |
| `21-backend.yaml` | Backend Deployment + ClusterIP Service (`backend:3000`) + NodePort (30300, debug) |
| `22-backend-hpa.yaml` | HorizontalPodAutoscaler for the backend Deployment (CPU + memory) |
| `30-frontend.yaml` | Frontend (nginx) Deployment + NodePort Service (30080, main entry point) |
| `32-frontend-hpa.yaml` | HorizontalPodAutoscaler for the frontend Deployment (CPU) |
| `kustomization.yaml` | Lets you `kubectl apply -k .` everything **except Secrets** at once |
| `secret-templates/mongo-credentials.yaml.example` | Reference only — shows the shape of the `mongo-credentials` Secret. Never applied. |
| `secret-templates/backend-secret.yaml.example` | Reference only — shows the shape of the `backend-secret` Secret. Never applied. |

**Why Secrets aren't in `kustomization.yaml`:** they used to live inside
`10-mongo-config.yaml` / `20-backend-config.yaml` alongside their
ConfigMaps, checked in with `REPLACE_ME` placeholders. The very first
`kubectl apply -k .` on a fresh cluster applied those placeholders as the
live Secret values — silently, with no error — and the backend ran for a
while authenticating as literal user `REPLACE_ME` before anyone noticed.
Splitting Secrets out of the applied path entirely means there's now only
one way to set real credentials (the imperative commands below), and
`kubectl apply -k .` can never reset them back to placeholders by
accident, no matter how many times it's re-run.

## Fresh install

Run these in order, on the EC2 instance, from inside this `k8s/`
directory.

### 1. Create the cluster

```bash
kind create cluster --name rent-a-ride --config kind-config.yaml
kubectl create namespace rent-a-ride
```

### 2. Create both Secrets — before anything else touches the cluster

Both Secrets **must** share the same Mongo username/password. Generate
the password once and reuse it in both commands:

```bash
MONGO_USER=rentaride_admin
MONGO_PASS=$(openssl rand -base64 24 | tr -d '"'\''`$\\')   # no quote/backtick/$ chars - see note below
echo "Generated Mongo password: $MONGO_PASS"   # save this somewhere safe now

kubectl create secret generic mongo-credentials -n rent-a-ride \
  --from-literal=MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASS"

kubectl create secret generic backend-secret -n rent-a-ride \
  --from-literal=mongo_uri="mongodb://${MONGO_USER}:${MONGO_PASS}@mongo-0.mongo.rent-a-ride.svc.cluster.local:27017/rent-a-ride?authSource=admin" \
  --from-literal=ACCESS_TOKEN='<real value>' \
  --from-literal=REFRESH_TOKEN='<real value>' \
  --from-literal=CLOUD_NAME='<real value>' \
  --from-literal=API_KEY='<real value>' \
  --from-literal=API_SECRET='<real value>' \
  --from-literal=EMAIL_HOST='<real value>' \
  --from-literal=EMAIL_PASSWORD='<real value>' \
  --from-literal=RAZORPAY_KEY_ID='<real value>' \
  --from-literal=RAZORPAY_SECRET='<real value>'
```

Replace every `<real value>` with the actual credential — the same ones
that would go into `backend/.env` for a Docker Compose deploy (Cloudinary,
Razorpay, email, JWT signing values). **Do not paste a literal
`REPLACE_ME` anywhere in this step** — there's no second safety net
downstream that catches it.

*Why the password generator excludes quotes/backticks/`$`:* those
characters break shell interpolation (and, separately, the Mongo probe's
`sh -c` eval string) if they end up embedded in the password. Simpler to
avoid them entirely than to escape through three layers correctly.

### 3. Verify both Secrets before moving on

```bash
kubectl get secret mongo-credentials -n rent-a-ride -o jsonpath='{.data.MONGO_INITDB_ROOT_USERNAME}' | base64 -d; echo
kubectl get secret backend-secret -n rent-a-ride -o jsonpath='{.data.mongo_uri}' | base64 -d; echo
```

Confirm neither prints `REPLACE_ME` and that the username/password in
the `mongo_uri` matches what you just set. Don't proceed until this
looks right — every later step assumes it does.

### 4. Apply everything else

```bash
kubectl apply -k .
```

This creates the ConfigMaps, the Mongo StatefulSet + headless Service,
the backend and frontend Deployments/Services, and both HPAs — it will
**not** touch either Secret, now or on any future re-run.

### 5. Watch the rollout

StatefulSet pods come up in order (`mongo-0` first; only after it's
Ready would `mongo-1` etc. start, if `replicas` were ever raised above 1):

```bash
kubectl -n rent-a-ride get pods -w
```

### 6. Verify

```bash
kubectl -n rent-a-ride get svc
kubectl -n rent-a-ride get pvc                     # mongo-data-mongo-0 should be Bound

kubectl -n rent-a-ride exec -it mongo-0 -- mongosh \
  -u "$MONGO_USER" -p "$MONGO_PASS" --authenticationDatabase admin \
  --eval "db.adminCommand('ping')"

curl http://localhost:30300/healthz     # backend, direct
curl -I http://localhost:30080/         # frontend
```

Then open `http://<EC2-PUBLIC-IP>:30080` in a browser (make sure the EC2
security group allows inbound TCP 30080, and 30300 if you want direct
backend access).

**Before step 4**, also edit `20-backend-config.yaml`'s
`ALLOWED_ORIGINS` to use your real EC2 public IP instead of the
`<EC2-PUBLIC-IP>` placeholder — this one's a ConfigMap, not a Secret, so
it's safe to edit in place and commit.

### 7. Enable autoscaling (optional but recommended)

The HPAs are already applied by step 4, but they do nothing without
`metrics-server`, which kind doesn't ship by default. See
[Autoscaling](#autoscaling-horizontalpodautoscaler) below for the
one-time setup.

## Pod communication

- Frontend's nginx.conf (baked into the client image) proxies `/api/` to
  `http://backend:3000` — this resolves via in-cluster DNS as long as the
  backend Service is literally named `backend` in the same namespace,
  which it is here.
- Backend's `mongo_uri` (in the `backend-secret` Secret) points at
  `mongo-0.mongo.rent-a-ride.svc.cluster.local:27017` — Mongo runs as a
  StatefulSet behind a **headless** Service (`clusterIP: None`), so
  there's no single ClusterIP to route through; each pod instead gets its
  own stable per-pod DNS name (`<pod-name>.<service-name>...`). With one
  replica, that's always `mongo-0`.
- All tiers live in the `rent-a-ride` namespace, and the mongo URI uses
  the full `.svc.cluster.local` form since that's required for headless
  Service pod-DNS lookups (unlike the short-name resolution that works
  for normal ClusterIP Services like `backend`).

## Database: StatefulSet + PVC + credentials

- **StatefulSet, not Deployment.** Mongo is a `StatefulSet`
  (`11-mongo-statefulset.yaml`) so its pod identity and storage are
  stable across restarts, rather than the fungible pod identity a
  Deployment gives you.
- **Persistent storage via `volumeClaimTemplates`.** Instead of one PVC
  manually defined and shared, the StatefulSet provisions and binds a
  dedicated PVC per pod automatically — here that's a single 1Gi PVC
  named `mongo-data-mongo-0`, bound to kind's default `standard`
  StorageClass (local-path-provisioner). Data survives pod restarts and
  rescheduling, but not `kind delete cluster`.
- **Credentials via Kubernetes Secret, config via ConfigMap, created in
  that order.** `mongo-config` (ConfigMap, `10-mongo-config.yaml`) holds
  non-secret values (`MONGO_INITDB_DATABASE`, host, port); the
  `mongo-credentials` Secret (imperative-only, see Fresh install above)
  holds `MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD`,
  consumed by the official `mongo` image to create the root user on first
  init, and read by both StatefulSet probes for authenticated health
  checks.
- **`backend-secret`'s `mongo_uri` must be kept in sync by hand** with
  `mongo-credentials` (same username/password) — nothing enforces this
  automatically. The distroless backend image has no shell to interpolate
  the two at runtime, which is why they're two separate values instead of
  one computed at startup. An External Secrets Operator or Vault
  integration would remove this duplication if the credential ever needs
  to rotate.

## Autoscaling (HorizontalPodAutoscaler)

- **backend** (`22-backend-hpa.yaml`): 2–6 replicas, scales on CPU (70% of
  its `100m` request) and memory (80% of its `128Mi` request). Memory is
  included because a Node process under sustained request volume can grow
  its heap well before CPU alone would trigger a scale-up.
- **frontend** (`32-frontend-hpa.yaml`): 2–8 replicas, CPU only (70% of its
  `50m` request) — nginx serving static assets is CPU-bound on request
  volume and doesn't meaningfully leak memory the way a Node process can.
- **mongo is deliberately NOT autoscaled.** It's a single-replica
  StatefulSet holding the one primary database instance; scaling it
  horizontally would mean running multiple independent, non-replicated
  Mongo instances each with their own data — not the same thing as
  scaling a stateless web tier. Real Mongo horizontal scaling needs a
  proper replica set, which is a separate, bigger change from HPA.
- Both HPAs scale up fast (`stabilizationWindowSeconds: 0`, up to 100%
  more pods per 30s) and scale down slow (5-minute stabilization window,
  one pod removed per minute) — deliberately asymmetric so a real traffic
  spike gets capacity immediately, but a brief, noisy dip in usage doesn't
  cause pods to be added and removed repeatedly (flapping).

**HPA requires the `metrics-server` add-on, which kind does NOT ship by
default.** Without it, `kubectl get hpa` will show `<unknown>` under
`TARGETS` indefinitely and neither HPA will ever scale anything. Install
it once per cluster:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# kind's kubelets use self-signed certs that aren't in a public CA chain,
# which metrics-server rejects by default (Unable to fetch node metrics /
# x509 certificate signed by unknown authority). Patch in
# --kubelet-insecure-tls - fine for a local kind cluster, NOT something
# to carry into a real production cluster with properly-signed kubelet certs.
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

# wait for it to report real numbers (can take ~1-2 min after the patch)
kubectl top pods -n rent-a-ride
```

Once `kubectl top pods` returns real CPU/memory numbers instead of an
error, verify:

```bash
kubectl get hpa -n rent-a-ride -w
```

`TARGETS` should show something like `23%/70%, 41%/80%` instead of
`<unknown>/70%`. Watching this while generating load (e.g. a quick
`hey`/`ab` run against the frontend's NodePort) is the fastest way to
confirm scaling actually triggers before relying on it.

## Recovering from a placeholder / mismatched-credential Secret

If a Secret was ever applied with `REPLACE_ME` values (e.g. from before
this Secrets-out-of-kustomization change), or `mongo-credentials` and
`backend-secret`'s `mongo_uri` have drifted out of sync (different
passwords), the symptom is the backend crash-looping with
`MongoServerError: Authentication failed` in its logs even though Mongo
itself is healthy. Fix by patching just the affected key(s) in place —
no need to delete and recreate the whole Secret:

```bash
MONGO_USER=$(kubectl get secret mongo-credentials -n rent-a-ride -o jsonpath='{.data.MONGO_INITDB_ROOT_USERNAME}' | base64 -d)
MONGO_PASS=$(kubectl get secret mongo-credentials -n rent-a-ride -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d)

kubectl patch secret backend-secret -n rent-a-ride --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/mongo_uri\",\"value\":\"$(echo -n "mongodb://${MONGO_USER}:${MONGO_PASS}@mongo-0.mongo.rent-a-ride.svc.cluster.local:27017/rent-a-ride?authSource=admin" | base64 -w 0)\"}]"

kubectl -n rent-a-ride rollout restart deployment/backend
```

`base64 -w 0` matters on Linux — GNU `base64` line-wraps its output every
76 characters by default, which breaks the JSON patch payload with
`illegal base64 data at input byte 76` on anything longer than that (a
full `mongo_uri` always is). Drop `-w 0` on macOS, where `base64` doesn't
wrap by default and the flag isn't recognized.

## Notes / things to double check

- The client image already has `VITE_PRODUCTION_BACKEND_URL` and friends
  baked in at build time (Jenkins build args), so there's nothing to
  configure at runtime for the frontend container itself.
- Swap `:latest` for a specific Jenkins `IMAGE_TAG` (build number) in
  `21-backend.yaml` / `30-frontend.yaml` if you want a pinned, reproducible
  deploy instead of always pulling whatever `latest` currently points to.
- The `mongo-data-mongo-0` PVC uses kind's default `standard` StorageClass
  (local-path-provisioner) — data persists across pod restarts and
  rescheduling, but not across `kind delete cluster`.
- These Secrets are plain `Opaque` Kubernetes Secrets — base64-encoded at
  rest, not encrypted, and readable by anyone with `get secrets` RBAC
  access in the namespace. Fine for this kind/EC2 setup; a real
  production cluster would add encryption at rest and/or an external
  secrets manager on top.
