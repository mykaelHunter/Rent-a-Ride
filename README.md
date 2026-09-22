
# Rent-a-Ride

A full-stack car rental platform (User / Admin / Vendor modules) — originally a
MERN portfolio app — taken through a full production-hardening and
multi-cloud deployment pipeline as an Expadox Mentorship Lab capstone-style
project. This README covers the application itself and everything built on
top of it: containerization, CI/CD, Kubernetes, GitOps, blue/green
deployments, four independent deployment paths (local, EC2+bastion, ECS
Fargate, EKS), static hosting via S3+CloudFront, and full observability.

For the deep "how do I actually deploy this" instructions, see
**[`RUNBOOK.md`](docs/RUNBOOK.md)**. For the system diagrams, see
**[`ARCHITECTURE.md`](docs/ARCHITECTURE.md)**. For the complete, incident-by-incident
history of every bug found and fixed along the way, see
**[`docs/incident-log.md`](docs/incident-log.md)** and
**[`docs/blue-green-deployment.md`](docs/blue-green-deployment.md)**.

---

## 1. The application

**Modules:** User, Admin, Vendor — vehicle browsing/booking, order
management, vendor vehicle listings and approvals, admin dashboard and
moderation.

**Frontend (`client/`):** React (Vite), Redux Toolkit, Tailwind CSS, React
Hook Form + Zod validation, Google OAuth, Razorpay payments.

**Backend (`backend/`):** Node.js, Express, MongoDB (Mongoose), JWT
access/refresh tokens, role-based access control, Multer uploads,
Cloudinary media storage, Nodemailer email notifications, pino structured
logging.

### Local development (no Docker)

```bash
cd backend && npm install && npm run dev
cd client  && npm install && npm run dev
```

See `RUNBOOK.md` → Local development for the Docker Compose route
(recommended — matches prod parity, gives you Mongo for free).

---

## 2. What was built on top of the app

