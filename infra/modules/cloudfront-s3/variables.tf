variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name for the built frontend assets (client/dist). Bucket stays fully private - CloudFront reaches it via Origin Access Control, nothing is public directly."
  type        = string
}

variable "aliases" {
  description = "CNAMEs for the distribution, e.g. [\"app.rentaride.example.com\"]. Must all be covered by acm_certificate_arn (SANs or primary name). Leave empty to serve only on the default *.cloudfront.net domain."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN, MUST be issued in us-east-1 - CloudFront rejects certs from any other region. Leave empty to serve on the default CloudFront certificate (no custom aliases possible in that case)."
  type        = string
  default     = ""
}

variable "price_class" {
  description = "PriceClass_100 (US/EU/Canada only, cheapest), PriceClass_200 (adds Asia/Africa/Oceania), or PriceClass_All."
  type        = string
  default     = "PriceClass_100"
}

variable "default_root_object" {
  type    = string
  default = "index.html"
}

variable "spa_mode" {
  description = "If true, map S3 403/404 responses to /index.html with a 200 so client-side routing (React Router etc.) works on a hard refresh of a deep link."
  type        = bool
  default     = true
}
