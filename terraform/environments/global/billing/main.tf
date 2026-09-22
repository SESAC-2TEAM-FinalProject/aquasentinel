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

# Cost Explorer/Budgets API는 us-east-1 엔드포인트를 기준으로 한다.
# 실제 리소스(EKS 등)는 서울/도쿄에 있어도 이 컴포넌트만 us-east-1을 쓴다.
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      project    = var.project_name
      owner      = var.owner
      managed_by = "terraform"
      component  = "billing"
    }
  }
}

module "billing" {
  source = "../../../modules/aws-billing"

  project_name               = var.project_name
  budget_limit_usd           = var.budget_limit_usd
  budget_notification_emails = var.budget_notification_emails
}
