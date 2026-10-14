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
  description = "가용성/DR 재구축 개선안(2026-10-13)에 따라 2a/2c 2개에서 2b를 추가해 3개로 확장. count 기반 리소스라 기존 2a/2c의 인덱스(0,1)가 바뀌면 그 서브넷들이 강제 교체되므로, 신규 AZ(2b)는 반드시 리스트 맨 끝(인덱스 2)에 추가한다 — 기존 순서를 바꾸지 않는다."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c", "ap-northeast-2b"]
}

# 모듈 기본값(public/private-app/private-data 각 2개 CIDR)은 AZ 2개 전제라, 3번째 AZ(2b)를
# 추가하면서 여기서 3개짜리 CIDR 리스트로 명시적으로 오버라이드한다. 기존 2a/2c 값(인덱스 0,1)은
# 그대로 유지하고, 2b 몫은 반드시 리스트 맨 끝(인덱스 2)에 추가한다 — availability_zones와
# 순서를 맞추지 않으면(예: 중간에 끼워넣으면) 기존 2c 서브넷이 강제 교체된다.
variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.16.0/20", "10.0.32.0/20", "10.0.64.0/20"]
}

variable "private_data_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.48.0/24", "10.0.49.0/24", "10.0.50.0/24"]
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
