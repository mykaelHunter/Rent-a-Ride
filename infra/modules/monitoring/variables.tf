variable "project_name" {
  type = string
}

variable "vpc_id" {
  description = "VPC ID (from the networking module)."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (from the networking module) the Grafana NLB is enabled in. Needs to include the AZ the app host's private subnet lives in, or the target sits permanently unused."
  type        = list(string)
}

variable "app_instance_id" {
  description = "Instance ID of the app host (from the bastion module) - used as the alarm dimension and the Grafana NLB target."
  type        = string
}
