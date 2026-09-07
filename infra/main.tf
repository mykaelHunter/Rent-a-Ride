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
  backend_desired_count   = var.backend_desired_count
  backend_environment     = var.backend_environment
  backend_secrets         = var.backend_secrets

  frontend_image_url      = local.ecr_repository_urls["frontend"]
  frontend_image_tag      = var.frontend_image_tag
  frontend_container_port = var.frontend_container_port
  frontend_desired_count  = var.frontend_desired_count
}
