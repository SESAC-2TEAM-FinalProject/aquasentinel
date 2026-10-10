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
  type    = string
  default = "ap-northeast-2"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "eks_cluster_name" {
  description = "2-cluster 컴포넌트가 실제로 생성할 클러스터 이름과 반드시 일치해야 한다."
  type        = string
  default     = "aquasentinel-dev-apne2-eks"
}
