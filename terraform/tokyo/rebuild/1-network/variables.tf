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
  description = "서울과 같은 3 AZ 구조로 확장(2026-10-25) — CNPG cluster.yaml 이 instances=3 에 podAntiAffinityType=required + topologyKey=zone 이라 **AZ 당 1개**를 강제하므로, 2 AZ 에서는 3번째 인스턴스가 영구 Pending 이었다. 🔴 ap-northeast-1 에는 1b 가 없다(1a/1c/1d 뿐) — 세 번째는 1d 다. count 기반 리소스라 신규 AZ 는 반드시 리스트 맨 끝(인덱스 2)에 둔다(서울 1-network/variables.tf 주석과 같은 이유) — 지금은 도쿄 VPC 가 0개라 교체 위험이 없지만, 나중에 순서를 바꾸면 기존 서브넷이 강제 교체된다."
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c", "ap-northeast-1d"]
}

# 🔴 도쿄는 서울과 **다른** CIDR 를 쓴다 — VPC 피어링을 염두에 둔 결정(2026-10-25).
# 서울은 모듈 기본값 10.0.0.0/16 을 그대로 쓰는데, 두 리전이 같은 블록이면 피어링
# 자체가 불가능하다(CIDR 중복). 그래서 도쿄만 여기서 10.1.0.0/16 으로 명시한다.
# 서브넷 쪼개는 방식(public /24 · private-app /20 · private-data /24)과 오프셋은
# 서울과 똑같이 맞췄다 — 세 번째 자리(2.0/64.0/50.0)까지 동일하다.
#
# 모듈 기본값(각 2개 CIDR)은 AZ 2개 전제라 3 AZ 로 가면 validation 에 걸린다
# (modules/aws-network/variables.tf 가 availability_zones 길이 == 각 CIDR 리스트
# 길이를 세 번 검증한다) — 그래서 네 변수를 전부 넘겨야 한다.
variable "vpc_cidr" {
  description = "도쿄 VPC CIDR. 서울(10.0.0.0/16)과 겹치지 않게 10.1.0.0/16 을 쓴다 — VPC 피어링 대비."
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.0.0/24", "10.1.1.0/24", "10.1.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.16.0/20", "10.1.32.0/20", "10.1.64.0/20"]
}

variable "private_data_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.48.0/24", "10.1.49.0/24", "10.1.50.0/24"]
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "eks_cluster_name" {
  description = "2-cluster 컴포넌트가 실제로 생성할 클러스터 이름과 반드시 일치해야 한다."
  type        = string
  default     = "aquasentinel-dr-apne1-eks"
}
