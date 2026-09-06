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
  description = "Environment name (e.g. dev, staging, prod) - used in tags."
  type        = string
  default     = "dev"
}

# --- Networking ---

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (bastion host)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (application host)."
  type        = string
  default     = "10.0.2.0/24"
}

# The public and private subnets are deliberately placed in two different
# AZs (see data.aws_availability_zones in vpc.tf) to satisfy the "two
# availability zones" requirement. Note this is NOT high availability on
# its own - there's a single NAT Gateway (lives in the public subnet's AZ)
# and a single instance per tier, so an AZ outage on the private subnet's
# side still takes the app instance down. Turning this into a truly HA
# design would mean a public+private subnet pair per AZ, one NAT Gateway
# per AZ, and instances/ASGs spread across both pairs.

# --- SSH access ---

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

# --- Compute ---

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
  description = "Root EBS volume size (GiB) for the private app instance - kind/Docker images and containers live here."
  type        = number
  default     = 20
}

variable "private_ingress_ports" {
  description = <<-EOT
    Extra TCP ports (beyond SSH from the bastion) opened on the private
    instance's security group, reachable only from within the VPC CIDR.
    Defaults to Rent-a-Ride's backend port (3000) and the kind NodePorts
    (30080 frontend / 30300 backend) used elsewhere in this project - adjust
    or empty this list out if the private instance is used for something
    else.
  EOT
  type        = list(number)
  default     = [3000, 30080, 30300]
}

variable "key_pair_name" {
  description = "Name to give the AWS key pair created for these instances."
  type        = string
  default     = "rent-a-ride-key"
}
