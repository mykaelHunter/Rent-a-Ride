# Rent-a-Ride on kind (EC2)

Manifests to run Rent-a-Ride on a `kind` cluster on your EC2 instance,
pulling the images your Jenkins pipeline already pushed to Docker Hub
(`mykaelhunter/rent-a-ride-backend`, `mykaelhunter/rent-a-ride-client`).

**If this is a brand new cluster, skip straight to [Fresh install](#fresh-install).**
Everything else in this file is reference material.

## Files

| File | Purpose |
|---|---|
| `kind-config.yaml` | 1 control-plane + 2 worker node cluster; control-plane labeled `ingress-ready=true` and maps host ports 30080/30300 (app) + 31080/31443 (ingress, via hostNetwork) |
| `00-namespace.yaml` | `rent-a-ride` namespace |
| `10-mongo-config.yaml` | Mongo non-secret ConfigMap only (`mongo-config`) |
| `11-mongo-statefulset.yaml` | Mongo 7 StatefulSet with a per-pod PVC (`volumeClaimTemplates`) + headless Service |
| `20-backend-config.yaml` | Backend non-secret ConfigMap only (`backend-config`) |
| `21-backend.yaml` | Backend Deployment + ClusterIP Service (`backend:3000`) + NodePort (30300, debug) |
| `22-backend-hpa.yaml` | HorizontalPodAutoscaler for the backend Deployment (CPU + memory) |
| `30-frontend.yaml` | Frontend (nginx) Deployment + NodePort Service (30080, main entry point) |
| `32-frontend-hpa.yaml` | HorizontalPodAutoscaler for the frontend Deployment (CPU) |
| `41-ingress.yaml` | Ingress routing `/` → frontend, `/api` → backend, via the nginx Ingress controller |
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

# URL-encode the password for embedding in the mongo_uri connection
# string - a raw password can contain URI-special characters (@, :, /,
# %, +) even after the shell-safety filter above, which strips a
# different set of characters for a different reason. A connection
# string parses these as separators/escapes regardless of shell context,
# so the copy embedded in mongo_uri below needs its own encoding pass.
MONGO_PASS_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$MONGO_PASS")

kubectl create secret generic mongo-credentials -n rent-a-ride \
  --from-literal=MONGO_INITDB_ROOT_USERNAME="$MONGO_USER" \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD="$MONGO_PASS"

kubectl create secret generic backend-secret -n rent-a-ride \
  --from-literal=mongo_uri="mongodb://${MONGO_USER}:${MONGO_PASS_ENCODED}@mongo-0.mongo.rent-a-ride.svc.cluster.local:27017/rent-a-ride?authSource=admin" \
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

Note: `mongo-credentials` itself stores the **raw, unencoded** password —
that's what mongod's own auth uses directly, not parsed through a URI, so
it must NOT be URL-encoded there. Only the copy embedded inside
`mongo_uri` needs encoding. Getting this backwards (encoding the raw
Secret, or forgetting to encode the URI copy) is exactly what causes a
`MongoParseError: Password contains unescaped characters` crash-loop on
first deploy, even with the shell-safe generator above — that filter
protects against shell/`sh -c` breakage, not URI parsing, and the two
character sets that matter aren't the same.

Replace every `<real value>` with the actual credential — the same ones
that would go into `backend/.env` for a Docker Compose deploy (Cloudinary,
Razorpay, email, JWT signing values). **Do not paste a literal
`REPLACE_ME` anywhere in this step** — there's no second safety net
downstream that catches it.

*Why the password generator excludes quotes/backticks/`$`:* those
characters break shell interpolation (and, separately, the Mongo probe's
`sh -c` eval string) if they end up embedded in the password. Simpler to
avoid them entirely than to escape through three layers correctly. This
is a separate concern from the URI-encoding step above — a password can
be shell-safe and still be URI-unsafe (e.g. `@` or `+`), which is why
both steps exist independently.

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

### 8. Install the Ingress controller (optional — single-entry-point routing)

> **This section is for the local `kind` cluster only.** If you're on EKS,
> skip this entirely - the Helm chart (`helm/rent-a-ride`) creates its own
> Ingress backed by the AWS Load Balancer Controller (see
> `infra/modules/eks`), and installing `ingress-nginx` alongside it will
> actively break things: its cluster-wide admission webhook intercepts
> *every* Ingress write, including the ALB one, and fails once the
> `ingress-nginx` controller pod isn't there to answer it (a
> "no endpoints available" webhook error on `argocd app sync` or
> `kubectl apply` is the exact symptom). If you've already installed it on
> an EKS cluster by mistake: `helm uninstall <release> -n ingress-nginx`
> (check the release/namespace with `helm list -A | grep nginx` first).

