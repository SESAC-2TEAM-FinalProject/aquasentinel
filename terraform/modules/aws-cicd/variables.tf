variable "project_name" {
  type = string
}

variable "github_repository" {
  description = "\"org/repo\" 형식. trust policy의 sub 조건에 그대로 들어간다."
  type        = string
}

variable "github_branch" {
  description = "이 브랜치로의 push만 apply 권한을 갖는다."
  type        = string
  default     = "main"
}

variable "tags" {
  type    = map(string)
  default = {}
}
