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

variable "enable_eks" {
  description = "Create the EKS cluster + managed node group, as an alternative to (or alongside) the ECS path."
  type        = bool
  default     = false
}

variable "enable_dns_ssl" {
  description = "Provision the Route53 zone lookup, both ACM certs (app./api. subdomains, split cert-per-region), the CloudFront+S3 frontend, and the app./api. alias records. Requires domain_name and a pre-existing Route53-hosted zone for it, plus enable_ecs = true (api.<domain_name> aliases to the ECS module's ALB)."
  type        = bool
  default     = false
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
  description = "ACM cert ARN for HTTPS on the ALB, used only when enable_dns_ssl = false (that path auto-creates and injects its own api.<domain_name> cert instead). Leave empty for HTTP-only on port 80."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Domain / ACM / CloudFront+S3 - split-subdomain model:
#   app.<domain_name>  -> CloudFront -> S3 (frontend)
#   api.<domain_name>  -> ALB directly (backend, via the ECS module)
# Two separate ACM certs (each covering just its own subdomain) rather
# than one cert with SANs, since the CloudFront cert must live in
# us-east-1 while the ALB cert must live in the ALB's own region.
# ---------------------------------------------------------------------------

variable "domain_name" {
  description = "Your Route53-hosted apex domain, e.g. rentaride.example.com. Required when enable_dns_ssl = true."
  type        = string
  default     = ""
}

variable "app_subdomain" {
  description = "Subdomain the frontend answers on - full hostname is <app_subdomain>.<domain_name>."
  type        = string
  default     = "app"
}

variable "api_subdomain" {
  description = "Subdomain the backend API answers on - full hostname is <api_subdomain>.<domain_name>."
  type        = string
  default     = "api"
}

variable "frontend_bucket_name" {
  description = "Globally-unique S3 bucket name for the built React app (client/dist). Required when enable_dns_ssl = true."
  type        = string
  default     = ""
}

variable "cloudfront_price_class" {
  description = "CloudFront price class - PriceClass_100 (US/Canada/Europe) is cheapest, PriceClass_All is most edge locations."
  type        = string
  default     = "PriceClass_100"
}

variable "enable_ecs_frontend" {
  description = "Run the frontend as an ECS/nginx service behind the ALB. Set false once app.<domain_name> is served from S3+CloudFront instead - kept as a toggle (not a deletion) so reverting is a one-line change."
  type        = bool
  default     = true
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

variable "backend_health_check_path" {
  description = "Path the ALB hits on the backend container for its health check - must match a real route in server.js. Defaults to /healthz."
  type        = string
  default     = "/healthz"
}

variable "frontend_container_port" {
  description = "Port nginx listens on inside the container. The image's nginx.conf uses 8080, not the usual 80 - keep this in sync with that file's `listen` directive."
  type        = number
  default     = 8080
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
  description = "Map of env var name -> Secrets Manager ARN, for secrets you're already managing elsewhere. Merged with the auto-created secrets from mongo_uri/backend_secret_values - you don't need to duplicate those keys here."
  type        = map(string)
  default     = {}
}

variable "mongo_uri" {
  description = "MongoDB connection string (e.g. Atlas SRV URI). Shorthand for backend_secret_values[\"mongo_uri\"] - equivalent to adding it there, kept separate since every deployment needs it. Injected as env var mongo_uri (lowercase - matches what server.js actually reads, not the usual MONGO_URI convention)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backend_secret_values" {
  description = <<-EOT
    Plaintext secret values Terraform should create a Secrets Manager
    secret for and inject into the backend task - the map key is BOTH
    the secret's name suffix and the env var name the container sees.
    This is the AWS-Secrets-Manager equivalent of what you'd otherwise
    pass to `kubectl create secret generic backend-secret --from-literal=...`
    when deploying to Kubernetes - one map, one Terraform-managed secret
    per key, injected as an env var each:

      backend_secret_values = {
        ACCESS_TOKEN    = "..."
        REFRESH_TOKEN   = "..."
        CLOUD_NAME      = "..."
        API_KEY         = "..."
        API_SECRET      = "..."
        EMAIL_HOST      = "..."
        EMAIL_PASSWORD  = "..."
        RAZORPAY_KEY_ID = "..."
        RAZORPAY_SECRET = "..."
      }

    Same MONGO_INITDB_ROOT_USERNAME/PASSWORD pattern from the Kubernetes
    setup doesn't carry over as-is: those existed to bootstrap a
    self-hosted `mongo-0` StatefulSet's root user on first boot, which
    doesn't apply once Mongo lives in Atlas (or DocumentDB) - Atlas
    creates its database user through its own UI/API, not a Kubernetes
    Secret an init container reads. If you're still self-hosting Mongo
    (e.g. as a separate ECS service or EC2 instance) rather than using
    Atlas, put MONGO_INITDB_ROOT_USERNAME/PASSWORD in this map too and
    wire them into that Mongo container's task definition the same way -
    ask if you want that added.

    Pass this at apply time (-var or TF_VAR_backend_secret_values as
    JSON), never in a committed terraform.tfvars - see the Secrets
    section of the README.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

variable "eks_kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "eks_endpoint_public_access" {
  description = "Whether the EKS API server is reachable from outside the VPC (needed for kubectl from a laptop, unless you're going through the bastion/VPN)."
  type        = bool
  default     = true
}

variable "eks_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Restrict to your own IP before real use."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "eks_capacity_type" {
  description = "ON_DEMAND or SPOT for the managed node group."
  type        = string
  default     = "SPOT"
}

variable "eks_instance_types" {
  type    = list(string)
  default = ["t3a.medium"]
}

variable "eks_desired_size" {
  type    = number
  default = 3
}

variable "eks_min_size" {
  type    = number
  default = 3
}

variable "eks_max_size" {
  type    = number
  default = 3
}

variable "eks_ssh_key_pair_name" {
  description = "EC2 key pair for SSH access to EKS nodes. Leave empty (default) to disable node SSH entirely."
  type        = string
  default     = ""
}

variable "eks_bastion_security_group_id" {
  description = "Security group ID to allow SSH into EKS nodes from. Only used when eks_ssh_key_pair_name is also set. Leave empty to default to the bastion module's own security group (when enable_bastion = true); set explicitly to use a different source SG instead."
  type        = string
  default     = ""
}

variable "eks_lb_controller_install_method" {
  description = "How to install the AWS Load Balancer Controller: \"addon\" (managed EKS addon) or \"helm\" (upstream chart, installed at root via the helm provider). Default \"helm\" since the addon build lags new k8s versions - switch to \"addon\" once AWS publishes one for your cluster's version."
  type        = string
  default     = "helm"
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
