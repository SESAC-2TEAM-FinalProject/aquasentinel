locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ---------------------------------------------------------------------------
# RDS MySQL
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-rds"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rds-subnet-group"
  })
}

# 계획서 11.7절: rds-sg 인바운드는 node-sg의 3306만 허용, 아웃바운드는 없음.
# egress 블록을 아예 선언하지 않으면 Terraform이 AWS 기본 all-outbound 규칙을
# 제거해 "아웃바운드 없음"이 그대로 구현된다.
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Allow MySQL(3306) from EKS nodes only" # AWS SG description은 ASCII만 허용
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from EKS nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.allowed_security_group_id]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-rds-sg"
  })
}

resource "random_password" "rds" {
  length      = 24
  special     = false # RDS 접속 문자열에 특수문자가 섞이면 애플리케이션 측 이스케이프 문제가 잦아 영문+숫자로 제한
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "aws_secretsmanager_secret" "rds" {
  name = "${local.name_prefix}-rds-credentials"
  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id

  secret_string = jsonencode({
    username = var.rds_username
    password = random_password.rds.result
  })
}

resource "aws_db_instance" "this" {
  identifier     = "${local.name_prefix}-mysql"
  engine         = "mysql"
  engine_version = var.rds_engine_version

  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true # AWS 관리형 키(aws/rds) 사용 — 계획서 결정: 자체 CMK 불필요

  db_name  = var.rds_database_name
  username = var.rds_username
  password = random_password.rds.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az                   = var.rds_multi_az
  backup_retention_period    = var.rds_backup_retention_days
  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection       = var.rds_deletion_protection
  skip_final_snapshot       = var.rds_skip_final_snapshot
  final_snapshot_identifier = var.rds_skip_final_snapshot ? null : "${local.name_prefix}-mysql-final"

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-mysql"
  })
}

# ---------------------------------------------------------------------------
# ElastiCache Redis — 단일 노드. 4.7절 구독 조회 캐시, 3.2절 상태조회 캐시 용도.
# HA(복제) 실험 대상이 아니므로 replication group이 아니라 단순 cluster로 구성.
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = var.private_data_subnet_ids

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis-subnet-group"
  })
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "Allow Redis(6379) from EKS nodes only" # AWS SG description은 ASCII만 허용
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.allowed_security_group_id]
  }

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis-sg"
  })
}

resource "aws_elasticache_cluster" "this" {
  cluster_id      = "${local.name_prefix}-redis"
  engine          = "redis"
  engine_version  = var.redis_engine_version
  node_type       = var.redis_node_type
  num_cache_nodes = 1
  port            = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  tags = merge(var.tags, {
    Name = "${local.name_prefix}-redis"
  })
}
