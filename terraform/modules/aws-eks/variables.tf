variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "EKS 컨트롤플레인 ENI가 위치할 서브넷. 컨트롤플레인은 subnet_ids 변경이 in-place라 AZ를 늘려도 안전하다."
  type        = list(string)
}

variable "node_group_subnet_ids" {
  description = "관리형 노드그룹(aws_eks_node_group.default) 전용 서브넷. subnet_ids 변경 시 노드그룹이 강제 교체되므로 private_subnet_ids와 분리했다 — 카펜터 도입(2026-10-13) 이후 이 노드그룹은 축소될 고정분이라 서브넷을 더 늘릴 계획이 없다."
  type        = list(string)
}

variable "endpoint_public_access" {
  description = "true면 클러스터 API를 인터넷에서 kubectl로 접근 가능. 8주 프로젝트라 VPN/bastion 없이 public으로 시작한다 — 반드시 ADR로 사유를 기록할 것 (계획서 9절 원칙, 11.5절 결정기준과 동일한 성격)."
  type        = bool
  default     = true
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
  description = "SPOT 기본 (계획서 16절 비용 제약)."
  type        = string
  default     = "SPOT"
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

variable "node_labels" {
  description = "관리형 노드그룹(aws_eks_node_group.default) 전체에 적용할 쿠버네티스 노드 라벨."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "관리형 노드그룹 전체에 적용할 taint 목록. effect는 AWS API 표기(NO_SCHEDULE/NO_EXECUTE/PREFER_NO_SCHEDULE)를 쓴다 — kubectl이 보여주는 NoSchedule 표기와 다르다."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "enable_prefix_delegation" {
  description = "VPC CNI Prefix Delegation 활성화 여부. 계획서 11.1/11.5절 — 파드 70~80개 전망에 ENI 슬롯이 부족해 반드시 켜야 한다. 새로 조인하는 노드에만 적용되므로 클러스터 생성 시점에 켠다."
  type        = bool
  default     = true
}

variable "enable_network_policy" {
  description = "VPC CNI 네트워크 정책 집행(vpc-cni enableNetworkPolicy). 끄면 NetworkPolicy 객체가 있어도 집행되지 않는다. 켜는 순간 클러스터에 이미 있는 정책(argocd·keycloak 등)도 처음으로 집행되므로, 켤 때 그 파드들이 READY를 유지하는지 확인한다(egress 작업계획서 2장 단계 2)."
  type        = bool
  default     = false
}

variable "max_pods_per_node" {
  description = "커스텀 launch template으로 EKS 부트스트랩에 병합하는 kubelet --max-pods 값 (계획서 11.1절 근거)."
  type        = number
  default     = 110
}

variable "enable_ebs_csi" {
  description = "EBS CSI 드라이버 애드온 활성화. Prometheus/Loki/Grafana의 PVC(4주차)가 이걸 전제로 한다."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
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

variable "readonly_principal_arns" {
  description = "클러스터를 읽기만 하는 IAM 주체(사람이 아닌 CI 역할 등). AmazonEKSAdminViewPolicy — 시크릿을 포함해 모든 리소스 읽기, 쓰기 없음. 예: Terraform plan 역할(3-gitops plan 이 Argo CD Application · 시크릿을 읽어야 한다)."
  type        = list(string)
  default     = []
}

variable "group_access_entries" {
  description = "쿠버네티스 그룹으로만 권한을 받는 IAM 주체(접근 정책 연결 없음 — 권한은 클러스터 안 RBAC 가 정한다). 키는 식별자. 예: CI 알람 점검 역할 → 그룹 aquasentinel:alert-maintenance(gitops manifests/alerting/routing/rbac-maintenance.yaml)."
  type = map(object({
    principal_arn     = string
    kubernetes_groups = list(string)
  }))
  default = {}
}
