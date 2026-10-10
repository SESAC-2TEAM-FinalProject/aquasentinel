terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # 부트스트랩 자체는 local state로 실행한다.
  # (backend를 만드는 코드가 그 backend를 쓸 수는 없다)
}
