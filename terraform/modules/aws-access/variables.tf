variable "cluster_name" {
  description = "aws-eks 모듈 output.cluster_name."
  type        = string
}

variable "team_members" {
  description = "팀원 3명(A/B/C — 원 계획서 D의 업무는 A/B/C가 나눠 흡수). iam_arn은 각자의 IAM User 또는 Role ARN."
  type = list(object({
    name    = string
    iam_arn = string
  }))
}

variable "access_policy_arn" {
  description = "전원 클러스터 관리자로 시작한다 — 계획서 18.3절(가상 사용자 기반, 실사용자 없음)을 근거로 권한 세분화 실익이 낮다고 판단. 이 결정은 ADR로 기록할 것."
  type        = string
  default     = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
}
