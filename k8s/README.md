# Rent-a-Ride on kind (EC2)

Manifests to run Rent-a-Ride on a `kind` cluster on your EC2 instance,
pulling the images your Jenkins pipeline already pushed to Docker Hub
(`mykaelhunter/rent-a-ride-backend`, `mykaelhunter/rent-a-ride-client`).

## Files

| File | Purpose |
|---|---|
| `kind-config.yaml` | 1 control-plane + 2 worker node cluster, with host ports 30080/30300 mapped in |
| `00-namespace.yaml` | `rent-a-ride` namespace |
| `10-mongo.yaml` | Mongo 7 Deployment + PVC + ClusterIP Service (`mongo:27017`) |
| `20-backend-config.yaml` | Backend ConfigMap (non-secret) + Secret (fill in real values) |
| `21-backend.yaml` | Backend Deployment + ClusterIP Service (`backend:3000`) + NodePort (30300, debug) |
| `30-frontend.yaml` | Frontend (nginx) Deployment + NodePort Service (30080, main entry point) |
| `kustomization.yaml` | Lets you `kubectl apply -k .` everything at once |

## Pod communication

- Frontend's nginx.conf (baked into the client image) proxies `/api/` to
  `http://backend:3000` — this resolves via in-cluster DNS as long as the
  backend Service is literally named `backend` in the same namespace,
  which it is here.
- Backend's `mongo_uri` (in `backend-config` ConfigMap) points at
  `mongodb://mongo:27017/rent-a-ride` — same DNS mechanism, resolving to
  the `mongo` Service.
- All three tiers live in the `rent-a-ride` namespace so short DNS names
  (`mongo`, `backend`) resolve without needing the `.svc.cluster.local`
  suffix.

## Deploy steps (on the EC2 instance)

```bash
# 1. Create the cluster (1 control-plane + 2 workers)
kind create cluster --name rent-a-ride --config kind-config.yaml

# 2. Fill in real secret values, either by editing 20-backend-config.yaml's
#    stringData block before applying, or delete that Secret block and run:
kubectl create namespace rent-a-ride
kubectl create secret generic backend-secret -n rent-a-ride \
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
# (or individually: kubectl apply -f 00-namespace.yaml -f 10-mongo.yaml \
#    -f 21-backend.yaml -f 30-frontend.yaml, skipping 20- if you used
#    step 2's imperative Secret)

# 4. Watch rollout
kubectl -n rent-a-ride get pods -w

# 5. Verify
kubectl -n rent-a-ride get svc
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
- `mongo-data` PVC uses kind's default `standard` StorageClass
  (local-path-provisioner) — data persists across pod restarts but not
  across `kind delete cluster`.
