# Monitoring Terraform

`iam.tf`, `sns.tf`, and `alarms.tf` reuse `var.project_name` / `var.aws_region`
and the `aws` provider already declared in `infra/`. Drop them straight into
the existing root rather than standing up a second state/provider:

```bash
cp infra/monitoring/terraform/*.tf infra/
```

Then, in `infra/ec2.tf`, attach the new instance profile to the app host:

```hcl
resource "aws_instance" "app" {
  ...
  iam_instance_profile = aws_iam_instance_profile.app_cwagent.name
  ...
}
```

## Apply

```bash
cd infra
terraform init
terraform apply \
  -var="alert_email=you@example.com" \
  -var="app_instance_id=$(terraform output -raw app_instance_id 2>/dev/null || echo REPLACE_ME)"
```

`app_instance_id` can't come from a `terraform output` before the instance
exists on a fresh apply — for the very first apply, either:
- run `terraform apply -target=aws_instance.app` first, then apply the rest, or
- add `app_instance_id = aws_instance.app.id` directly as a default/local
  once the instance resource is in the same plan (simplest: replace the
  `var.app_instance_id` references in `alarms.tf` with `aws_instance.app.id`
  once you've copied these files into `infra/`).

## After apply

1. Check the inbox for `alert_email` and click the SNS "Confirm
   subscription" link — alarms will not deliver until you do.
2. SSH to the app host (`terraform output ssh_app_command`) and run
   `../cloudwatch-agent/install-cwagent.sh` (see that directory).
3. Deploy Fluent Bit into the kind cluster (see `../fluent-bit/README.md`).
4. Confirm dimensions in the console match what's in `alarms.tf` — the
   CloudWatch Agent's exact `path`/`fstype`/`device` dimension values for
   the disk alarm depend on the instance's actual mount, so open Metrics →
   `RentARide/App` → `used_percent` once data is flowing and adjust
   `alarms.tf`'s `dimensions` block to match exactly if the alarm shows
   "Insufficient Data".
