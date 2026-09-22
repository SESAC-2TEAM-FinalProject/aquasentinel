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
  type = string
}

variable "tfstate_bucket_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "rds_multi_az" {
  type    = bool
  default = false
}

variable "rds_skip_final_snapshot" {
  description = "false로 두면 destroy 시 최종 스냅샷을 남긴다 (계획서 18.5절)."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}
