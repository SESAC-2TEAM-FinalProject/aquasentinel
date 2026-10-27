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

# 🔴 서울과 같은 「온디맨드 고정 3대」 구조로 맞춘다(2026-10-25).
# seoul/rebuild/2-cluster/variables.tf 가 ON_DEMAND · 3/3/3 이고, 노드가 2a/2b/2c 에
# 하나씩 앉아 CNPG 3개도 AZ 하나씩 앉는다(2026-10-24 운영 실측으로 확인).
#
# 왜 SPOT 2대에서 바꾸는가 —
#  1) AZ: 3 AZ 로 늘려도 **노드가 2대면 노드가 있는 AZ 가 2개**라 CNPG 3번째
#     인스턴스가 여전히 Pending 이다(cluster.yaml 이 AZ 당 1개를 강제). AZ 3개와
#     노드 3대는 한 묶음이다.
#  2) SPOT: 서울에서 grading 이 스팟 회수마다 죽어(하루 약 5회) 2026-10-23~24 에
#     스팟을 0대까지 없앴다(SIM-14 · ⑤ 관문 6/6). DR 대기 리전이 스팟이면 실제
#     전환 시점에 회수가 겹칠 수 있어 같은 교훈을 적용한다.
#  3) max 를 3 으로 묶는 것도 서울과 같다 — 스테이트풀 전용 고정 노드그룹이라
#     ASG 가 임의로 늘리지 않게 한다. 🔴 단 도쿄엔 Karpenter 가 없어(「도쿄 반영
#     목록」 #3) 일반 워크로드용 자동 증설 경로가 없다 — 용량이 모자라면 이 값을
#     올려야 한다. 2026-10-24 계산으로는 3대에서 CPU 54% · MEM 49% 로 여유가 있다.
variable "node_capacity_type" {
  type    = string
  default = "ON_DEMAND"
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "enable_prefix_delegation" {
  type    = bool
  default = true
}

# VPC CNI 네트워크 정책 집행 — 기본 꺼짐. 도쿄는 서울에서 검증한 뒤 같은 방식으로 켠다
# (egress 작업계획서 2장 단계 2 — 켜는 순간 argocd·keycloak 정책도 처음 집행되므로 사전 공지 + READY 확인).
variable "enable_network_policy" {
  type    = bool
  default = false
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

variable "grafana_namespace" {
  type    = string
  default = "monitoring"
}

variable "grafana_service_account_name" {
  description = "차트가 기본으로 만드는 SA 이름이 이미 grafana 라 그 이름을 그대로 쓴다 — 3-gitops bootstrap.tf 가 같은 이름으로 만들어 role-arn 을 붙인다(서울과 같은 패턴)."
  type        = string
  default     = "grafana"
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
