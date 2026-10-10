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

variable "tfstate_bucket" {
  description = "bootstrap output.tfstate_bucket_name 값. 1-network/persistent state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

# --- EKS ---

variable "cluster_name" {
  type    = string
  default = "aquasentinel-dev-apne2-eks"
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
  description = "팀원 3명(A/B/C). iam_arn은 각자의 IAM User 또는 Role ARN."
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
  type    = bool
  default = true
}

# --- IRSA: 네임스페이스/서비스어카운트 ---
# thanos/cloudnativepg 기본값은 모듈 기본값이 아니라 실제 사고(2026-10-08)로
# 확인된 값이다 — irsa.tf 상단 주석 참고. 바꾸기 전에 반드시 실제 차트/
# 오퍼레이터가 만드는 SA 이름과 일치하는지 확인할 것.

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
  description = "kube-prometheus-stack 차트가 자동 생성하는 Prometheus ServiceAccount 이름 그대로 써야 한다(2026-10-08 thanos-sidecar S3 Access Denied로 확인된 실제값)."
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
  description = "CNPG는 serviceAccountTemplate으로 이름을 새로 짓지 못하고 Cluster 리소스 이름(manifests/cloudnativepg-cluster/cluster.yaml 기준)과 같은 이름의 서비스어카운트를 자동 생성한다 — 실제 페일오버 테스트 중 AccessDenied로 확인된 값."
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
  description = "reprocess Job·completeness-check도 processor 이미지를 재사용하므로 같은 SA를 쓴다."
  type        = string
  default     = "processor"
}

variable "tags" {
  type    = map(string)
  default = {}
}