`41-ingress.yaml` is already applied by step 4, but like the HPAs it does
nothing until the actual nginx **Ingress controller** is installed - an
Ingress *resource* just declares routing rules; something has to exist
in-cluster to read and act on them. See
[Ingress](#ingress-nginx-ingress-controller) below for the one-time setup.

## Ingress (nginx Ingress controller, kind only - see warning above)

`41-ingress.yaml` routes all traffic through a single entry point instead
of the two separate NodePorts used so far:

- `http://<host>:31080/` → `frontend` Service (port 8080)
- `http://<host>:31080/api` → `backend` Service (port 3000)

No `rewrite-target` annotation is used — the backend's own Express routes
are already mounted under `/api/*` (the same assumption `client/nginx.conf`'s
own proxy already relies on, see INC-020), so the Ingress passes the full
path straight through, `/api` included.

This is a genuine second (better) entry point on top of the existing
`frontend`/`backend` NodePort Services from `21-backend.yaml` /
`30-frontend.yaml` — those aren't removed and still work directly if you
need them for debugging.

**Use kind's own ingress-nginx install manifest — NOT the generic "cloud"
one.** This matters more than it looks: the generic cloud-provider
manifest creates the controller as `type: LoadBalancer`, which never
gets an external IP on kind (no cloud load balancer provisioner exists),
so the obvious-seeming fix is patching its Service to `NodePort`
afterward. **Don't do this — it looked like it worked in earlier testing
of this setup, then reliably hung on every actual request from outside
the cluster, twice, on two different port numbers, even from a
completely fresh cluster.** Kind's Docker-based nodes make NodePort
routing to a Service unreliable in ways that don't show up in `kubectl
get svc`/`get endpoints` — everything reports healthy right up until an
external client actually tries to use it. `docker exec`-ing into the
node and curling the same port from inside always worked, which is what
made this so confusing to diagnose — the break was consistently between
the host and the node, invisible to every Kubernetes-level check.

kind's own docs address this directly: install the **kind-specific**
manifest, which runs the controller with `hostNetwork: true` and a
`nodeSelector` targeting a labeled node, so the controller binds host
ports directly — no NodePort, no kube-proxy Service routing involved at
all for ingress traffic.

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

**As of this writing, the upstream manifest above no longer includes the
`nodeSelector` that pins the controller to the `ingress-ready` node —
kind's own docs describe it, but the manifest's `main` branch has drifted
from that. Without it, the controller pod can be scheduled onto any
node, including a worker with none of `kind-config.yaml`'s host port
mappings, which produces a very specific and confusing symptom: `curl`
connects successfully (so it's not a networking dead-end) but gets
`Recv failure: Connection reset by peer` immediately, because
`docker-proxy` on the host forwards the connection into the
control-plane node correctly, but nothing on that specific node is
listening — the actual controller pod is elsewhere.** Patch the
`nodeSelector` back in immediately after applying:

```bash
kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/nodeSelector/ingress-ready","value":"true"}]'
```

This requires `kind-config.yaml`'s control-plane node to already have
`labels: { ingress-ready: "true" }` set at cluster-creation time** (it
does, as of this file) — the patch's `nodeSelector` won't schedule the
controller anywhere without it, and node labels, like
`extraPortMappings`, can't be added after the cluster already exists.
If this cluster predates that label being added to `kind-config.yaml`,
delete and recreate:

```bash
kind delete cluster --name rent-a-ride
kind create cluster --name rent-a-ride --config kind-config.yaml
# then redo Fresh install steps 2 onward - Secrets and PVCs don't survive
# cluster deletion, so this really is starting over
```

Wait for the controller to be ready — this manifest also runs one-shot
admission-webhook jobs first, so expect a `Completed` job or two
alongside the controller pod, not just the controller itself:

```bash
kubectl get pods -n ingress-nginx -w
kubectl get ingress -n rent-a-ride

# confirm the pod actually landed on the control-plane node - if this
# shows a worker instead, the nodeSelector patch above didn't take
kubectl get pod -n ingress-nginx -l app.kubernetes.io/component=controller -o wide
```

No Service patching step this time — `hostNetwork: true` means there's
no NodePort layer to configure at all. Once the controller pod shows
`1/1 Running` **and is confirmed scheduled on the control-plane node**,
test both routes directly against the mapped host ports:

```bash
curl -I http://localhost:31080/          # should hit the frontend
curl http://localhost:31080/api/healthz  # should hit the backend
```

(Substitute your EC2 public IP for `localhost` if running on EC2 rather
than locally, and confirm the security group allows inbound TCP `31080`.)

If these still hang the way the NodePort-patched approach did, that
would point at something new and worth investigating fresh — but this
approach removes the entire layer (kube-proxy NodePort routing through
Docker's NAT) that every previous failure traced back to, so it's the
right next thing to try before going deeper into host networking again.

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

## Recovering from a placeholder / mismatched-credential / unescaped-password Secret

If a Secret was ever applied with `REPLACE_ME` values (e.g. from before
this Secrets-out-of-kustomization change), `mongo-credentials` and
`backend-secret`'s `mongo_uri` have drifted out of sync (different
passwords), or the generated password contains a URI-special character
(`@`, `:`, `/`, `%`, `+`) that was embedded in `mongo_uri` unencoded, the
symptom is the backend crash-looping — either
`MongoServerError: Authentication failed` (mismatched credentials) or
`MongoParseError: Password contains unescaped characters` (unencoded
special character) — in its logs, even though Mongo itself is healthy.
Fix by patching just the affected key(s) in place — no need to delete and
recreate the whole Secret:

```bash
MONGO_USER=$(kubectl get secret mongo-credentials -n rent-a-ride -o jsonpath='{.data.MONGO_INITDB_ROOT_USERNAME}' | base64 -d)
MONGO_PASS=$(kubectl get secret mongo-credentials -n rent-a-ride -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d)
MONGO_PASS_ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$MONGO_PASS")

kubectl patch secret backend-secret -n rent-a-ride --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/mongo_uri\",\"value\":\"$(echo -n "mongodb://${MONGO_USER}:${MONGO_PASS_ENCODED}@mongo-0.mongo.rent-a-ride.svc.cluster.local:27017/rent-a-ride?authSource=admin" | base64 -w 0)\"}]"

kubectl -n rent-a-ride rollout restart deployment/backend
```

`base64 -w 0` matters on Linux — GNU `base64` line-wraps its output every
76 characters by default, which breaks the JSON patch payload with
`illegal base64 data at input byte 76` on anything longer than that (a
full `mongo_uri` always is). Drop `-w 0` on macOS, where `base64` doesn't
wrap by default and the flag isn't recognized.

`urllib.parse.quote(..., safe='')` matters just as much — running this
patch with the raw, unencoded password is what causes
`MongoParseError: Password contains unescaped characters` on the very
next backend restart even when the credentials themselves are otherwise
correct.

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
