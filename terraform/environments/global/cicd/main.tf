terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
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
      project    = var.project_name
      owner      = var.owner
      managed_by = "terraform"
      component  = "cicd"
    }
  }
}

module "cicd" {
  source = "../../../modules/aws-cicd"

  project_name      = var.project_name
  github_repository = var.github_repository
  github_branch     = var.github_branch
}
