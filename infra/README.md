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
    ├── ecr/         # ECR repositories (backend, frontend) + lifecycle policies - see modules/ecr/README.md
    └── ecs/         # Fargate cluster, ALB, task defs, services for backend/frontend - see modules/ecs/README.md
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

Don't put real secrets in `backend_environment` — plain vars land in the
task definition in cleartext, visible to anyone with
`ecs:DescribeTaskDefinition`. There are three ways to get a secret into
the backend container, all landing in the same place (one Secrets
Manager secret per key, injected via ECS's `secrets` field):

**1. `mongo_uri`** — every deployment needs this one, so it gets its own
variable. Injected as env var `mongo_uri` (lowercase, matching what
`server.js` actually reads via `process.env.mongo_uri` — env var names
are case-sensitive, so this one is deliberately NOT the usual
`MONGO_URI` convention):

```bash
terraform apply -target=module.ecs -var='mongo_uri=mongodb+srv://user:pass@cluster0.xxxxx.mongodb.net/rent-a-ride'
```

**2. `backend_secret_values`** — everything else the app needs at
runtime. This is the Secrets Manager equivalent of the
`kubectl create secret generic backend-secret --from-literal=...`
step from a Kubernetes deployment — same keys, same values, just
provisioned by Terraform instead of `kubectl`:

```bash
terraform apply -target=module.ecs -var-file=secrets.tfvars
```

```hcl
# secrets.tfvars - see the .gitignore note below
backend_secret_values = {
  ACCESS_TOKEN    = "..."
  REFRESH_TOKEN   = "..."
  CLOUD_NAME      = "..."
  API_KEY         = "..."
  API_SECRET      = "..."
  EMAIL_HOST      = "..."
  EMAIL_PASSWORD  = "..."
  RAZORPAY_KEY_ID = "..."
  RAZORPAY_SECRET = "..."
}
```

One thing that does **not** carry over as-is: the Kubernetes setup's
`MONGO_INITDB_ROOT_USERNAME`/`PASSWORD` secret existed to bootstrap a
self-hosted `mongo-0` StatefulSet's root user on first boot. That's not
applicable once Mongo lives in Atlas (Atlas creates its database user
through its own UI/API) — only add those two keys here if you're
self-hosting Mongo as a separate ECS service or EC2 instance instead of
using Atlas, and wire them into *that* container's task definition, not
the backend's.

Whichever of #1/#2 you use, **never** in a committed `terraform.tfvars`
— pass via `-var`, `-var-file` pointing at a git-ignored file, or
`TF_VAR_*` env vars in your shell/CI secrets store. If you use a
`-var-file`, add its name to `.gitignore` (`secrets.tfvars` isn't
covered by the existing `terraform.tfvars`/`*.auto.tfvars` patterns).
Both variables are marked `sensitive`, so they won't appear in
`plan`/`apply` output, but they do land in Terraform state regardless of
how they're passed in — state itself should be treated as sensitive
(e.g. an S3 backend with encryption + access controls), independent of
this.

**3. `backend_secrets`** — for secrets you're *already* managing in
Secrets Manager yourself (Terraform didn't create them). Point this at
the ARN directly; it's merged with #1/#2, not a replacement:

```hcl
backend_secrets = {
  SOME_PRE_EXISTING_SECRET = "arn:aws:secretsmanager:us-east-1:123456789012:secret:some-secret"
}
```

The secrets Terraform creates (#1/#2) are set with
`recovery_window_in_days = 0`, so `terraform destroy` deletes them
immediately instead of Secrets Manager's default 7-30 day soft-delete
window. Without this, a destroy/recreate cycle (e.g. tearing down and
rebuilding a dev environment) hits `InvalidRequestException: ... already
scheduled for deletion` on the next apply, since the name stays reserved
until the window lapses. Fine for disposable dev secrets; reconsider if
you ever want a recovery window on a production secret you could delete
by mistake.

All three paths automatically grant the execution role
`secretsmanager:GetSecretValue`, scoped to just the ARNs involved — the
managed `AmazonECSTaskExecutionRolePolicy` alone doesn't include that
permission, so without it the task fails to start with a
`ResourceInitializationError` rather than a container crash.

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
