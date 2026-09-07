# Rent-a-Ride — infra

Terraform for Rent-a-Ride's AWS infrastructure, now split into modules so
each piece (networking, bastion, ECR, ECS) can be reasoned about — and
applied — on its own.

## Layout

```
infra/
├── main.tf                # composes the modules below
├── variables.tf           # project-wide vars + per-module enable_* toggles
├── outputs.tf             # aggregated outputs from every module
├── provider.tf
├── versions.tf
├── terraform.tfvars.example
└── modules/
    ├── networking/  # VPC, public/private subnets (2 AZs each), IGW, NAT, routing
    ├── bastion/     # bastion + private app EC2 host (the pre-ECS kind setup)
    ├── monitoring/  # CloudWatch alarms, SNS alerts, Grafana NLB for the app host
    ├── ecr/         # ECR repositories (backend, frontend) + lifecycle policies
    └── ecs/         # Fargate cluster, ALB, task defs, services for backend/frontend
```

`networking` is the only module every other module depends on, so it's
always created. `bastion`, `monitoring`, `ecr`, and `ecs` are each wrapped
in a `count = var.enable_x ? 1 : 0`, so they can be switched on/off per
apply. `monitoring` additionally requires `enable_bastion = true` (it
monitors the app EC2 host, not ECS), and is skipped automatically if
bastion is off even when `enable_monitoring = true`.

The CloudWatch Agent IAM instance profile lives inside the `bastion`
module (not `monitoring`) and is attached directly to `aws_instance.app`.
That's because `monitoring` needs the app host's instance ID, and
`bastion` would need `monitoring`'s instance-profile name back - two
modules each waiting on the other's output is a dependency cycle
Terraform can't resolve. Same reasoning for the Grafana NodePort security
rule: it's a `dynamic` ingress block on `bastion`'s existing private
security group (toggled by `grafana_allowed_cidr`/`grafana_nodeport`),
not a separate `aws_security_group_rule` in `monitoring` - mixing the two
on one security group causes the AWS provider to fight over the rule set.

## Topology

```
                              Internet
                                  │
                        ┌─────────▼─────────┐
                        │  Internet Gateway │
                        └─────────┬─────────┘
                                  │
   VPC 10.0.0.0/16                │
   ┌─────────────────────────────┴──────────────────────────────┐
   │  Public subnets (AZ-a, AZ-b)                                │
   │  ┌────────────┐  ┌───────────┐        ┌────────────────┐   │
   │  │  Bastion   │  │    ALB    │        │  NAT Gateway   │   │
   │  │ t3.micro   │  │  (ECS)    │        │   (+ EIP)      │   │
   │  └─────┬──────┘  └─────┬─────┘        └────────┬───────┘   │
   │        │ SSH (22)      │ HTTP(S)               │ outbound   │
   ├────────┼───────────────┼───────────────────────┼───────────┤
   │  Private subnets (AZ-a, AZ-b)                               │
   │        ▼               ▼                                   │
   │  ┌───────────┐   ┌─────────────────────────────┐           │
   │  │  App EC2  │   │ ECS Fargate tasks             │           │
   │  │ (legacy)  │   │ backend :3000  frontend :80   │           │
   │  └───────────┘   └─────────────────────────────┘           │
   └───────────────────────────────────────────────────────────┘
```

- Public subnets route `0.0.0.0/0` → Internet Gateway; private subnets
  route `0.0.0.0/0` → the (single, shared) NAT Gateway.
- The networking module now provisions **two** public and **two** private
  subnets (one pair per AZ) instead of one of each — an ALB requires
  subnets in at least two AZs. The bastion module still only uses subnet
  `[0]` from each list, so its behavior is unchanged.
- ALB listens on 80 (and 443 if `acm_certificate_arn` is set); path
  `/api/*` routes to the backend target group, everything else to the
  frontend target group.
- ECS tasks run in the private subnets with no public IP — the ALB is the
  only ingress path, and the NAT Gateway handles egress (pulling images
  from ECR, calling out to MongoDB, etc.).
- ECS security group only accepts traffic on the container ports from the
  ALB's security group.

## Applying only specific modules

Each optional module has an `enable_*` toggle in `variables.tf`
(`enable_bastion`, `enable_ecr`, `enable_ecs`), all `true` by default.
Two ways to scope an apply:

**1. Toggle vars** — cleanest when you want a module fully skipped
(no plan, no resources touched):

```bash
# Only stand up networking + ECR (e.g. first run, before ECS is ready)
terraform apply -var="enable_bastion=false" -var="enable_ecs=false"

# Bastion is decommissioned; only ECR + ECS remain
terraform apply -var="enable_bastion=false"
```

**2. `-target`** — useful for iterating on one module without touching
`.tf` files or memorizing toggle combinations. Terraform will still want
its dependencies satisfied (state), so target the module and anything
it reads from:

