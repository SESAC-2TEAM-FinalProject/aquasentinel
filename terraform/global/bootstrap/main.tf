provider "aws" {
  region = var.bootstrap_region

  default_tags {
    tags = {
      project    = var.project_name
      managed_by = "terraform"
      component  = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

# 모든 environment/component의 state가 여기 한 버킷 아래 key 경로로 나뉘어 저장된다.
# 경로 규칙: {environment}/{region}/{component}/terraform.tfstate
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # state 버킷은 실수로 지워지면 전체 인프라 추적이 끊기므로 보호한다.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
