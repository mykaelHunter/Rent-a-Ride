variable "project_name" {
  description = "Short name used to prefix/tag all resources."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod) - used in tags and resource names."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes version."
  type        = string
  default     = "1.36"
}

variable "vpc_id" {
  description = "VPC to place the cluster and node group into."
  type        = string
}

# EKS control planes need subnets in at least 2 AZs. Passing both public
# and private subnets lets the control plane create ENIs in either -
# nodes themselves are pinned to private_subnet_ids below, keeping worker
# instances off the public subnets regardless of what's passed here.
variable "control_plane_subnet_ids" {
  description = "Subnet IDs the EKS control plane ENIs are created in (public + private recommended, min 2 AZs)."
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Subnet IDs worker nodes are launched into - private subnets, so nodes aren't directly internet-reachable."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "Whether the EKS API server endpoint is reachable from outside the VPC. Leave true for kubectl access from a laptop; set false + rely on the bastion/VPN for a locked-down cluster."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint, when endpoint_public_access = true. Restrict to your own IP before real use."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_group_name" {
  description = "Name suffix for the managed node group."
  type        = string
  default     = "default"
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT. SPOT is cheaper but nodes can be reclaimed by AWS with a 2-minute warning - fine for stateless/interruption-tolerant workloads, not for anything that can't tolerate a node disappearing."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be either \"ON_DEMAND\" or \"SPOT\"."
  }
}

variable "instance_types" {
  description = "EC2 instance types the node group draws from. Multiple types recommended for SPOT (more capacity pools = fewer interruptions) - kept to one here to match a specific ask, but consider adding e.g. t3.medium as a fallback."
  type        = list(string)
  default     = ["t3a.medium"]
}

variable "desired_size" {
  type    = number
  default = 3
}

variable "min_size" {
  type    = number
  default = 3
}

variable "max_size" {
  type    = number
  default = 3
}

variable "node_disk_size" {
  description = "Root EBS volume size (GiB) for each worker node."
  type        = number
  default     = 20
}

variable "ssh_key_pair_name" {
  description = "EC2 key pair name for SSH access to nodes via the bastion's security group. Leave empty to disable SSH access entirely."
  type        = string
  default     = ""
}

variable "bastion_security_group_id" {
  description = "Security group ID (e.g. the bastion's) to allow SSH into nodes from, when ssh_key_pair_name is set. Ignored if ssh_key_pair_name is empty."
  type        = string
  default     = ""
}

variable "lb_controller_install_method" {
  description = "How to install the AWS Load Balancer Controller: \"addon\" (managed EKS addon - simplest, but AWS hasn't published a build for every k8s version) or \"helm\" (upstream chart via the helm provider - works everywhere, one more provider to configure). Default is \"helm\" since the addon build lags new k8s versions."
  type        = string
  default     = "helm"

  validation {
    condition     = contains(["addon", "helm"], var.lb_controller_install_method)
    error_message = "lb_controller_install_method must be either \"addon\" or \"helm\"."
  }
}
