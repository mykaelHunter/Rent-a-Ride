variable "project_name" {
  description = "Short name used to prefix/tag all resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (from the networking module) to place the bastion/app SGs into."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC (from the networking module) - used to scope app-port ingress."
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID to launch the bastion into."
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet ID to launch the app host into."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    CIDR block allowed to SSH into the bastion host on port 22.
    Defaults to 0.0.0.0/0 (open to the internet) purely so `terraform apply`
    works out of the box - restrict this to your own IP (e.g. "x.x.x.x/32")
    before using this anywhere beyond a quick test.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "bastion_instance_type" {
  description = "Instance type for the public bastion host."
  type        = string
  default     = "t3.micro"
}

variable "private_instance_type" {
  description = "Instance type for the private application host."
  type        = string
  default     = "t3a.medium"
}

variable "app_root_volume_size" {
  description = "Root EBS volume size (GiB) for the private app instance."
  type        = number
  default     = 20
}

variable "private_ingress_ports" {
  description = "Extra TCP ports opened on the private instance's SG, reachable only from within the VPC CIDR."
  type        = list(number)
  default     = [3000, 30080, 30300]
}

variable "key_pair_name" {
  description = "Name to give the AWS key pair created for these instances."
  type        = string
  default     = "rent-a-ride-key"
}

variable "grafana_allowed_cidr" {
  description = "CIDR allowed to reach Grafana's NodePort through the monitoring module's NLB. Leave empty (default) to skip adding the rule - do this when the monitoring module isn't in use."
  type        = string
  default     = ""
}

variable "grafana_nodeport" {
  description = "NodePort Grafana is exposed on inside the kind cluster."
  type        = number
  default     = 30030
}

variable "enable_cw_agent_profile" {
  description = "Create and attach the CloudWatch Agent IAM instance profile to the app host. Leave enabled even if the monitoring module is off - it's a harmless, low-privilege role."
  type        = bool
  default     = true
}
