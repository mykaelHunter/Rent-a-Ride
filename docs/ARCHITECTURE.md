# Rent-a-Ride — Architecture

Diagrams for the application itself and for each of its deployment
topologies. See `RUNBOOK.md` for the commands behind each of these.

## 1. Application architecture (all environments)

```
┌───────────────────────┐        ┌────────────────────────────┐
│  Client (React/Vite)  │  HTTP  │  Backend (Express/Node)     │
│  served by nginx       │ ─────► │  /api/* routes              │
│  (or CDN, see §5)      │        │  JWT access+refresh, RBAC   │
└───────────────────────┘        └───────────┬────────────────┘
                                              │
                     ┌────────────────────────┼─────────────────────┐
                     ▼                        ▼                     ▼
             ┌───────────────┐      ┌──────────────────┐   ┌────────────────┐
             │  MongoDB       │      │  Cloudinary       │   │  Nodemailer /  │
             │  (Mongoose)    │      │  (media storage)  │   │  Razorpay      │
             └───────────────┘      └──────────────────┘   └────────────────┘
```

The frontend's own nginx (or, in the ECS/EKS/S3 paths, an ALB/CloudFront)
reverse-proxies `/api/*` straight through to the backend — no rewrite is
needed since the Express app already mounts its routes under `/api`.

---

## 2. Local development

```
┌─────────────────────────── developer machine ───────────────────────────┐
│                                                                          │
│   docker compose                                                        │
│   ┌───────────┐   ┌────────────────┐   ┌─────────────────────────┐     │
│   │  mongo:7  │◄──│ backend (node) │◄──│ client (nginx + built    │     │
│   │ :27017    │   │ :3000          │   │ React app) :80           │     │
│   └───────────┘   └────────────────┘   └─────────────────────────┘     │
│         ▲                  ▲                        │                   │
│         └── mongo-data vol │            /api/* proxied to backend       │
│                     healthcheck-gated startup order                    │
└──────────────────────────────────────────────────────────────────────────┘
```

`backend` waits on `mongo`'s healthcheck; `client`'s nginx starts once
`backend` is reachable. All three containers log JSON with rotation
(10MB × 3 files) so a long dev session doesn't fill disk.

---

## 3. EC2 + bastion, kind cluster (staging)

```
                                  Internet
                                      │
                            ┌─────────▼─────────┐
                            │ Internet Gateway   │
                            └─────────┬─────────┘
   VPC 10.0.0.0/16                    │
   ┌──────────────────────────────────┴───────────────────────────────┐
   │  Public subnet (AZ-a)                                             │
   │  ┌──────────────┐                              ┌────────────────┐│
   │  │   Bastion     │  SSH (22) only               │  NAT Gateway   ││
   │  │   t3.micro    │──────────────┐               │   + EIP        ││
   │  └──────────────┘               │               └────────┬───────┘│
   ├──────────────────────────────────┼────────────────────────┼───────┤
   │  Private subnet (AZ-a)           ▼                        │       │
   │                          ┌──────────────────────────┐     │       │
   │                          │  App EC2 (t3a.medium)     │◄────┘ egress │
   │                          │  runs `kind` cluster:      │              │
   │                          │  ┌──────────────────────┐ │              │
   │                          │  │ kind control-plane +  │ │              │
   │                          │  │ 2 workers (Docker)     │ │              │
   │                          │  │  - mongo-0 StatefulSet │ │              │
   │                          │  │    (PVC)               │ │              │
   │                          │  │  - backend Deployment  │ │              │
   │                          │  │    + HPA                │ │              │
   │                          │  │  - frontend Deployment │ │              │
   │                          │  │    (nginx) + HPA        │ │              │
   │                          │  │  - ingress-nginx        │ │              │
   │                          │  │    (hostNetwork)        │ │              │
   │                          │  └──────────────────────┘ │              │
   │                          │  NodePorts: 30080 (front), │              │
   │                          │  30300 (backend, debug),   │              │
   │                          │  31080/31443 (ingress)      │              │
   │                          └──────────────────────────┘              │
   └────────────────────────────────────────────────────────────────────┘
```

Access path: `you → SSH bastion → SSH app host (ProxyJump)` for
administration; `you → http://<app-host-public-or-EIP>:30080` (or `:31080`
via Ingress) for the app itself, gated by the app host's security group.

Blue/Green on this same host (see `docs/blue-green-deployment.md`) adds a
second full namespace (`green`) alongside `blue`, plus an ALB in front with
two target groups (`tg-blue` :30080/hc:30300, `tg-green` :30081/hc:30301)
and one live `:80` listener whose default action is what actually decides
which color serves traffic:

