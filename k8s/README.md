# Rent-a-Ride on kind (EC2)

Manifests to run Rent-a-Ride on a `kind` cluster on your EC2 instance,
pulling the images your Jenkins pipeline already pushed to Docker Hub
(`mykaelhunter/rent-a-ride-backend`, `mykaelhunter/rent-a-ride-client`).

## Files

| File | Purpose |
|---|---|
| `kind-config.yaml` | 1 control-plane + 2 worker node cluster, with host ports 30080/30300 mapped in |
| `00-namespace.yaml` | `rent-a-ride` namespace |
| `10-mongo-config.yaml` | Mongo non-secret ConfigMap + `mongo-credentials` Secret (root username/password) |
| `11-mongo-statefulset.yaml` | Mongo 7 StatefulSet with a per-pod PVC (`volumeClaimTemplates`) + headless Service |
| `20-backend-config.yaml` | Backend ConfigMap (non-secret) + Secret (`mongo_uri` + app secrets — fill in real values) |
| `21-backend.yaml` | Backend Deployment + ClusterIP Service (`backend:3000`) + NodePort (30300, debug) |
| `30-frontend.yaml` | Frontend (nginx) Deployment + NodePort Service (30080, main entry point) |
| `kustomization.yaml` | Lets you `kubectl apply -k .` everything at once |

## Pod communication

- Frontend's nginx.conf (baked into the client image) proxies `/api/` to
  `http://backend:3000` — this resolves via in-cluster DNS as long as the
  backend Service is literally named `backend` in the same namespace,
  which it is here.
- Backend's `mongo_uri` (in the `backend-secret` Secret) points at
  `mongo-0.mongo.rent-a-ride.svc.cluster.local:27017` — Mongo now runs as
  a StatefulSet behind a **headless** Service (`clusterIP: None`), so
  there's no single ClusterIP to route through; each pod instead gets its
  own stable per-pod DNS name (`<pod-name>.<service-name>...`). With one
  replica, that's always `mongo-0`.
- All tiers live in the `rent-a-ride` namespace, and the mongo URI uses
  the full `.svc.cluster.local` form since that's required for headless
  Service pod-DNS lookups (unlike the short-name resolution that works
  for normal ClusterIP Services like `backend`).

## Database: StatefulSet + PVC + credentials

- **StatefulSet, not Deployment.** Mongo is now a `StatefulSet`
  (`11-mongo-statefulset.yaml`) so its pod identity and storage are
  stable across restarts, rather than the fungible pod identity a
  Deployment gives you.
- **Persistent storage via `volumeClaimTemplates`.** Instead of one PVC
  manually defined and shared, the StatefulSet provisions and binds a
  dedicated PVC per pod automatically — here that's a single 1Gi PVC
  named `mongo-data-mongo-0`, bound to kind's default `standard`
  StorageClass (local-path-provisioner). Data survives pod restarts and
  rescheduling, but not `kind delete cluster`.
- **Credentials via Kubernetes Secret, config via ConfigMap.**
  `10-mongo-config.yaml` splits the two: `mongo-config` (ConfigMap) holds
  non-secret values (`MONGO_INITDB_DATABASE`, host, port); `mongo-credentials`
  (Secret) holds `MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD`,
  consumed by the official `mongo` image to create the root user on first
  init, and read by both StatefulSet probes for authenticated health
  checks.
- **Backend's `mongo_uri` now lives in `backend-secret`, not the
  ConfigMap** — once it embeds a real username/password it's a secret by
  definition. It must be kept in sync by hand with `mongo-credentials`
  (same username/password); see the comment in `20-backend-config.yaml`
  for why (distroless has no shell to interpolate the two at runtime) and
  what would remove that duplication later (External Secrets Operator /
  Vault).

## Deploy steps (on the EC2 instance)

```bash
# 1. Create the cluster (1 control-plane + 2 workers)
kind create cluster --name rent-a-ride --config kind-config.yaml

# 2. Fill in real secret values, either by editing the stringData blocks
#    in 10-mongo-config.yaml and 20-backend-config.yaml before applying,
#    or delete those Secret blocks and run:
kubectl create namespace rent-a-ride

kubectl create secret generic mongo-credentials -n rent-a-ride \
  --from-literal=MONGO_INITDB_ROOT_USERNAME=rentaride_admin \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD='<a real generated password>'

kubectl create secret generic backend-secret -n rent-a-ride \
  --from-literal=mongo_uri='mongodb://rentaride_admin:<same password>@mongo-0.mongo.rent-a-ride.svc.cluster.local:27017/rent-a-ride?authSource=admin' \
  --from-literal=ACCESS_TOKEN=... \
  --from-literal=REFRESH_TOKEN=... \
  --from-literal=CLOUD_NAME=... \
  --from-literal=API_KEY=... \
  --from-literal=API_SECRET=... \
  --from-literal=EMAIL_HOST=... \
  --from-literal=EMAIL_PASSWORD=... \
  --from-literal=RAZORPAY_KEY_ID=... \
  --from-literal=RAZORPAY_SECRET=...

# 3. Apply everything else
kubectl apply -k .
# (or individually: kubectl apply -f 00-namespace.yaml \
#    -f 10-mongo-config.yaml -f 11-mongo-statefulset.yaml \
#    -f 21-backend.yaml -f 30-frontend.yaml, skipping 10-/20-'s Secret
#    blocks if you used step 2's imperative Secrets instead)

# 4. Watch rollout - StatefulSet pods come up in order (mongo-0 first,
#    and only after it, would come mongo-1 etc. if replicas > 1)
kubectl -n rent-a-ride get pods -w

# 5. Verify
kubectl -n rent-a-ride get svc
kubectl -n rent-a-ride get pvc                     # mongo-data-mongo-0 should be Bound
kubectl -n rent-a-ride exec -it mongo-0 -- mongosh \
  -u <username> -p <password> --authenticationDatabase admin \
  --eval "db.adminCommand('ping')"
curl http://localhost:30300/healthz     # backend, direct
curl -I http://localhost:30080/         # frontend
```

Then open `http://<EC2-PUBLIC-IP>:30080` in a browser (make sure the EC2
security group allows inbound TCP 30080, and 30300 if you want direct
backend access).

## Notes / things to double check

- `ALLOWED_ORIGINS` in `20-backend-config.yaml` has a `<EC2-PUBLIC-IP>`
  placeholder — replace it with the real address before applying, or the
  backend's CORS check will reject the frontend's requests.
- The client image already has `VITE_PRODUCTION_BACKEND_URL` and friends
  baked in at build time (Jenkins build args), so there's nothing to
  configure at runtime for the frontend container itself.
- Swap `:latest` for a specific Jenkins `IMAGE_TAG` (build number) in
  `21-backend.yaml` / `30-frontend.yaml` if you want a pinned, reproducible
  deploy instead of always pulling whatever `latest` currently points to.
- `mongo-credentials` and `backend-secret`'s `mongo_uri` must use the
  **same** username/password — nothing enforces this automatically, so
  double-check both after filling in real values.
- The `mongo-data-mongo-0` PVC uses kind's default `standard` StorageClass
  (local-path-provisioner) — data persists across pod restarts and
  rescheduling, but not across `kind delete cluster`.
- These Secrets are plain `Opaque` Kubernetes Secrets — base64-encoded at
  rest, not encrypted, and readable by anyone with `get secrets` RBAC
  access in the namespace. Fine for this kind/EC2 setup; a real
  production cluster would add encryption at rest and/or an external
  secrets manager on top.
