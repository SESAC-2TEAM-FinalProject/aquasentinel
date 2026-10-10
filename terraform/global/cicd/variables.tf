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

variable "gitlab_project_path" {
  description = "GitLab 프로젝트 경로(그룹/프로젝트), 예: SESAC-2TEAM-FinalProject/aquasentinel. OIDC sub 클레임의 project_path 부분과 정확히 일치해야 한다."
  type        = string
}
