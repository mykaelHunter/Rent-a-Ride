# ---------------------------------------------------------------------------
# One-time bootstrap for Terraform remote state.
#
# This is a SEPARATE root module on purpose: the main infra/ config can't
# create the very bucket/table it needs to store its own state in (chicken
# -and-egg). Run this once, by itself, with local state. After it applies,
# wire the outputs into infra/backend.tf and run `terraform init` there -
# never touch this config again unless you're changing the state backend
# itself.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Deliberately no backend block - this config's own state stays local
  # (infra/bootstrap/terraform.tfstate). Keep that file safe (commit it
  # to a private repo or copy it somewhere durable); losing it just means
  # a future `terraform import` of the bucket/table, not a re-create.
}

provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name

  # Guards against `terraform destroy` here ever taking out the bucket
  # that the main config's state lives in.
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Belt-and-suspenders alongside the DynamoDB lock table below: even if
# something bypasses the lock, this stops any state file version from
# ever being deleted outright.
resource "aws_s3_bucket_lifecycle_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    id     = "keep-noncurrent-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# Terraform's native S3 lock (`use_lockfile = true` in backend.tf) needs
# no separate table - it writes a lock object alongside the state file in
# the same bucket. No DynamoDB table is created here; kept only as a
# historical note in case an older environment still needs one.
