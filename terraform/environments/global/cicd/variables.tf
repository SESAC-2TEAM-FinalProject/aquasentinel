variable "project_name" {
  type    = string
  default = "aquasentinel"
}

variable "owner" {
  type    = string
  default = "team-aquasentinel"
}

variable "region" {
  description = "IAM/OIDC provider는 글로벌 리소스라 어느 리전이든 무방하다. 서울로 고정."
  type        = string
  default     = "ap-northeast-2"
}

variable "github_repository" {
  description = "\"org/repo\" 형식. 실제 저장소가 정해지면 terraform.tfvars에 채운다."
  type        = string
}

variable "github_branch" {
  type    = string
  default = "main"
}
