variable "project_name" {
  type = string
}

variable "gitlab_project_path" {
  description = "GitLab 프로젝트 경로(그룹/프로젝트), 예: SESAC-2TEAM-FinalProject/aquasentinel. OIDC sub 클레임의 project_path 부분과 정확히 일치해야 한다."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
