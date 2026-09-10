# ---------------------------------------------------------------------------
# Networking - always created; ECR has no networking dependency, but both
# the bastion and ECS modules need a VPC/subnets to place resources into.
# ---------------------------------------------------------------------------

module "networking" {
  source = "./modules/networking"

  project_name          = var.project_name
  vpc_cidr              = var.vpc_cidr
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
}

# ---------------------------------------------------------------------------
# Bastion + legacy private app host (the pre-ECS kind-on-EC2 setup).
# Toggle off once everything has moved to ECS.
# ---------------------------------------------------------------------------

module "bastion" {
  source = "./modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  project_name             = var.project_name
  vpc_id                   = module.networking.vpc_id
  vpc_cidr                 = module.networking.vpc_cidr
  public_subnet_id         = module.networking.public_subnet_ids[0]
  private_subnet_id        = module.networking.private_subnet_ids[0]
  allowed_ssh_cidr         = var.allowed_ssh_cidr
  bastion_instance_type    = var.bastion_instance_type
  private_instance_type    = var.private_instance_type
  app_root_volume_size     = var.app_root_volume_size
  private_ingress_ports    = var.private_ingress_ports
  key_pair_name            = var.key_pair_name
  enable_cw_agent_profile  = var.enable_monitoring
  grafana_allowed_cidr     = var.enable_monitoring ? var.grafana_allowed_cidr : ""
}

# ---------------------------------------------------------------------------
# Monitoring - CloudWatch alarms, SNS alerts, and a Grafana NLB for the
# app host. Only meaningful when the bastion/app EC2 host exists, since
# it's what's being monitored - the ECS path isn't covered by this module.
# ---------------------------------------------------------------------------

module "monitoring" {
  source = "./modules/monitoring"
  count  = var.enable_bastion && var.enable_monitoring ? 1 : 0

  project_name      = var.project_name
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids

  app_instance_id = module.bastion[0].app_instance_id

  alert_email          = var.alert_email
  grafana_allowed_cidr = var.grafana_allowed_cidr

  cpu_alarm_threshold      = var.cpu_alarm_threshold
  mem_alarm_threshold      = var.mem_alarm_threshold
  disk_alarm_threshold     = var.disk_alarm_threshold
  alarm_evaluation_periods = var.alarm_evaluation_periods
  alarm_period_seconds     = var.alarm_period_seconds
  app_log_group_name       = var.app_log_group_name
  error_alarm_threshold    = var.error_alarm_threshold
}

# ---------------------------------------------------------------------------
# ECR - repositories the CI pipeline pushes backend/frontend images to.
# ---------------------------------------------------------------------------

module "ecr" {
  source = "./modules/ecr"
  count  = var.enable_ecr ? 1 : 0

  project_name      = var.project_name
  repository_names  = var.ecr_repository_names
  max_image_count   = var.ecr_max_image_count
}

# ---------------------------------------------------------------------------
# ECS - Fargate cluster + ALB + services running the images from ECR.
# When enable_ecr = false, repository URLs must come from
# var.ecr_repository_urls_override instead (e.g. ECR applied separately).
# ---------------------------------------------------------------------------

locals {
  ecr_repository_urls = var.enable_ecr ? module.ecr[0].repository_urls : var.ecr_repository_urls_override

  # Everything Terraform should create a Secrets Manager secret for:
  # mongo_uri kept as its own variable purely because it's the one every
  # deployment needs; everything else (ACCESS_TOKEN, RAZORPAY_SECRET,
  # EMAIL_PASSWORD, etc.) goes in the generic backend_secret_values map.
  # Both land in the same place, one Secrets Manager secret per key.
  backend_secret_plaintext = merge(
    var.backend_secret_values,
    var.mongo_uri == "" ? {} : { mongo_uri = var.mongo_uri }
  )

  # for_each can't take a value derived from a sensitive variable (it
  # would risk exposing a secret VALUE as a resource instance key in the
  # plan) - so the resources below iterate over just the key NAMES
  # (env var names like MONGO_URI, ACCESS_TOKEN - not secret themselves)
  # pulled out with nonsensitive(), and look the actual value back up
  # from local.backend_secret_plaintext per-iteration instead.
  backend_secret_keys = nonsensitive(toset(keys(local.backend_secret_plaintext)))

  # Merge the auto-created secrets' ARNs with whatever the caller passed
  # in backend_secrets directly (secrets they're already managing
  # elsewhere), so both paths work at once.
  backend_secrets = merge(
    var.backend_secrets,
    { for key in local.backend_secret_keys : key => aws_secretsmanager_secret.backend[key].arn }
  )
}

