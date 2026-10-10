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

variable "tfstate_bucket" {
  description = "bootstrap output.tfstate_bucket_name 값(서울 리전 버킷을 그대로 참조). 1-network/persistent/seoul-persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

# --- EKS ---

variable "cluster_name" {
  type    = string
  default = "aquasentinel-dr-apne1-eks"
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "endpoint_public_access" {
  type    = bool
  default = true
}

variable "endpoint_private_access" {
  type    = bool
  default = true
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.large"]
}

variable "node_capacity_type" {
  type    = string
  default = "SPOT"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "enable_prefix_delegation" {
  type    = bool
  default = true
}

variable "max_pods_per_node" {
  type    = number
  default = 110
}

variable "enable_ebs_csi" {
  type    = bool
  default = true
}

variable "team_members" {
  description = "팀원 3명(A/B/C). iam_arn은 각자의 IAM User 또는 Role ARN. 서울과 동일 목록."
  type = list(object({
    name    = string
    iam_arn = string
  }))
}

variable "access_policy_arn" {
  type    = string
  default = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
}

# --- Redis ---

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "redis_automatic_failover_enabled" {
  description = "도쿄 드릴 환경은 비용에 민감해 기본 false(단일 노드) 유지."
  type        = bool
  default     = false
}

# --- IRSA: 네임스페이스/서비스어카운트 (서울과 동일 값 — 실제 사고로 확인된
# thanos/cloudnativepg SA 이름도 동일하게 적용) ---

variable "lbc_namespace" {
  type    = string
  default = "kube-system"
}

variable "lbc_service_account_name" {
  type    = string
  default = "aws-load-balancer-controller"
}

variable "eso_namespace" {
  type    = string
  default = "external-secrets"
}

variable "eso_service_account_name" {
  type    = string
  default = "external-secrets"
}

variable "thanos_namespace" {
  type    = string
  default = "monitoring"
}

variable "thanos_service_account_name" {
  description = "kube-prometheus-stack 차트가 자동 생성하는 Prometheus ServiceAccount 이름 그대로 써야 한다(서울과 동일 사고 이력, 2-cluster irsa.tf 주석 참고)."
  type        = string
  default     = "kube-prometheus-stack-prometheus"
}

variable "loki_namespace" {
  type    = string
  default = "monitoring"
}

variable "loki_service_account_name" {
  type    = string
  default = "loki"
}

variable "cloudnativepg_namespace" {
  type    = string
  default = "aquasentinel-db"
}

variable "cloudnativepg_service_account_name" {
  description = "CNPG는 serviceAccountTemplate으로 이름을 새로 짓지 못하고 Cluster 리소스 이름과 같은 이름의 서비스어카운트를 자동 생성한다 — 서울과 같은 매니페스트를 재사용하므로 같은 값."
  type        = string
  default     = "aquasentinel-pg"
}

variable "api_module_namespace" {
  type    = string
  default = "api-module"
}

variable "collector_service_account_name" {
  type    = string
  default = "collector"
}

variable "processor_service_account_name" {
  type    = string
  default = "processor"
}

variable "tags" {
  type    = map(string)
  default = {}
}