```bash
# Just the ECR repos
terraform apply -target=module.ecr

# Just ECS (needs networking + ecr already in state)
terraform apply -target=module.networking -target=module.ecr -target=module.ecs
```

Prefer (1) for anything you intend to keep off long-term; prefer (2) for
short-lived, iterative applies during development.

## Day-to-day: pushing a new image and rolling it out

1. CI builds and pushes `backend`/`frontend` images to the ECR repos
   created by the `ecr` module, tagged with e.g. the git SHA.
2. Roll the new tag out:
   ```bash
   terraform apply -target=module.ecs \
     -var="backend_image_tag=$GIT_SHA" \
     -var="frontend_image_tag=$GIT_SHA"
   ```
   This updates the task definitions and triggers a new ECS deployment.

## Prerequisites

- Terraform >= 1.5
- AWS credentials available to the provider (env vars, `~/.aws/credentials`,
  or an assumed role) with permission to create VPC/EC2/ECR/ECS/IAM/ALB
  resources
- An AWS account/region with at least 2 availability zones (true for every
  standard region)

## Usage

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum set allowed_ssh_cidr, and check the
# enable_* toggles match what you want this apply to touch

terraform init
terraform plan
terraform apply
```

Bastion module outputs (only present when `enable_bastion = true`)
generates an SSH key pair and writes the private key to
`infra/keys/<key_pair_name>.pem` (0400 permissions, git-ignored):

```bash
terraform output -raw ssh_bastion_command
terraform output -raw ssh_app_command
```

ECS module outputs (only present when `enable_ecs = true`):

```bash
terraform output alb_dns_name          # point your app's URL / DNS record here
terraform output ecs_cluster_name
terraform output ecs_backend_service_name
terraform output ecs_frontend_service_name
```

The app command for the bastion uses `ProxyCommand` (rather than the bare
`-o ProxyJump=user@host` flag) so it hops through the bastion in one
command with the same key used for both hops. Note that
`-o ProxyJump=...` alone only applies `-i` to the *final* destination —
the hidden jump connection falls back to your default identity and fails
with "Permission denied" on the bastion. For repeat use, an SSH config
entry with `IdentityFile` set per-`Host` is cleaner than typing the full
command each time:

```
# ~/.ssh/config
Host rar-bastion
  HostName <bastion_public_ip>
  User ubuntu
  IdentityFile infra/keys/rent-a-ride-key.pem

Host rar-app
  HostName <app_private_ip>
  User ubuntu
  IdentityFile infra/keys/rent-a-ride-key.pem
  ProxyJump rar-bastion
```

## Secrets

Don't put real secrets (Mongo URI, JWT secret, etc.) in
`backend_environment` — plain vars land in the task definition and
Terraform state in cleartext. Put them in AWS Secrets Manager or SSM
Parameter Store and reference them via `backend_secrets`, which maps env
var name → ARN and lets ECS inject the value at container start:

```hcl
backend_secrets = {
  MONGO_URI  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rent-a-ride/mongo-uri"
  JWT_SECRET = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rent-a-ride/jwt-secret"
}
```

The `execution` IAM role only has the managed
`AmazonECSTaskExecutionRolePolicy` attached, which does **not** include
`secretsmanager:GetSecretValue` — add that permission (scoped to your
secret ARNs) to the execution role before relying on `backend_secrets`.

## Monitoring

`enable_monitoring = true` (default, requires `enable_bastion = true`)
stands up:

- CloudWatch alarms on the `RentARide/App` custom namespace the
  CloudWatch Agent publishes to (high CPU, high memory, high disk), plus
  a log-metric-filter alarm on Fluent Bit-shipped app logs (pino
  `level` 50/60 or a 5xx `res.statusCode`)
- An SNS topic (`sns_topic_arn` output) emailing `alert_email` on any
  alarm state change — **you must click the confirmation link AWS
  emails you before anything actually delivers**
- An internet-facing Network Load Balancer forwarding to the app host's
  Grafana NodePort (30030), so you can browse Grafana directly
  (`grafana_url` output) instead of SSH-tunneling through the bastion

```bash
terraform output sns_topic_arn
terraform output alarm_names
terraform output -raw grafana_url
```

Set `grafana_allowed_cidr` to your own IP (`curl ifconfig.me` + `/32`) —
an NLB preserves the real client IP, so this CIDR is enforced directly on
the app host's security group, not diluted to the whole VPC. Leaving it
at `0.0.0.0/0` exposes Grafana to the entire internet.

This module only covers the EC2/kind app host — it doesn't monitor ECS.

## What's not covered here

- No custom domain / Route 53 record for the ALB or Grafana NLB — point
  your DNS at `alb_dns_name` / `grafana_url` manually, or extend the
  relevant module.
- No auto-scaling policies on the ECS services — `*_desired_count` is
  static; add `aws_appautoscaling_target`/`policy` resources to the `ecs`
  module if you need that.
- No CloudWatch alarms/monitoring for ECS itself — `monitoring` targets
  the EC2/kind app host, not the Fargate services.
