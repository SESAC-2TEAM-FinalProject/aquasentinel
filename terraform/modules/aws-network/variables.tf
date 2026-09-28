variable "project_name" {
  type = string
}

variable "environment" {
  description = "dev / dr-tokyo 등. environments/ 디렉토리 이름과 대응시킨다."
  type        = string
}

variable "region" {
  type = string
}

variable "availability_zones" {
  description = "이 리전에서 사용할 AZ 2개. 서울/도쿄 모두 AZ 이름이 달라 environment별로 넘겨받는다."
  type        = list(string)

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "AZ 2개 구성을 전제로 서브넷 CIDR을 나눴다 (계획서 11.7절)."
  }
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "ALB, NAT Gateway용. AZ당 1개."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "워커노드+파드용. /20으로 크게 잡는 이유는 prefix delegation이 연속된 /28 블록을 소모하기 때문 (계획서 11.7절)."
  type        = list(string)
  default     = ["10.0.16.0/20", "10.0.32.0/20"]
}

variable "private_data_subnet_cidrs" {
  description = "ElastiCache용 (관계형 DB는 CloudNativePG로 전환되어 K8s 워크로드로 이동, 이 서브넷을 쓰지 않음)."
  type        = list(string)
  default     = ["10.0.48.0/24", "10.0.49.0/24"]
}

variable "single_nat_gateway" {
  description = "true면 NAT Gateway를 1개만 생성해 비용을 절감한다 (계획서 16절 비용 제약)."
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "public/private-app 서브넷에 kubernetes.io/cluster/<name> 태그를 달기 위함 (ALB Controller, 오토스케일러의 서브넷 자동탐색용). 클러스터가 아직 없으면 null."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
