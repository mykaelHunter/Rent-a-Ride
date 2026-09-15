provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront + ACM-for-CloudFront are global services that only accept
# certificates issued in us-east-1, regardless of what region the rest
# of the stack (ALB, ECS, etc.) runs in. This alias is only exercised
# when enable_dns_ssl = true.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Only ever actually used when enable_eks = true and
# lb_controller_install_method = "helm" (the default) - the resources
# that use it are count-gated in main.tf, so this sits inert otherwise.
# try() guards every field since module.eks[0] doesn't exist at all when
# enable_eks = false, which would otherwise break plan/validate.
provider "helm" {
  kubernetes {
    host                   = try(module.eks[0].cluster_endpoint, "")
    cluster_ca_certificate = try(base64decode(module.eks[0].cluster_certificate_authority_data), "")
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", try(module.eks[0].cluster_name, ""), "--region", var.aws_region]
    }
  }
}
