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
  description = "bootstrap output.tfstate_bucket_name 값. network 컴포넌트 state를 읽기 위해 필요."
  type        = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

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
