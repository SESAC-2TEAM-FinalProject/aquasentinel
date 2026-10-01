# 서울 repository_urls의 "ecr.{서울 리전}." 부분만 도쿄 리전으로 치환한다 —
# 계정 ID·레포 이름은 복제본이 원본과 동일하므로 바뀌지 않는다.
output "repository_urls" {
  value = {
    for name, url in data.terraform_remote_state.seoul_registry.outputs.repository_urls :
    name => replace(url, ".ecr.${var.source_region}.", ".ecr.${var.region}.")
  }
}
