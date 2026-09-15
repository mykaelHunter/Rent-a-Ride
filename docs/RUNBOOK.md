# Rent-a-Ride — Deployment Runbook

Practical, step-by-step instructions for every way this app is deployed.
Each section is self-contained — jump straight to the one you need.

1. [Local development](#1-local-development)
2. [EC2 + bastion, kind cluster (staging)](#2-ec2--bastion-kind-cluster-staging)
3. [ECS + ECR (production)](#3-ecs--ecr-production)
4. [EKS (production)](#4-eks-production)
5. [Static hosting: S3 + CloudFront](#5-static-hosting-s3--cloudfront)
6. [Monitoring](#6-monitoring)
7. [CI/CD (Jenkins + ArgoCD)](#7-cicd-jenkins--argocd)

---

## 1. Local development

### Option A — plain Node (fastest inner loop)

```bash
cd backend && cp .env.example .env   # fill in real values
npm install && npm run dev

cd client && cp .env.example .env
npm install && npm run dev
```

Needs a reachable MongoDB (local `mongod` or an Atlas URI in `backend/.env`'s
`mongo_uri`).

### Option B — Docker Compose (prod-parity, includes Mongo)

```bash
cp .env.example .env          # root-level, if you keep shared vars there
cp backend/.env.example backend/.env
docker compose up --build
```

This starts `mongo` (with a healthcheck), `backend` (waits for Mongo to be
healthy), and `client` (nginx, reverse-proxies `/api/` to `backend`). All
three log JSON to stdout with a 10MB × 3-file rotation cap.

- Frontend: `http://localhost` (port 80, or whatever `docker-compose.yml`'s
  `client` port mapping specifies)
- Backend direct: `http://localhost:3000`
- Mongo: `localhost:27017` (mapped for local tooling/inspection)

To pull the exact images Jenkins built instead of rebuilding locally:

```bash
BACKEND_IMAGE=mykaelhunter/rent-a-ride-backend IMAGE_TAG=<tag> docker compose pull
docker compose up
```

Stop and clean up:

```bash
docker compose down          # add -v to also drop the mongo-data volume
```

---

## 2. EC2 + bastion, kind cluster (staging)

Topology: a public **bastion** host (SSH jump box only) and a private **app
EC2** instance that runs a `kind` (Kubernetes-in-Docker) cluster. Nothing on
the app host is directly internet-reachable except through the bastion or
the app's own exposed ports.

### 2.1 Provision the infrastructure

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set allowed_ssh_cidr to your IP, confirm enable_bastion=true

terraform init
terraform apply -var="enable_ecs=false"   # keep this pass scoped to bastion+networking
```

Grab the SSH helpers:

```bash
terraform output -raw ssh_bastion_command
terraform output -raw ssh_app_command       # hops through the bastion automatically
```

The bastion module writes the private key to `infra/keys/<key_pair_name>.pem`
(0400, git-ignored). For repeat use, add an SSH config entry (see
`infra/README.md` → Usage) instead of retyping the full `ProxyCommand` each
time.

### 2.2 SSH to the app host and install prerequisites

```bash
$(terraform output -raw ssh_app_command)

# Fresh Ubuntu 24.04 needs the docker group refreshed in a NEW session
# (a bare `usermod -aG docker $USER` in the current shell will not take effect)
sudo usermod -aG docker $USER
exit
$(terraform output -raw ssh_app_command)   # reconnect

docker --version
kind version
kubectl version --client
```

### 2.3 Create the kind cluster

```bash
# copy k8s/ up to the app host (scp, git clone, or rsync), then:
cd k8s
kind create cluster --name rent-a-ride --config kind-config.yaml
kubectl create namespace rent-a-ride
```

### 2.4 Create Secrets — before anything else touches the cluster

```bash
MONGO_USER=rentaride_admin
MONGO_PASS=$(openssl rand -base64 24 | tr -d '"'\''`$\\')
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

> **Important:** `mongo-credentials` stores the raw, unencoded password
> (mongod auth uses it directly); the copy embedded in `mongo_uri` must be
> URL-encoded. Mixing these two up is what causes a `MongoParseError`
> crash-loop. Never paste a literal `REPLACE_ME`.

Verify before proceeding:

```bash
kubectl get secret mongo-credentials -n rent-a-ride -o jsonpath='{.data.MONGO_INITDB_ROOT_USERNAME}' | base64 -d; echo
kubectl get secret backend-secret -n rent-a-ride -o jsonpath='{.data.mongo_uri}' | base64 -d; echo
```

### 2.5 Edit the ConfigMap, then deploy everything else

Edit `k8s/20-backend-config.yaml`'s `ALLOWED_ORIGINS` to your app host's real
EC2 public IP (safe — it's a ConfigMap, not a Secret).

```bash
kubectl apply -k .
kubectl -n rent-a-ride get pods -w      # mongo-0 first, then backend/frontend
```

### 2.6 Verify

```bash
kubectl -n rent-a-ride get svc
kubectl -n rent-a-ride get pvc                     # mongo-data-mongo-0 should be Bound
curl http://localhost:30300/healthz                # backend, direct
curl -I http://localhost:30080/                    # frontend
```

Open `http://<EC2-PUBLIC-IP>:30080` (make sure the security group allows
inbound 30080, and 30300 for direct backend access).

### 2.7 Autoscaling (optional)

The HPAs (`22-backend-hpa.yaml`, `32-frontend-hpa.yaml`) are already applied
by step 2.5, but kind doesn't ship `metrics-server` by default:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

`--kubelet-insecure-tls` is a kind-only workaround (kind's kubelet certs have
no IP SANs) — remove it if this workload ever lands on a managed/real
cluster.

### 2.8 Single entry point via Ingress (optional, kind only)

> This section is for `kind` **only**. On EKS, the Helm chart creates its
> own Ingress backed by the AWS Load Balancer Controller — installing
> `ingress-nginx` there as well will break ALB Ingress syncs (see §4).

`41-ingress.yaml` is already applied; it does nothing until the controller
itself exists. **Use kind's own ingress-nginx install manifest, not the
generic cloud one** (the generic one is `type: LoadBalancer`, which never
gets an external IP on kind, and patching it to NodePort afterward silently
fails under real external traffic even though everything reports healthy).
Follow `k8s/README.md` → "Ingress (nginx Ingress controller, kind only)" for
the exact manifest URL and `kind-config.yaml`'s `hostNetwork` port mappings
(31080/31443).

### 2.9 Helm + ArgoCD instead of raw manifests

Once the cluster works with raw `k8s/` manifests, migrate to the Helm chart
(`helm/rent-a-ride/`) and let ArgoCD manage it going forward — see §7.

### 2.10 Blue/Green on this same host

`docs/blue-green-deployment.md` covers running two full app stacks (`blue`,
`green`) side by side against one shared Mongo, with an ALB switching which
one is live. The scripts in `cli/` (`blue-green-setup.sh`,
`blue-green-cutover.sh`, `migrate-to-blue.sh`, `create-alb.sh`) automate the
AWS side of this on top of the EC2+bastion topology.

---

## 3. ECS + ECR (production)

Fully managed — no servers to patch. Fargate tasks behind an
internet-facing ALB, images in ECR, secrets in Secrets Manager.

### 3.1 Push images to ECR

```bash
cd infra
terraform apply -target=module.networking -target=module.ecr

aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account_id>.dkr.ecr.us-east-1.amazonaws.com

aws_repo=$(terraform output -json ecr_repository_urls | jq -r '.backend')
docker build -t rent-a-ride-backend -f ../backend/Dockerfile ..
docker tag rent-a-ride-backend:latest "$aws_repo:latest"
docker push "$aws_repo:latest"
# repeat for frontend, using ../client/Dockerfile
```

### 3.2 Set secrets

```bash
terraform apply -target=module.ecs \
  -var='mongo_uri=mongodb+srv://user:pass@cluster0.xxxxx.mongodb.net/rent-a-ride' \
  -var-file=secrets.tfvars      # backend_secret_values map — see infra/README.md
```

Never commit `secrets.tfvars` — add it to `.gitignore` alongside
`terraform.tfvars`.

### 3.3 Apply the ECS module

```bash
terraform apply -target=module.ecs
```

First apply will fail health checks until real images exist in ECR (step 3.1
must run first).

### 3.4 Verify

```bash
aws ecs describe-clusters --clusters $(terraform output -raw ecs_cluster_name) --query 'clusters[0].status'

aws ecs describe-services --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_backend_service_name) $(terraform output -raw ecs_frontend_service_name) \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount}'

terraform output alb_dns_name
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups --names rent-a-ride-dev-backend-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
```

Both `running` should equal `desired`, and target health should read
`healthy`. If not, see `infra/modules/ecs/README.md` → Common issues
(wrong health-check port/path is the most common cause — non-root images
often listen above 1024).

### 3.5 Roll out a new image

```bash
terraform apply -target=module.ecs \
  -var="backend_image_tag=$GIT_SHA" \
  -var="frontend_image_tag=$GIT_SHA"
```

---

## 4. EKS (production)

Managed Kubernetes control plane; the same Helm chart used on kind, now
served through the AWS Load Balancer Controller instead of a NodePort/kind
ingress.

### 4.1 Provision the cluster

```bash
cd infra
terraform apply -var="enable_eks=true"
```

EKS uses **API auth mode** (access entries, not the legacy `aws-auth`
ConfigMap) — the applying identity is granted cluster-admin automatically.
Two known gotchas from the remediation history:

- The Load Balancer Controller's Helm release and the node group's own
  CoreDNS/CNI settling can outrace each other on a from-scratch cluster —
  a two-phase apply avoids it:
  ```bash
  terraform apply -target=module.eks
  terraform apply
  ```
- `terraform apply -target=module.eks` alone can silently skip a dependency
  with no direct attribute reference (e.g. the NAT gateway) — always follow
  a targeted apply with a full untargeted one once the reason for targeting
  is resolved.

### 4.2 Point kubectl at the cluster

```bash
terraform output configure_kubectl
aws eks update-kubeconfig --region <region> --name <cluster_name>
kubectl get nodes
```

### 4.3 Install the AWS Load Balancer Controller (if not already via the module's helm_release)

The `eks` module provisions the IRSA role and attempts a `helm_release`
automatically; if it times out (cluster networking still settling), retry
manually with `atomic = true`-equivalent behavior:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=<cluster_name> \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --timeout 10m
```

### 4.4 Confirm the default StorageClass

EKS's built-in default `gp2` StorageClass is non-functional out of the box
for this chart — `helm/rent-a-ride` ships its own `gp3` StorageClass
(`templates/storageclass.yaml`), which the chart marks as cluster-default.
Confirm it exists before deploying Mongo:

```bash
kubectl get storageclass
```

### 4.5 Deploy the app via Helm (or ArgoCD — see §7)

```bash
kubectl create secret generic mongo-credentials -n rent-a-ride --from-literal=... # same as §2.4
kubectl create secret generic backend-secret -n rent-a-ride --from-literal=...

helm upgrade --install rent-a-ride helm/rent-a-ride \
  -n rent-a-ride --create-namespace \
  -f helm/rent-a-ride/values.yaml
```

### 4.6 Verify Ingress / ALB

```bash
kubectl get ingress -n rent-a-ride
kubectl describe ingress rent-a-ride -n rent-a-ride    # look for the assigned ALB address
```

> **Never install `ingress-nginx` on this cluster.** The chart's Ingress
> uses `className: alb`, backed by the Load Balancer Controller — a second
> Ingress controller's cluster-wide admission webhook will intercept the ALB
> Ingress resource too and start failing `argocd app sync`/`kubectl apply`
> with a "no endpoints available" webhook error. If it's already installed
> by mistake: `helm uninstall <release> -n ingress-nginx`.

### 4.7 Blue/Green on EKS

`helm/rent-a-ride/templates/green-stack.yaml` and the
`rollout.enabled` / `backendGreen` / `frontendGreen` values blocks stand up
a parallel green Deployment+Service stack (off by default). When
`rollout.enabled: true`, the chart's Ingress switches to weighted
`alb.ingress.kubernetes.io/actions.*` forward rules, splitting traffic
between blue and green by percentage — a gradual, ALB-native canary/blue-green
instead of the EC2 setup's listener-swap approach.

---

## 5. Static hosting: S3 + CloudFront

Split-subdomain setup layered on top of the ECS deployment:
`app.<domain>` serves the built React app from a private S3 bucket via
CloudFront; `api.<domain>` points straight at the ECS ALB. Requires a domain
already hosted in Route53 in this AWS account, and `enable_ecs = true`.

```bash
cd infra
terraform apply \
  -var="enable_dns_ssl=true" \
  -var="domain_name=rentaride.example.com" \
  -var="frontend_bucket_name=rent-a-ride-frontend-<unique-suffix>"
```

This provisions:

- Two ACM certs — one in `us-east-1` (CloudFront requires this region
  specifically) for `app.<domain>`, one in your working region for
  `api.<domain>`'s ALB listener. Two certs, not one with SANs, because of
  that region split.
- A private S3 bucket (no public access — CloudFront reaches it via Origin
  Access Control) for `client/dist`.
- A CloudFront distribution in front of that bucket.
- Route53 alias records for both `app.` and `api.`.

Then build and publish the frontend:

```bash
cd client && npm run build && cd ..

aws s3 sync client/dist s3://$(terraform output -raw frontend_bucket_name) --delete

aws cloudfront create-invalidation \
  --distribution-id $(terraform output -raw cloudfront_distribution_id) \
  --paths "/index.html"   # hashed assets are long-cached; only index.html needs busting
```

The ECS frontend service (the nginx container) keeps running independently
of this — leave it on for direct ALB-path testing, or set
`enable_ecs_frontend = false` once `app.<domain>` is confirmed serving
traffic. There's no cost to leaving it deployed-but-unused.

**Not automated yet:** the `npm run build` → `s3 sync` → CloudFront
invalidation sequence above is manual. Wiring it into the Jenkins pipeline
as a post-build stage is a natural next step (see `infra/README.md` →
"What's not covered here").

---

## 6. Monitoring

Two independent stacks exist, matched to the two Kubernetes-hosting paths
(they are not mutually exclusive — both can run against the same kind
cluster if desired):

### 6.1 CloudWatch + Fluent Bit (EC2/kind path)

Host-level metrics come from the CloudWatch Agent running directly on the
app EC2 instance; pod/container logs come from a Fluent Bit DaemonSet
*inside* the kind cluster (kind's nodes are themselves Docker containers, so
pod logs live in the kind node's containerd — not somewhere a host-level
agent can tail them directly).

```bash
# 1. IAM + alarms + SNS topic (Terraform)
cd infra
terraform apply -var="enable_monitoring=true" \
  -var="alert_email=you@example.com" \
  -var="grafana_allowed_cidr=$(curl -s ifconfig.me)/32"
#    confirm the SNS email subscription before doing anything else —
#    unconfirmed subscriptions drop notifications silently.

# 2. CloudWatch Agent, on the app host
ssh <app-host>
sudo ./monitoring/cloudwatch/cloudwatch-agent/install-cwagent.sh

# 3. Fluent Bit, into the kind cluster
kubectl apply -f monitoring/fluent-bit/namespace.yaml
kubectl apply -f monitoring/fluent-bit/service-account.yaml
kubectl apply -f monitoring/fluent-bit/fluent-bit-configmap.yaml
kubectl apply -f monitoring/fluent-bit/fluent-bit-daemonset.yaml
```

Verify:

```bash
terraform output sns_topic_arn
terraform output alarm_names
terraform output -raw grafana_url    # NLB in front of the app host's Grafana NodePort
```

Metrics land under the `RentARide/App` CloudWatch namespace; alarms cover
CPU/memory/disk plus a log-metric-filter alarm on Fluent Bit-shipped app
logs (pino `level` 50/60, or a 5xx `res.statusCode`). Full architecture
diagram and a fill-in-as-you-go verification checklist are in
`monitoring/cloudwatch/docs/MONITORING.md`.

This stack only covers the EC2/kind app host — it does not monitor ECS or
EKS.

### 6.2 Prometheus + Grafana (Kubernetes path — kind or EKS)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f monitoring/prometheus-grafana/helm-values-kube-prometheus-stack.yaml

kubectl apply -f monitoring/prometheus-grafana/ingress-nginx-servicemonitor.yaml
kubectl apply -f monitoring/prometheus-grafana/dashboards/rentaride-app-dashboard-configmap.yaml
```

On kind, the values file excludes ServiceMonitors that assume cloud-managed
components kind doesn't have. Direct Grafana access on the EC2/kind path
goes through the same NLB used by the CloudWatch stack
(`monitoring/prometheus-grafana/grafana-nlb.tf`); on EKS, front Grafana with
the AWS Load Balancer Controller Ingress instead.

Generate test load to confirm dashboards populate:

```bash
./monitoring/prometheus-grafana/scripts/generate-traffic.sh
```

Before trusting any newly-wired target as "working," query for actual data,
not just target health — a target can scrape HTTP 200 while returning none
of the metrics a dashboard expects:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090
curl 'http://localhost:9090/api/v1/query?query=up'
```

Full setup steps, target/connection verification, and kind-specific gotchas
are in `monitoring/prometheus-grafana/docs/PROMETHEUS_GRAFANA.md`.

**Known gap:** dashboards here are infra/Kubernetes-level (pod CPU/memory,
request counts at the ingress). True per-request backend latency/error-rate
metrics need a `/metrics` endpoint added to the backend via `prom-client` —
tracked as an open item, not yet built.

---

## 7. CI/CD (Jenkins + ArgoCD)

### 7.1 Jenkins (CI, and CD for the Compose path)

Setup: `docs/JENKINS_SETUP.md`. Pipeline: `Jenkinsfile` — GitHub webhook
triggers a build, images are pushed to Docker Hub
(`mykaelhunter/rent-a-ride-backend` / `-client`), then (for the
Compose/EC2 target) pulled and rolled out via `docker compose up`, with old
local images cleaned up afterward.

### 7.2 ArgoCD (GitOps for kind/EKS)

```bash
./argocd/install/install-argocd.sh   # installs ArgoCD + Image Updater, waits for rollout

kubectl create secret generic git-creds -n argocd \
  --from-literal=username=<github-username> \
  --from-literal=password=<fine-grained-PAT-with-contents-readwrite>

kubectl apply -f argocd/applications/rent-a-ride.yaml
kubectl apply -f argocd/applications/image-updater.yaml
```

Image Updater watches the `backend`/`frontend` images on Docker Hub and
commits new tags directly into `helm/rent-a-ride/values.yaml` — the same
file `helm lint`/`helm template` read directly, so `git log` on that file is
a complete, human-readable deploy history with no ArgoCD-only state.

Log in to the UI/CLI:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Full detail (including the note on why Image Updater's CRD-driven
architecture needs its own `ImageUpdater` object) is in `argocd/README.md`.