```
                    ALB  :80 (live) ──► ONE of tg-blue / tg-green
                         :8080 (always) ──► tg-blue   (test listener)
                         :8081 (always) ──► tg-green  (test listener)
                              │                    │
                    ┌─────────▼─────────┐ ┌─────────▼─────────┐
                    │ ns: blue           │ │ ns: green          │
                    │ frontend+backend   │ │ frontend+backend   │
                    │ mongo (real data)  │ │ (mongo.enabled=false,
                    │                     │ │  points at blue's   │
                    │                     │ │  mongo across ns)   │
                    └────────────────────┘ └────────────────────┘
```

---

## 4. ECS + ECR (production)

```
                                  Internet
                                      │
                            ┌─────────▼─────────┐
                            │ Internet Gateway   │
                            └─────────┬─────────┘
   VPC 10.0.0.0/16                    │
   ┌──────────────────────────────────┴───────────────────────────────┐
   │  Public subnets (AZ-a, AZ-b)                                      │
   │           ┌───────────────────────┐        ┌────────────────┐    │
   │           │  ALB (internet-facing) │        │  NAT Gateway   │    │
   │           │  :80 / :443             │        │   + EIP        │    │
   │           └───────────┬────────────┘        └────────┬───────┘   │
   │           path /api/* │  else                          │egress    │
   ├───────────────────────┼────────────────────────────────┼─────────┤
   │  Private subnets (AZ-a, AZ-b)                           ▼         │
   │           ┌────────────▼───────────┐   ┌────────────────────┐    │
   │           │ ECS Fargate: backend    │   │ ECS Fargate:        │    │
   │           │ task, :3000, no public  │   │ frontend task, :8080│    │
   │           │ IP, target group A      │   │ target group B      │    │
   │           └────────────────────────┘   └────────────────────┘    │
   └────────────────────────────────────────────────────────────────────┘

   ┌──────────────┐   ┌───────────────────┐   ┌─────────────────────┐
   │  ECR          │   │ Secrets Manager    │   │ CloudWatch Logs      │
   │  backend repo │   │ mongo_uri +        │   │ /ecs/<project>/      │
   │  frontend repo│   │ backend_secret_*   │   │ backend, /frontend   │
   └──────────────┘   └───────────────────┘   └─────────────────────┘
```

Both ECS security group and task execution role are scoped tight: the ECS
tasks only accept traffic from the ALB's security group, and the execution
role's `secretsmanager:GetSecretValue` is scoped to just the secret ARNs
actually referenced — not `*`.

---

## 5. EKS (production) — with optional Blue/Green

```
                                  Internet
                                      │
                            ┌─────────▼─────────┐
                            │ Internet Gateway   │
                            └─────────┬─────────┘
   VPC                                │
   ┌──────────────────────────────────┴───────────────────────────────┐
   │  Public subnets                 Private subnets                   │
   │  ┌──────────────┐         ┌─────────────────────────────────────┐│
   │  │ EKS control   │         │  Managed node group (SPOT,           ││
   │  │ plane (managed│         │  t3a.medium x3)                       ││
   │  │ by AWS)       │         │  ┌─────────────────────────────────┐ ││
   │  └──────────────┘         │  │ AWS Load Balancer Controller     │ ││
   │                            │  │ (IRSA) — creates/manages an ALB  │ ││
   │                            │  │ from the chart's Ingress          │ ││
   │                            │  ├─────────────────────────────────┤ ││
   │                            │  │ EBS CSI driver (IRSA) + gp3       │ ││
   │                            │  │ StorageClass (chart-owned,        │ ││
   │                            │  │ replaces non-functional gp2)      │ ││
   │                            │  ├─────────────────────────────────┤ ││
   │                            │  │ helm/rent-a-ride release:         │ ││
   │                            │  │  mongo StatefulSet (PVC/gp3)      │ ││
   │                            │  │  backend Deployment + HPA          │ ││
   │                            │  │  frontend Deployment + HPA         │ ││
   │                            │  │  (+ green-stack.yaml, optional,    │ ││
   │                            │  │   see below)                       │ ││
   │                            │  └─────────────────────────────────┘ ││
   │                            └─────────────────────────────────────┘│
   └────────────────────────────────────────────────────────────────────┘
                            ▲
                            │ syncs from git
                    ┌───────┴────────┐        ┌───────────────────────────┐
                    │  ArgoCD          │◄───────│  ArgoCD Image Updater     │
                    │  Application     │  writes│  watches Docker Hub tags, │
                    │  (helm/rent-a-   │  new   │  commits into values.yaml │
                    │   ride source)   │  tags  │                            │
                    └─────────────────┘        └───────────────────────────┘
```

With `rollout.enabled: true`, the chart's Ingress switches from a single
forward rule to weighted `alb.ingress.kubernetes.io/actions.*` rules,
splitting traffic by percentage between the primary (blue) and
`green-stack.yaml`'s parallel Deployment+Service set:

