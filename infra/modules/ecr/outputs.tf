output "repository_urls" {
  description = "Map of component name -> repository URL (e.g. backend -> 123.dkr.ecr.us-east-1.amazonaws.com/rent-a-ride-backend)."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Map of component name -> repository ARN."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}

output "repository_names" {
  description = "Map of component name -> full repository name."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.name }
}
