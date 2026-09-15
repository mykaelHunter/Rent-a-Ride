# Remote state with locking. Values here come from infra/bootstrap's
# outputs (run that config once first - see bootstrap/README or the
# `backend_config_snippet` output).
#
# NOTE: backend blocks can't use variables - these are literal values on
# purpose. Update them once after running bootstrap, then never again
# unless you deliberately migrate the backend (terraform init -migrate-state).
# Remote state with locking. Values here come from infra/bootstrap's
# outputs (run that config once first - see the README's "Remote state"
# section or the `backend_config_snippet` output).
#
# NOTE: backend blocks can't use variables - these are literal values on
# purpose. Update them once after running bootstrap, then never again
# unless you deliberately migrate the backend (terraform init -migrate-state).
#
# use_lockfile = true is Terraform's native S3 locking (>= 1.10, no
# DynamoDB table needed) - it writes a `.tflock` companion object next to
# the state file itself. Requires Terraform >= 1.10 (see versions.tf).
terraform {
  backend "s3" {
    bucket       = "rent-a-ride-tf-state-mhunter"
    key          = "rent-a-ride/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
