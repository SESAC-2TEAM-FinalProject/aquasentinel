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
  default = "dr-tokyo"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "eks_cluster_name" {
  description = "eks 컴포넌트가 실제로 생성할 클러스터 이름과 반드시 일치해야 한다 (environments/aws-tokyo-dr/eks/variables.tf의 cluster_name)."
  type        = string
  default     = "aquasentinel-dr-apne1-eks"
}
