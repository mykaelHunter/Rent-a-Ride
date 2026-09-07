variable "project_name" {
  description = "Short name used to prefix repository names."
  type        = string
}

variable "repository_names" {
  description = "Short component names to create one ECR repo each for (final name: <project_name>-<name>)."
  type        = list(string)
  default     = ["backend", "frontend"]
}

variable "image_tag_mutability" {
  description = "Whether image tags can be overwritten (MUTABLE) or not (IMMUTABLE)."
  type        = string
  default     = "MUTABLE"
}

variable "scan_on_push" {
  description = "Whether to run vulnerability scanning automatically on every image push."
  type        = bool
  default     = true
}

variable "max_image_count" {
  description = "Max number of tagged images to retain per repository before the oldest are expired."
  type        = number
  default     = 10
}
