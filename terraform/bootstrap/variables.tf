variable "project_name" {
  description = "프로젝트 식별자. 모든 리소스 네이밍의 접두사로 쓰인다."
  type        = string
  default     = "aquasentinel"
}

variable "bootstrap_region" {
  description = "Terraform state 버킷을 생성할 리전. 이 버킷 하나가 모든 environment(dev/dr-tokyo)의 state를 key 경로로 구분해 저장한다."
  type        = string
  default     = "ap-northeast-2"
}
