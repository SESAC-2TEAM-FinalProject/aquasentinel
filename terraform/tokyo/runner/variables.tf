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

variable "runner_desired_capacity" {
  description = <<-EOT
    도쿄 러너 ASG 의 desired/min 용량. **기본 0 — 평소엔 꺼 둔다**(2026-11-01 · 비용).

    🔴 왜 0 이 기본인가 — 이 러너는 **DR 훈련과 재해 때만** 쓴다. 전에는 1 로 띄워 놓고
      GitLab 에서 Pause 로 막았는데, ⒜ t3.medium 이 계속 과금되고 ⒝ 태그
      `eks-self-hosted` 가 서울과 겹쳐 **Pause 가 풀리면 서울 잡을 가로챈다.**
      용량 0 이면 인스턴스가 아예 없어 두 문제가 같이 없어진다.

    🔴 terminate 로는 끌 수 없다 `[2026-10-31 실측]` — ASG 가 desired 를 맞추려고
      **91초 뒤 새 인스턴스를 띄웠다**(`i-0a6ffc9fe8534f93c` 종료 16:10:44Z →
      `i-01211d32dd0ff94b2` 생성 16:12:15Z). 끄려면 이 값을 0 으로 두어야 한다.

    🔴 깨울 때 — 이 값을 **1** 로 주고 apply 한다. `max_size` 는 1 로 고정이라
      따로 올릴 것이 없다. 런치 템플릿·SG·IAM·등록 토큰 시크릿은 그대로 남는다.
      🔸 새 인스턴스는 부팅 때 **새 러너로 등록**되므로 GitLab 러너 목록에
      Offline 항목이 쌓인다 — 깨운 뒤 새 항목의 Pause 상태를 확인한다
      (runbooks/도쿄러너_재해때_깨우기.md).
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.runner_desired_capacity >= 0 && var.runner_desired_capacity <= 1
    error_message = "max_size 가 1 이라 0 또는 1 만 쓸 수 있습니다."
  }
}