# ---------------------------------------------------------------------------
# Backend secrets, stored as Secrets Manager secrets (one per key) rather
# than plain Terraform variables in the task definition. Driven by
# local.backend_secret_plaintext (mongo_uri + backend_secret_values
# merged) - add a new secret by adding one line to backend_secret_values
# in terraform.tfvars, nothing here needs to change.
#
# One secret per env var, not a single JSON blob, because that's what
# ECS's per-container "secrets" field expects: each entry is one env var
# name mapped to one secret ARN (optionally a ::key suffix for a JSON
# secret's field) - one-per-key skips needing a jq/JSON-parsing step in
# the container's entrypoint.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "backend" {
  for_each = local.backend_secret_keys

  # Secrets Manager names are case-sensitive and env vars are
  # conventionally upper-snake-case; lowercasing here just keeps the
  # secret name matching the kubectl-era key naming (mongo_uri,
  # razorpay_secret, ...) without affecting the MONGO_URI-style env var
  # name ECS actually injects (that's the map key itself, untouched).
  name = "${var.project_name}/${var.environment}/${lower(each.value)}"

  # Secrets Manager's default is a 7-30 day soft-delete window that
  # blocks recreating a secret under the same name until it lapses (or
  # you force-delete manually) - exactly what broke a prior apply here.
  # 0 = force-delete-without-recovery on destroy, matching what these
  # dev-environment secrets need: instantly reusable names, no grace
  # period. Don't carry this into a real production secret you'd want
  # a recovery window for if it were deleted by mistake.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "backend" {
  for_each      = local.backend_secret_keys
  secret_id     = aws_secretsmanager_secret.backend[each.value].id
  secret_string = local.backend_secret_plaintext[each.value]
}

# ---------------------------------------------------------------------------
# EKS - managed Kubernetes cluster + a SPOT-capacity node group, as an
# alternative worker platform to the ECS path above (not wired to it -
# ECS and EKS can both be enabled, or either alone).
# ---------------------------------------------------------------------------

module "eks" {
  source = "./modules/eks"
  count  = var.enable_eks ? 1 : 0

  project_name = var.project_name
  environment  = var.environment

  kubernetes_version = var.eks_kubernetes_version

  vpc_id                    = module.networking.vpc_id
  control_plane_subnet_ids  = concat(module.networking.public_subnet_ids, module.networking.private_subnet_ids)
  node_subnet_ids           = module.networking.private_subnet_ids

  endpoint_public_access       = var.eks_endpoint_public_access
  endpoint_public_access_cidrs = var.eks_endpoint_public_access_cidrs

  capacity_type   = var.eks_capacity_type
  instance_types  = var.eks_instance_types
  desired_size    = var.eks_desired_size
  min_size        = var.eks_min_size
  max_size        = var.eks_max_size

  # Defaults to the bastion's own security group when the bastion module
  # is enabled and no explicit override was passed, so node SSH "just
  # works" via the bastion once eks_ssh_key_pair_name is set - override
  # with eks_bastion_security_group_id for any other source SG.
  ssh_key_pair_name = var.eks_ssh_key_pair_name
  bastion_security_group_id = var.eks_bastion_security_group_id != "" ? var.eks_bastion_security_group_id : (
    var.enable_bastion ? try(module.bastion[0].bastion_security_group_id, "") : ""
  )

  lb_controller_install_method = var.eks_lb_controller_install_method
}

# Helm-based install of the AWS Load Balancer Controller - lives at root
# because the "helm" provider (configured in provider.tf) can't be set up
# inside modules/eks, which is invoked with count. Only created when
# eks_lb_controller_install_method = "helm" (the default - the managed
# EKS addon type doesn't have a build for every k8s version yet).
resource "helm_release" "lb_controller" {
  count = var.enable_eks && var.eks_lb_controller_install_method == "helm" ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"

  # Right after a fresh cluster/node group comes up, CoreDNS/VPC CNI can
  # still be settling - the chart's pre-install hook Job (self-signed
  # webhook cert generation) can take longer than the default 300s to
  # schedule and run in that window. atomic = true rolls back a failed
  # install automatically, so a timeout here doesn't leave a half-
  # installed release blocking the next `terraform apply` retry.
  timeout = 600
  atomic  = true

  set {
    name  = "clusterName"
    value = module.eks[0].cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.eks[0].lb_controller_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.networking.vpc_id
  }
}

module "ecs" {
  source = "./modules/ecs"
  count  = var.enable_ecs ? 1 : 0

  project_name = var.project_name
  environment  = var.environment
  aws_region   = var.aws_region

  vpc_id              = module.networking.vpc_id
  public_subnet_ids   = module.networking.public_subnet_ids
  private_subnet_ids  = module.networking.private_subnet_ids

  acm_certificate_arn = var.acm_certificate_arn

  backend_image_url       = local.ecr_repository_urls["backend"]
  backend_image_tag       = var.backend_image_tag
  backend_container_port  = var.backend_container_port
  backend_health_check_path = var.backend_health_check_path
  backend_desired_count   = var.backend_desired_count
  backend_environment     = var.backend_environment
  backend_secrets         = local.backend_secrets

  frontend_image_url      = local.ecr_repository_urls["frontend"]
  frontend_image_tag      = var.frontend_image_tag
  frontend_container_port = var.frontend_container_port
  frontend_desired_count  = var.frontend_desired_count
}
