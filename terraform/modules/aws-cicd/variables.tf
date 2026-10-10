variable "project_name" {
  type = string
}

variable "gitlab_project_id" {
  description = "GitLab 프로젝트의 숫자 ID(프로젝트 개요 화면 'Project ID'). 2026-10-10, project_path 기반 sub 클레임에서 전환 — GitLab이 '이 경로를 과거 다른 프로젝트가 쓴 적 있음'을 이유로 ID 토큰 발급 자체를 막는 재사용 방지 보안 기능에 걸려서, path보다 불변인 project_id로 옮겼다(GitLab 프로젝트의 ci_id_token_sub_claim_components를 [\"project_id\",\"ref_type\",\"ref\"]로 맞춰야 함)."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "build_projects" {
  description = "이미지 빌드·ECR 푸시 역할을 만들 GitLab 프로젝트 목록. 키는 역할 이름에 쓰는 짧은 식별자(예: web)."
  type = map(object({
    gitlab_project_id = string
    ecr_repositories  = list(string) # 계정/리전 접두사 없는 리포지토리 이름만 (예: aquasentinel-dev/status-svc)
  }))
  default = {}
}