The application code was already functional but had never been reviewed for
production readiness. A full pre-deployment review and remediation pass
(documented in `docs/incident-log.md` — 86 tracked incidents, INC-001
through INC-086) found and fixed **8 Critical**, plus a large number of
High/Medium severity issues, before anything was containerized or deployed.
A handful of Medium/Low items are intentionally left open (see
[Known open items](#5-known-open-items-not-blockers)).

On top of that remediation, the following was added, layer by layer:

| Layer | What | Where |
|---|---|---|
| **Containerization** | Multi-stage, non-root Dockerfiles for backend and client (nginx), `.dockerignore`, Compose for local parity | `backend/Dockerfile`, `client/Dockerfile`, `client/nginx.conf`, `docker-compose.yml` |
| **CI** | Jenkins pipeline: GitHub webhook → build → push to Docker Hub | `Jenkinsfile`, `docs/JENKINS_SETUP.md` |
| **CD (compose)** | Pull + `docker compose up` + image cleanup | `Jenkinsfile` (CD stage) |
| **Local Kubernetes (kind)** | Namespace, Mongo StatefulSet w/ PVC, backend/frontend Deployments, HPAs, Ingress | `k8s/` |
| **Helm** | Every manifest converted into a parameterised chart | `helm/rent-a-ride/` |
| **GitOps** | ArgoCD + Image Updater watching Docker Hub, writing new tags into `values.yaml` | `argocd/` |
| **AWS infra (Terraform)** | VPC/networking, bastion + private app EC2 (kind host), ECR, ECS Fargate, EKS, ACM/Route53, CloudFront+S3, monitoring — all as toggleable modules | `infra/` |
| **Blue/Green** | Two isolated namespaces/releases sharing one Mongo, ALB-level cutover | `docs/blue-green-deployment.md`, `helm/rent-a-ride/templates/green-stack.yaml`, `cli/blue-green-*.sh` |
| **AWS ECS migration** | Fargate cluster, path-based ALB routing, Secrets Manager wiring | `infra/modules/ecs/`, `infra/modules/ecr/` |
| **AWS EKS migration** | Managed node group, EBS CSI (IRSA), AWS Load Balancer Controller, gp3 default StorageClass | `infra/modules/eks/` |
| **Static hosting** | `client/dist` on S3, served via CloudFront, ACM certs, Route53 records | `infra/modules/cloudfront-s3/`, `infra/modules/acm/`, `infra/modules/route53/` |
| **Monitoring — EC2/kind path** | CloudWatch Agent (host metrics), Fluent Bit (pod logs), CloudWatch alarms, SNS alerts, Grafana via NLB | `monitoring/cloudwatch/`, `infra/modules/monitoring/` |
| **Monitoring — Kubernetes path** | kube-prometheus-stack (Prometheus + Grafana), ingress-nginx ServiceMonitor, custom app dashboard | `monitoring/prometheus-grafana/` |

## 3. Repository layout

```
Rent-a-Ride/
├── backend/            Express API (MVC, JWT auth, Mongo/Mongoose)
├── client/             React (Vite) frontend
├── docs/               Incident log, Jenkins setup, blue/green runbook,
│                       architecture diagrams and runbook
├── k8s/                Raw Kubernetes manifests for kind (local/EC2)
├── helm/rent-a-ride/   Helm chart used everywhere from kind onward
├── argocd/             ArgoCD Application + Image Updater config
├── infra/              Terraform (networking, bastion, ecr, ecs, eks,
│                       monitoring, acm, cloudfront-s3, route53)
├── cli/                Blue/green + ALB helper shell scripts
├── monitoring/         CloudWatch and Prometheus/Grafana stacks (+ docs)
├── Jenkinsfile         CI/CD pipeline definition
├── docker-compose.yml  Local/single-host multi-container run

```

## 4. Deployment paths at a glance

Rent-a-Ride can be run four different ways, each documented in full in
`RUNBOOK.md`:

1. **Local (dev)** — Docker Compose on a single machine, or `npm run dev`
   for both services directly against a local/Atlas Mongo.
2. **EC2 + bastion (staging)** — a private EC2 instance running `kind`,
   reached only through a public bastion host; Terraform-provisioned VPC,
   NAT, security groups.
3. **ECS + ECR (production)** — Fargate cluster behind an internet-facing
   ALB, images in ECR, secrets in Secrets Manager, no servers to patch.
4. **EKS (production)** — managed Kubernetes, the same Helm chart deployed
   via ArgoCD, AWS Load Balancer Controller, blue/green rollout support.

A fifth piece — **S3 + CloudFront static hosting** for the built frontend,
with the API still served from the ALB — is layered on top of the ECS path
and documented alongside it.

## 5. Known open items (not blockers)

Carried forward from `docs/incident-log.md`'s Open Issues section — none
of these block deployment on their own:

- **INC-009** — inconsistent cookie attributes across auth flows (needs a
  single cookie-vs-bearer-token decision).
- **INC-010** — no request validation layer (e.g. zod) on auth/user
  endpoints yet.
- **INC-012 / INC-013** — deprecated `Buffer.from`, duplicated upload
  helpers in `multer.js`.
- **INC-014** — mixed Vite + Create React App tooling in `client/package.json`.
- **INC-016 / INC-017** — typos in error responses, stray commented-out code.
- **INC-018** — `RAZORPAY_KEY_ID` needs the `VITE_` prefix to reach the client build.
- **INC-027** — known vulnerabilities in `nodemailer`, `image-size`, `uuid`
  (needs a breaking-change upgrade pass with regression testing).
- A true `/metrics` endpoint on the backend (prom-client) is still missing —
  current Prometheus/Grafana dashboards are infra/Kubernetes-level, not
  per-request app metrics.
- Mongo's PVC on EKS can still be stranded if AWS reclaims a SPOT node in a
  different AZ (INC-083) — worked around, not structurally fixed. Pinning
  the node group to one AZ or moving stateful workloads to an ON_DEMAND
  node group are the two fixes under consideration.

Full detail, root causes, and the fix for every one of the 86 tracked
incidents — resolved and open — is in `docs/incident-log.md`.

## 6. Screenshots

See the original application screenshots below (unchanged from the app's
initial build).

//user
<img width="1440" alt="Screenshot 2024-04-06 at 3 06 32 PM" src="https://github.com/user-attachments/assets/4b769f7d-5d2c-43a7-8283-07fa8402de92">
<img width="1430" alt="Screenshot 2024-12-10 at 12 35 41 AM" src="https://github.com/user-attachments/assets/5d6e0160-5f1d-4e67-a64e-1e18fb17a590">
<img width="1425" alt="Screenshot 2024-12-10 at 12 35 58 AM" src="https://github.com/user-attachments/assets/ac6b0f33-344e-4009-a979-23ea7dc3a5bb">
<img width="1430" alt="Screenshot 2024-12-10 at 12 36 15 AM" src="https://github.com/user-attachments/assets/40e2dc7d-0694-483d-bf4a-badac9c4d5f3">
<img width="1426" alt="Screenshot 2024-12-10 at 12 36 28 AM" src="https://github.com/user-attachments/assets/7ce5d1fa-c51f-414b-92da-cc04ac7c3402">
<img width="1428" alt="Screenshot 2024-12-10 at 1 59 45 AM" src="https://github.com/user-attachments/assets/0e87009c-832d-4c5e-be7c-ecd4df341070">
<img width="1408" alt="Screenshot 2024-12-10 at 2 00 01 AM" src="https://github.com/user-attachments/assets/baf15b5d-2e04-4410-803b-527dddda1aab">

//Admin
<img width="1418" alt="Screenshot 2024-12-10 at 2 01 09 AM" src="https://github.com/user-attachments/assets/c08e3bf0-2776-4236-80b6-6714d52ec8d7">
<img width="1421" alt="Screenshot 2024-12-10 at 2 04 29 AM" src="https://github.com/user-attachments/assets/ce6dada8-41b7-4aec-b86a-4a359f6d339f">
<img width="1431" alt="Screenshot 2024-12-10 at 2 04 42 AM" src="https://github.com/user-attachments/assets/467503a4-ab9a-4396-bc57-1abff5fe8106">
<img width="1418" alt="Screenshot 2024-12-10 at 2 05 02 AM" src="https://github.com/user-attachments/assets/8e1d2948-6316-420b-8336-30ec7c752b04">

//vendor
<img width="1418" alt="Screenshot 2024-12-10 at 2 05 02 AM" src="https://github.com/user-attachments/assets/59a9a9c7-5dc1-4f61-8d15-43266579386c">
<img width="1432" alt="Screenshot 2024-12-10 at 2 08 00 AM" src="https://github.com/user-attachments/assets/4e9d8f66-0984-4163-8dea-f9023db56ce0">

## 7. Credits

Original application by jeevan-aj. Production hardening, containerization,
Kubernetes/Helm/ArgoCD, AWS infrastructure (bastion/EC2, ECS, EKS,
CloudFront+S3), blue/green deployment, and monitoring by Hunter
(Egbuatu Silas Odinaka) as part of the Expadox Mentorship Lab.
