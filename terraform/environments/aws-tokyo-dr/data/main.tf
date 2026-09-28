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
      component   = "data"
    }
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/eks/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

module "data" {
  source = "../../../modules/aws-data"

  project_name              = var.project_name
  environment               = var.environment
  vpc_id                    = data.terraform_remote_state.network.outputs.vpc_id
  private_data_subnet_ids   = data.terraform_remote_state.network.outputs.private_data_subnet_ids
  allowed_security_group_id = data.terraform_remote_state.eks.outputs.cluster_security_group_id

  redis_node_type                  = var.redis_node_type
  redis_automatic_failover_enabled = var.redis_automatic_failover_enabled
}
