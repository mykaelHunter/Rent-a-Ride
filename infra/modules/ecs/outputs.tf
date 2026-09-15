output "alb_dns_name" {
  description = "Public DNS name of the ALB - point your domain's CNAME/ALIAS here."
  value       = aws_lb.this.dns_name
}

output "alb_zone_id" {
  description = "ALB's hosted zone ID, needed alongside alb_dns_name for a Route53 alias record."
  value       = aws_lb.this.zone_id
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "backend_service_name" {
  value = aws_ecs_service.backend.name
}

output "frontend_service_name" {
  value = var.enable_frontend ? aws_ecs_service.frontend[0].name : null
}

output "backend_log_group" {
  value = aws_cloudwatch_log_group.backend.name
}

output "frontend_log_group" {
  value = var.enable_frontend ? aws_cloudwatch_log_group.frontend[0].name : null
}
