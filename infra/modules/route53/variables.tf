variable "zone_id" {
  description = "Hosted zone ID (from the root's aws_route53_zone data lookup)."
  type        = string
}

variable "app_fqdn" {
  description = "Full hostname for the frontend, e.g. app.rentaride.example.com. Leave empty to skip creating this record."
  type        = string
  default     = ""
}

variable "cloudfront_domain_name" {
  description = "CloudFront distribution's domain_name (the d111111abcdef8.cloudfront.net value). Required when app_fqdn is set."
  type        = string
  default     = ""
}

variable "cloudfront_hosted_zone_id" {
  description = "CloudFront distribution's hosted_zone_id (fixed AWS value, exposed as a distribution attribute). Required when app_fqdn is set."
  type        = string
  default     = ""
}

variable "api_fqdn" {
  description = "Full hostname for the backend API, e.g. api.rentaride.example.com. Leave empty to skip creating this record."
  type        = string
  default     = ""
}

variable "alb_dns_name" {
  description = "ECS module's ALB DNS name (module.ecs[0].alb_dns_name). Required when api_fqdn is set."
  type        = string
  default     = ""
}

variable "alb_zone_id" {
  description = "ECS module's ALB hosted zone ID (module.ecs[0].alb_zone_id). Required when api_fqdn is set."
  type        = string
  default     = ""
}
