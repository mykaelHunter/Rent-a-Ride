output "alb_dns_name" {
  description = "Public DNS name of the ALB - point your domain's CNAME/ALIAS here."
  value       = aws_lb.this.dns_name
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "backend_service_name" {
  value = aws_ecs_service.backend.name
}

output "frontend_service_name" {
  value = aws_ecs_service.frontend.name
}

output "backend_log_group" {
  value = aws_cloudwatch_log_group.backend.name
}

output "frontend_log_group" {
  value = aws_cloudwatch_log_group.frontend.name
}
