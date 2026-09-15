# ---------------------------------------------------------------------------
# S3 bucket holding the built React app (client/dist). Private - no static
# website hosting endpoint, no public bucket policy of its own. CloudFront
# reaches it via Origin Access Control, the current (non-deprecated)
# replacement for the old OAI approach.
#
# Pure static-site distribution: app.<domain> -> CloudFront -> S3 only.
# api.<domain> is a separate Route53 alias straight to the ALB (see
# modules/route53) - no /api/* behavior or ALB origin lives here.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "frontend" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-${var.environment}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Bucket policy only allows GetObject, and only when the request came
# from *this* distribution (via the AWS:SourceArn condition) - not from
# any CloudFront distribution in the account.
data "aws_iam_policy_document" "frontend" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend.json
}

# ---------------------------------------------------------------------------
# CloudFront distribution - S3 is the only origin/behavior.
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = var.default_root_object
  price_class         = var.price_class
  aliases             = var.aliases

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # Managed-CachingOptimized - long TTL for the SPA's hashed static
    # assets; upload index.html itself with a short/no-cache
    # Cache-Control header in your deploy script so app updates show up
    # without needing a CloudFront invalidation every release.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # SPA client-side routing: a deep link typed directly in the URL bar
  # (e.g. /cars/123) has no matching S3 key and would otherwise 403
  # straight from S3 - rewrite 403/404 to index.html so React Router
  # takes over client-side.
  dynamic "custom_error_response" {
    for_each = var.spa_mode ? [403, 404] : []
    content {
      error_code         = custom_error_response.value
      response_code      = 200
      response_page_path = "/${var.default_root_object}"
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn            = var.acm_certificate_arn == "" ? null : var.acm_certificate_arn
    cloudfront_default_certificate = var.acm_certificate_arn == "" ? true : null
    ssl_support_method             = var.acm_certificate_arn == "" ? null : "sni-only"
    minimum_protocol_version       = var.acm_certificate_arn == "" ? null : "TLSv1.2_2021"
  }
}
