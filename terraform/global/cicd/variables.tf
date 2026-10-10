variable "project_name" {
  type    = string
  default = "aquasentinel"
}

variable "owner" {
  type    = string
  default = "team-aquasentinel"
}

variable "region" {
  description = "IAM/IRSA Role은 글로벌 리소스라 어느 리전이든 무방하다. 서울로 고정."
  type        = string
  default     = "ap-northeast-2"
}

variable "gitlab_project_id" {
  description = "GitLab 프로젝트의 숫자 ID(프로젝트 개요 화면 'Project ID'). project_path 재사용 방지 보안 기능 때문에 2026-10-10 전환 — modules/aws-cicd/variables.tf 주석 참고."
  type        = string
}

variable "web_gitlab_project_id" {
  description = "aquasentinel-web GitLab(미러) 프로젝트의 숫자 ID — 이미지 빌드·ECR 푸시 역할의 신뢰 조건에 쓴다(2026-10-11, 웹 CI 자동화)."
  type        = string
}
