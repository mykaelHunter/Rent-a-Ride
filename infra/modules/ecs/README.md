# modules/ecs

Fargate cluster, internet-facing ALB with path-based routing, task
definitions, and services for the backend and frontend containers.

See the root [`README.md`](../../README.md) for how this fits into the
whole stack, the `enable_ecs` toggle, and the full secrets story
(`mongo_uri` / `backend_secret_values` / `backend_secrets`). This file
covers just this module: what it creates and how to deploy/verify it on
its own.

## What it creates

- `aws_ecs_cluster` — Fargate only, no EC2 capacity providers
- `aws_lb` (ALB) + two target groups — path `/api/*` routed to backend,
  everything else to frontend
- `aws_security_group` × 2 — `alb` (internet → 80/443) and `ecs_tasks`
  (container ports, ALB only)
- `aws_iam_role` × 2 — `execution` (ECR pulls, log writes, and
  `secretsmanager:GetSecretValue` scoped to whatever's in
  `backend_secrets`) and `task` (empty by default — attach policies here
  for anything the app itself needs to call, e.g. S3)
- `aws_cloudwatch_log_group` × 2 — one per component
- `aws_ecs_task_definition` × 2 and `aws_ecs_service` × 2 — backend and
  frontend, tasks in the private subnets with no public IP

## Steps

### 1. Prerequisites

This module needs a VPC and subnets (the `networking` module) and image
URLs (the `ecr` module, or `ecr_repository_urls_override` if you're
managing ECR separately). From the root:

```bash
terraform apply -target=module.networking -target=module.ecr
```

### 2. Apply this module

```bash
terraform apply -target=module.ecs
```

First apply will fail health checks until real images exist in ECR —
push backend/frontend images first if you haven't (see
[`modules/ecr/README.md`](../ecr/README.md)).

### 3. Roll out a new image tag

```bash
terraform apply -target=module.ecs \
  -var="backend_image_tag=$GIT_SHA" \
  -var="frontend_image_tag=$GIT_SHA"
```

This updates the task definitions and triggers a new ECS deployment.

### 4. Verify the cluster is active

```bash
aws ecs describe-clusters --clusters $(terraform output -raw ecs_cluster_name) \
  --query 'clusters[0].status'
```

### 5. Verify task definitions registered

```bash
aws ecs describe-task-definition --task-definition rent-a-ride-dev-backend \
  --query 'taskDefinition.{status:status,revision:revision}'
```

### 6. Verify services and tasks are healthy

```bash
aws ecs describe-services --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_backend_service_name) $(terraform output -raw ecs_frontend_service_name) \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount}'
```

Both `running` should equal `desired`. If not:

```bash
# list any stopped tasks
aws ecs list-tasks --cluster <cluster> --service-name <service> --desired-status STOPPED

# get the actual failure reason for one
aws ecs describe-tasks --cluster <cluster> --tasks <task-arn> \
  --query 'tasks[0].{stoppedReason:stoppedReason,exitCode:containers[0].exitCode,containerReason:containers[0].reason}'

# tail the container's own logs
aws logs tail /ecs/rent-a-ride-dev/backend --since 20m
```

### 7. Verify the ALB and target groups

```bash
terraform output alb_dns_name

aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups --names rent-a-ride-dev-backend-tg --query 'TargetGroups[0].TargetGroupArn' --output text)
```

`State` should be `healthy`. `unhealthy`/`Target.FailedHealthChecks`
almost always means the health check path or port doesn't match what
the container actually serves — see Common issues below.

## Inputs worth knowing

| Variable | Default | Notes |
|---|---|---|
| `backend_container_port` | `3000` | Must match what the app listens on |
| `frontend_container_port` | `8080` | Not `80` — check your image's actual listen port before assuming |
| `backend_health_check_path` | `/healthz` | Must be a real route, not a guess |
| `frontend_health_check_path` | `/` | |
| `backend_path_pattern` | `/api/*` | ALB listener rule routing to backend |
| `backend_desired_count` / `frontend_desired_count` | `1` | Task count per service |
| `acm_certificate_arn` | `""` | Set for HTTPS; leave empty for HTTP-only |

## Common issues

- **Target group unhealthy, `Target.FailedHealthChecks`** — the health
  check path/port doesn't match the container. Check the *image's*
  actual listen port and route table (Dockerfile, nginx.conf, server
  startup code) rather than assuming a convention — non-root
  ("unprivileged") images very often listen above 1024 by design.
- **Task registers then immediately drains, repeatedly** — a crash
  loop, not a health-check failure. `describe-tasks` will show a real
  `exitCode`; check `aws logs tail` for the actual error (missing env
  var, bad connection string, etc.), not just the ECS-level symptom.
- **`ResourceInitializationError` on task start** — usually a missing
  IAM permission for pulling a secret. If you're setting
  `backend_secrets` manually (not via `mongo_uri`/
  `backend_secret_values`, which wire this automatically), the
  execution role needs `secretsmanager:GetSecretValue` scoped to that
  ARN.
- **ALB returns 503 with no healthy targets anywhere** — check
  `runningCount` per service first; a 503 with one target group empty
  (0 running tasks) is a scheduling/crash problem for that service, not
  a load balancer misconfiguration.
