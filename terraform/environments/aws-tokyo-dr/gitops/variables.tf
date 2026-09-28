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
