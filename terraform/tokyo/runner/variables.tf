variable "project_name" {
  type    = string
  default = "aquasentinel"
}

variable "owner" {
  type    = string
  default = "team-aquasentinel"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "region" {
  description = "이 러너가 사는 리전. 서울이 빠졌을 때 살아 있어야 하므로 도쿄다."
  type        = string
  default     = "ap-northeast-1"
}

variable "instance_type" {
  description = "러너 EC2 인스턴스 타입. 서울 러너와 같은 사양으로 둔다 — 재해 때 돌릴 것이 같은 tokyo/rebuild/* 컴포넌트라 요구 사양도 같다."
  type        = string
  default     = "t3.medium"
}

variable "runner_concurrent" {
  description = "config.toml concurrent 값. 서울 러너와 같은 3 — 재해 때 tokyo/rebuild/* 를 순차로 돌리는 용도라 더 올릴 이유가 없다."
  type        = number
  default     = 3
}

variable "token_secret_name" {
  description = <<-EOT
    GitLab 러너 등록 토큰이 든 Secrets Manager 시크릿 이름. **도쿄 리전**에 있어야 한다.
    🔴 이 컴포넌트가 만들지 않는다 — 다른 모든 시크릿과 같은 수동 관리 패턴이고,
    GitLab UI 에서 러너를 먼저 만들어야 토큰이 나온다. 도쿄 시크릿 이름 규칙
    (aquasentinel-dr-tokyo-*)을 따른다.
  EOT
  type        = string
  default     = "aquasentinel-dr-tokyo-gitlab-runner-token"
}
