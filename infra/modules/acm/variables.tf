variable "domain_name" {
  description = "Primary domain the certificate covers, e.g. rentaride.example.com."
  type        = string
}

variable "subject_alternative_names" {
  description = "Additional names on the same cert, e.g. [\"www.rentaride.example.com\"]."
  type        = list(string)
  default     = []
}

variable "route53_zone_id" {
  description = "Hosted zone ID to create DNS validation records in."
  type        = string
}
