# Split-subdomain DNS: app.<domain> aliases to CloudFront, api.<domain>
# aliases straight to the ALB. Both are alias records (not CNAMEs) - free,
# and the only way Route53 lets you point a name at another AWS resource's
# dynamic endpoint like this.

resource "aws_route53_record" "app" {
  count   = var.app_fqdn == "" ? 0 : 1
  zone_id = var.zone_id
  name    = var.app_fqdn
  type    = "A"

  alias {
    name                   = var.cloudfront_domain_name
    zone_id                = var.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "app_aaaa" {
  count   = var.app_fqdn == "" ? 0 : 1
  zone_id = var.zone_id
  name    = var.app_fqdn
  type    = "AAAA"

  alias {
    name                   = var.cloudfront_domain_name
    zone_id                = var.cloudfront_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api" {
  count   = var.api_fqdn == "" ? 0 : 1
  zone_id = var.zone_id
  name    = var.api_fqdn
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = false
  }
}