```
        ALB Ingress (className: alb)
              │
   weighted actions.rent-a-ride-rollout
     ┌─────────────┴─────────────┐
     │ N%                    100-N%│
     ▼                             ▼
┌───────────┐               ┌───────────┐
│ backend    │               │ backend    │
│ frontend   │               │ frontend   │
│ (blue,     │               │ (green,    │
│  primary)  │               │  candidate)│
└───────────┘               └───────────┘
```

Image Updater deliberately excludes `blue` from automatic tracking (only
`backend-green`/`frontend-green` are updated automatically against Jenkins
build-number tags) — promoting green to blue stays a manual, deliberate
step.

> **Do not** install `ingress-nginx` on this cluster — its cluster-wide
> admission webhook intercepts every Ingress write, including the ALB
> Controller's, and breaks `argocd app sync` once the second controller's
> pod isn't answering it.

---

## 6. Static hosting: S3 + CloudFront (layered on the ECS path)

```
                            Route53 (hosted zone)
                    ┌───────────────┴────────────────┐
             app.<domain>                       api.<domain>
                    │                                  │
                    ▼                                  ▼
        ┌───────────────────────┐         ┌─────────────────────────┐
        │  CloudFront             │         │  ALB (from §4)           │
        │  (ACM cert, us-east-1)  │         │  (ACM cert, app region)  │
        └───────────┬────────────┘         └────────────┬────────────┘
                    │ Origin Access Control              │ path /api/*
                    ▼                                    ▼
        ┌───────────────────────┐         ┌─────────────────────────┐
        │  S3 bucket (private)    │         │  ECS Fargate: backend    │
        │  client/dist            │         │  task (unchanged)        │
        └───────────────────────┘         └─────────────────────────┘
```

Two separate ACM certs are required (not one cert with SANs): CloudFront
only accepts a certificate issued in `us-east-1`, while the ALB listener
needs one issued in whatever region the ALB itself runs in. The ECS
frontend service (nginx serving the built app) keeps running independently
of this path — it's not required once `app.<domain>` is live, but costs
nothing to leave deployed for direct-ALB testing.

---

## 7. Monitoring architecture

### 7.1 EC2/kind path — CloudWatch + Fluent Bit

```
┌──────────────────────────────── app EC2 host ─────────────────────────────┐
│                                                                            │
│  CloudWatch Agent (host process)        kind cluster (Docker containers)  │
│   - cpu/mem/disk/diskio/net metrics       ┌───────────────────────────┐   │
│     → CW namespace RentARide/App          │ Fluent Bit DaemonSet      │   │
│   - /var/log/syslog, auth.log,            │  tails /var/log/containers│   │
│     docker.log → CW Logs                   │  → CW Logs (app+cluster) │   │
│                                             └───────────────────────────┘   │
│  Both use the instance's IAM role (CloudWatchAgentServerPolicy) via IMDS  │
└────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
                CloudWatch Alarms (CPU / memory / disk / app-error filter)
                                      │
                                      ▼
                     SNS Topic: rent-a-ride-monitoring-alerts
                                      │
                                      ▼
                              Email subscription
                                      
                (Grafana on the app host, reached via an internet-facing
                 NLB restricted to grafana_allowed_cidr, for dashboards)
```

Pod logs are shipped by an in-cluster Fluent Bit DaemonSet rather than the
host-level CloudWatch Agent, because kind's nodes are themselves Docker
containers — pod/container logs live in the kind node's own containerd, not
in a file the host agent can tail.

### 7.2 Kubernetes path (kind or EKS) — Prometheus + Grafana

```
┌───────────────────────────── Kubernetes cluster ─────────────────────────┐
│                                                                            │
│  kube-prometheus-stack                                                    │
│   ┌───────────────┐   scrapes   ┌─────────────────────────────────┐      │
│   │  Prometheus    │◄────────────│  ServiceMonitors:                │      │
│   │  (+ Alertmgr)  │             │   - ingress-nginx (kind only)     │      │
│   └───────┬────────┘             │   - node/kube-state-metrics       │      │
│           │                       └─────────────────────────────────┘      │
│           ▼                                                                │
│   ┌───────────────┐                                                        │
│   │  Grafana        │  auto-loads: rentaride-app-dashboard (ConfigMap      │
│   │                 │  sidecar) — infra/Kubernetes panels, honestly-scoped │
│   └───────────────┘  application panels (no true per-request metrics yet) │
└────────────────────────────────────────────────────────────────────────────┘
```

On kind, Grafana is reached via the same NLB as the CloudWatch stack
(§7.1); on EKS, front it with an Ingress through the AWS Load Balancer
Controller instead. A genuine backend `/metrics` endpoint (via
`prom-client`) is the tracked gap that would let this stack show real
per-request latency/error rate instead of infra-level signals only.
