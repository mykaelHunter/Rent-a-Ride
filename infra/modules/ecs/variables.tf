variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  description = "Region, needed for the awslogs log driver config."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the ALB (needs >= 2 AZs)."
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets the ECS tasks run in."
  type        = list(string)
}

variable "container_insights" {
  description = "Enable CloudWatch Container Insights on the cluster."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for HTTPS on the ALB. Leave empty to serve HTTP only on port 80."
  type        = string
  default     = ""
}

# --- Backend ---

variable "backend_image_url" {
  description = "ECR repository URL for the backend image (e.g. module.ecr.repository_urls[\"backend\"])."
  type        = string
}

variable "backend_image_tag" {
  type    = string
  default = "latest"
}

variable "backend_container_port" {
  type    = number
  default = 3000
}

variable "backend_health_check_path" {
  type    = string
  default = "/healthz"
}

variable "backend_path_pattern" {
  description = "ALB listener-rule path pattern routed to the backend target group."
  type        = string
  default     = "/api/*"
}

variable "backend_cpu" {
  type    = number
  default = 256
}

variable "backend_memory" {
  type    = number
  default = 512
}

variable "backend_desired_count" {
  type    = number
  default = 1
}

variable "backend_environment" {
  description = "Plain (non-secret) environment variables for the backend container."
  type        = map(string)
  default     = {}
}

variable "backend_secrets" {
  description = "Map of env var name -> Secrets Manager/SSM ARN, injected as ECS 'secrets' on the backend container."
  type        = map(string)
  default     = {}
}

# --- Frontend ---

variable "frontend_image_url" {
  description = "ECR repository URL for the frontend image (e.g. module.ecr.repository_urls[\"frontend\"])."
  type        = string
}

variable "frontend_image_tag" {
  type    = string
  default = "latest"
}

variable "frontend_container_port" {
  description = "Port nginx listens on inside the container. The image's nginx.conf uses 8080, not the usual 80 - keep this in sync with that file's `listen` directive."
  type        = number
  default     = 8080
}

variable "frontend_health_check_path" {
  type    = string
  default = "/"
}

variable "frontend_cpu" {
  type    = number
  default = 256
}

variable "frontend_memory" {
  type    = number
  default = 512
}

variable "frontend_desired_count" {
  type    = number
  default = 1
}

variable "frontend_environment" {
  type    = map(string)
  default = {}
}
