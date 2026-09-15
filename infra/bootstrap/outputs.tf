output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.id
}

output "backend_config_snippet" {
  description = "Paste this into infra/backend.tf's backend \"s3\" block."
  value = <<-EOT
    bucket       = "${aws_s3_bucket.tf_state.id}"
    key          = "rent-a-ride/terraform.tfstate"
    region       = "${var.aws_region}"
    use_lockfile = true
    encrypt      = true
  EOT
}
