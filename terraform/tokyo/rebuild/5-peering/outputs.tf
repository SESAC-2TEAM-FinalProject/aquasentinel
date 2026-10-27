output "peering_connection_id" {
  description = "VPC 피어링 연결 ID. 훈련 중 라우트를 손으로 손볼 때 쓴다."
  value       = aws_vpc_peering_connection.to_seoul.id
}

output "peering_status" {
  description = "수락 상태. active 여야 트래픽이 흐른다."
  value       = aws_vpc_peering_connection_accepter.seoul.accept_status
}

output "tokyo_route_table_ids" {
  description = "도쿄 private 라우트 테이블. 🔴 2부 「끊기」 대상이다."
  value       = data.aws_route_tables.tokyo_private.ids
}

output "seoul_route_table_ids" {
  description = "서울 private 라우트 테이블."
  value       = data.aws_route_tables.seoul_private.ids
}

output "tokyo_route_enabled" {
  description = "도쿄 → 서울 경로가 살아 있는가. false 면 스트리밍이 끊긴 상태다."
  value       = var.enable_tokyo_route
}
