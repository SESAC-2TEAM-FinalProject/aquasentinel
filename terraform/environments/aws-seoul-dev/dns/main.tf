terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = var.project_name
      owner       = var.owner
      environment = var.environment
      managed_by  = "terraform"
      component   = "dns"
    }
  }
}

module "dns" {
  source = "../../../modules/aws-dns"

  project_name = var.project_name
  environment  = var.environment
  domain_name  = var.domain_name
}
