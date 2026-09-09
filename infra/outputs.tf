# --- Networking ---

output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_ids" {
  value = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

output "nat_gateway_public_ip" {
  value = module.networking.nat_gateway_public_ip
}

# --- Bastion (only present when enable_bastion = true) ---

output "bastion_public_ip" {
  value = try(module.bastion[0].bastion_public_ip, null)
}

output "app_private_ip" {
  value = try(module.bastion[0].app_private_ip, null)
}

output "ssh_bastion_command" {
  value = try(module.bastion[0].ssh_bastion_command, null)
}

output "ssh_app_command" {
  value = try(module.bastion[0].ssh_app_command, null)
}

# --- ECR (only present when enable_ecr = true) ---

output "ecr_repository_urls" {
  value = try(module.ecr[0].repository_urls, {})
}

# --- Monitoring (only present when enable_bastion and enable_monitoring = true) ---

output "sns_topic_arn" {
  value = try(module.monitoring[0].sns_topic_arn, null)
}

output "alarm_names" {
  value = try(module.monitoring[0].alarm_names, null)
}

output "grafana_url" {
  value = try(module.monitoring[0].grafana_url, null)
}

# --- EKS (only present when enable_eks = true) ---

output "eks_cluster_name" {
  value = try(module.eks[0].cluster_name, null)
}

output "eks_cluster_endpoint" {
  value = try(module.eks[0].cluster_endpoint, null)
}

output "eks_node_group_name" {
  value = try(module.eks[0].node_group_name, null)
}

output "eks_configure_kubectl" {
  value = try(module.eks[0].configure_kubectl, null)
}

# --- ECS (only present when enable_ecs = true) ---

output "alb_dns_name" {
  description = "Point this at your app's URL / DNS record."
  value       = try(module.ecs[0].alb_dns_name, null)
}

output "ecs_cluster_name" {
  value = try(module.ecs[0].cluster_name, null)
}

output "ecs_backend_service_name" {
  value = try(module.ecs[0].backend_service_name, null)
}

output "ecs_frontend_service_name" {
  value = try(module.ecs[0].frontend_service_name, null)
}
