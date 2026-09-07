# ---------------------------------------------------------------------------
# Module toggles - set to false to skip a module entirely on `terraform
# apply` / `terraform plan` without touching the code. E.g. to (re)apply
# only ECR + ECS on top of an already-provisioned network:
#
#   terraform apply -var="enable_bastion=false"
#
# (networking stays required - both bastion and ecs depend on it). You can
# also target a single module directly regardless of these toggles, e.g.
# `terraform apply -target=module.ecr` or `-target=module.ecs`.
# ---------------------------------------------------------------------------

variable "enable_bastion" {
  description = "Create the bastion + private app EC2 instances (the pre-ECS kind-on-EC2 setup)."
  type        = bool
  default     = true
}

variable "enable_ecr" {
  description = "Create the ECR repositories."
  type        = bool
  default     = true
}

variable "enable_ecs" {
  description = "Create the ECS cluster/ALB/services. Requires ECR image URLs - either from enable_ecr=true or from ecr_repository_urls_override."
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Create the monitoring module (CloudWatch alarms, SNS topic, Grafana NLB) for the app EC2 host. Ignored (treated as off) when enable_bastion = false, since there's no app host to monitor."
  type        = bool
  default     = true
}

variable "ecr_repository_urls_override" {
  description = "Manual map of component -> ECR repo URL, used by the ECS module only when enable_ecr = false (e.g. ECR was applied in a prior run)."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to provision resources in."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used to prefix/tag all resources."
  type        = string
  default     = "rent-a-ride"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod) - used in tags and resource names."
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ, min 2 - required for the ALB)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.11.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.2.0/24", "10.0.12.0/24"]
}

# ---------------------------------------------------------------------------
# Bastion / legacy app host
# ---------------------------------------------------------------------------

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to SSH into the bastion host on port 22. Restrict to your own IP before real use."
  type        = string
  default     = "0.0.0.0/0"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "private_instance_type" {
  type    = string
  default = "t3a.medium"
}

variable "app_root_volume_size" {
  type    = number
  default = 20
}

variable "private_ingress_ports" {
  type    = list(number)
  default = [3000, 30080, 30300]
}

variable "key_pair_name" {
  type    = string
  default = "rent-a-ride-key"
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

variable "ecr_repository_names" {
  description = "Component names to create one ECR repo each for."
  type        = list(string)
  default     = ["backend", "frontend"]
}

variable "ecr_max_image_count" {
  type    = number
  default = 10
}

# ---------------------------------------------------------------------------
# ECS
# ---------------------------------------------------------------------------

variable "acm_certificate_arn" {
  description = "ACM cert ARN for HTTPS on the ALB. Leave empty for HTTP-only on port 80."
  type        = string
  default     = ""
}

variable "backend_image_tag" {
  description = "Image tag to deploy for the backend service - set this per deploy from CI (git SHA, build number, etc.)."
  type        = string
  default     = "latest"
}

variable "frontend_image_tag" {
  description = "Image tag to deploy for the frontend service - set this per deploy from CI."
  type        = string
  default     = "latest"
}

variable "backend_container_port" {
  type    = number
  default = 3000
}

variable "frontend_container_port" {
  type    = number
  default = 80
}

variable "backend_desired_count" {
  type    = number
  default = 1
}

variable "frontend_desired_count" {
  type    = number
  default = 1
}

variable "backend_environment" {
  description = "Plain (non-secret) env vars for the backend container, e.g. { NODE_ENV = \"production\" }."
  type        = map(string)
  default     = {}
}

variable "backend_secrets" {
  description = "Map of env var name -> Secrets Manager/SSM ARN (e.g. Mongo URI) injected into the backend container."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

variable "alert_email" {
  description = "Email address to subscribe to the monitoring SNS topic - you must confirm the AWS subscription email before alarms deliver. Required when enable_monitoring = true."
  type        = string
  default     = ""
}

variable "grafana_allowed_cidr" {
  description = "CIDR allowed to reach Grafana through the monitoring NLB (e.g. \"41.x.x.x/32\", from `curl ifconfig.me`). Do NOT leave as 0.0.0.0/0 - that exposes Grafana to the public internet. Required when enable_monitoring = true."
  type        = string
  default     = ""
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization percent (non-idle) above which the high-CPU alarm fires."
  type        = number
  default     = 80
}

variable "mem_alarm_threshold" {
  description = "Memory used percent above which the high-memory alarm fires."
  type        = number
  default     = 85
}

variable "disk_alarm_threshold" {
  description = "Root volume used percent above which the disk-space alarm fires."
  type        = number
  default     = 85
}

variable "alarm_evaluation_periods" {
  description = "Number of consecutive periods a threshold breach must persist before an infra alarm fires."
  type        = number
  default     = 3
}

variable "alarm_period_seconds" {
  description = "Length of each evaluation period, in seconds. Must match/exceed the CloudWatch Agent's metrics_collection_interval (60s)."
  type        = number
  default     = 60
}

variable "app_log_group_name" {
  description = "Log group Fluent Bit ships rent-a-ride namespace logs to - must match log_group_name in fluent-bit-configmap.yaml."
  type        = string
  default     = "/rent-a-ride/kubernetes/app"
}

variable "error_alarm_threshold" {
  description = "Number of matching error log lines within a 5-minute window that trips the application-errors alarm."
  type        = number
  default     = 5
}
