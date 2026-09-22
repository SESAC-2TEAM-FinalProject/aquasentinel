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
  description = "EKS 컨트롤플레인 ENI + 워커노드가 위치할 서브넷 (private-app, 2개 AZ)."
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

variable "enable_prefix_delegation" {
  description = "VPC CNI Prefix Delegation 활성화 여부. 계획서 11.1/11.5절 — 파드 70~80개 전망에 ENI 슬롯이 부족해 반드시 켜야 한다. 새로 조인하는 노드에만 적용되므로 클러스터 생성 시점에 켠다."
  type        = bool
  default     = true
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
