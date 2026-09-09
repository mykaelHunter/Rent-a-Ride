# modules/ecr

Creates one ECR repository per component (`backend`, `frontend` by
default), with image scanning on push and a lifecycle policy that keeps
the registry from growing forever.

See the root [`README.md`](../../README.md) for how this fits into the
whole stack and the `enable_ecr` toggle. This file covers just this
module: what it creates and how to use it on its own.

## What it creates

- `aws_ecr_repository` — one per name in `repository_names`, named
  `<project_name>-<name>` (e.g. `rent-a-ride-backend`)
- `aws_ecr_lifecycle_policy` — per repository: expires untagged images
  after 1 day, keeps only the last `max_image_count` tagged images

## Steps

### 1. Apply just this module

```bash
cd infra
terraform apply -target=module.ecr
```

Or, from the root, disable everything else for a first-time apply:

```bash
terraform apply -var="enable_bastion=false" -var="enable_ecs=false"
```

### 2. Get the repository URLs

```bash
terraform output ecr_repository_urls
# {
#   "backend"  = "<account_id>.dkr.ecr.<region>.amazonaws.com/rent-a-ride-backend"
#   "frontend" = "<account_id>.dkr.ecr.<region>.amazonaws.com/rent-a-ride-frontend"
# }
```

### 3. Authenticate Docker against ECR

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account_id>.dkr.ecr.us-east-1.amazonaws.com
```

Expires after 12 hours — re-run per session or wrap it into CI.

### 4. Tag and push an image

Pull the URL from Terraform output instead of typing it by hand — it
already has the account ID and region baked in:

```bash
aws_repo=$(terraform output -json ecr_repository_urls | jq -r '.backend')
docker tag rent-a-ride-backend:latest "$aws_repo:latest"
docker push "$aws_repo:latest"
```

Repeat for `frontend`.

### 5. Verify

```bash
aws ecr describe-images --repository-name rent-a-ride-backend \
  --query 'imageDetails[].{tag:imageTags,pushed:imagePushedAt}'
```

## Inputs worth knowing

| Variable | Default | Notes |
|---|---|---|
| `repository_names` | `["backend", "frontend"]` | One repo created per entry |
| `image_tag_mutability` | `MUTABLE` | Set `IMMUTABLE` to stop `:latest` from being overwritten |
| `scan_on_push` | `true` | Vulnerability scanning on every push |
| `max_image_count` | `10` | Older tagged images beyond this are expired |

## Common issues

- **`no basic auth credentials`** on `docker push` — the login token
  expired (12h) or was never run; redo step 3.
- **`repository does not exist`** — this module hasn't been applied
  yet, or you're pointing at the wrong region/account; check
  `terraform output ecr_repository_urls` matches what you're pushing to.
