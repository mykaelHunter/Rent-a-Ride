# Region-agnostic: this module has no opinion on which region the cert
# lands in. The caller decides via the module block's own `providers =`
# argument - e.g. `providers = { aws = aws.us_east_1 }` for a CloudFront
# cert (CloudFront only accepts certs from us-east-1), or the default
# `aws` provider for an ALB cert (which must match the ALB's own region).

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# One DNS record per domain name on the cert (apex + SANs) - Route53
# handles duplicate record sets across SANs that share a validation
# name/value automatically via the distinct() below.
resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}
