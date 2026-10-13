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

variable "tfstate_bucket_name" {
  description = "tfstate 버킷 이름(global/bootstrap output). plan 역할이 ReadOnlyAccess뿐이라 Terraform 1.10 S3 네이티브 락(.tflock, use_lockfile=true)의 PutObject/DeleteObject를 별도로 허용해야 한다 — 2026-10-12, plan:seoul 파이프라인 첫 실제 실행에서 'AccessDenied: s3:PutObject on .../*.tflock' 발견."
  type        = string
}

variable "build_projects" {
  description = "이미지 빌드·ECR 푸시 역할을 만들 GitLab 프로젝트 목록. 키는 역할 이름에 쓰는 짧은 식별자(예: web)."
  type = map(object({
    gitlab_project_id = string
    ecr_repositories  = list(string) # 계정/리전 접두사 없는 리포지토리 이름만 (예: aquasentinel-dev/status-svc)
  }))
  default = {}
}

variable "plan_readable_secret_names" {
  description = "plan 역할이 값을 읽어야 하는 Secrets Manager 비밀 이름(정확한 이름, 모든 리전). ReadOnlyAccess 는 GetSecretValue 를 일부러 빼 두므로 따로 허용한다 — 2026-10-13, 3-gitops plan 이 data.aws_secretsmanager_secret_version.gitops_pat 에서 AccessDenied. 필요한 비밀만 좁게 넣는다."
  type        = list(string)
  default     = []
}
