# 크로스어카운트 팀원용 IAM Role — 2026-10-14, 재희님(926762923779:user/sesac09)
# 접근권한 추가 작업 중 확인한 사실: EKS는 클러스터에 리소스 기반 정책이 없어서,
# 타 AWS 계정의 IAM User를 Access Entry에 직접 등록해도 그 사용자가 로컬에서
# `eks:DescribeCluster`(aws eks update-kubeconfig가 호출하는 control-plane API)를
# cross-account로 호출하는 건 막힌다 — 리소스 소유 계정 안에 Role을 만들고 그 Role을
# 상대 계정이 sts:AssumeRole로 위임받는 구조가 유일한 방법이다.
#
# 창영님 접근권한(aquasentinel-member-changyoung)이 IAM Role인 이유가 바로 이것으로
# 확인됐다(383344224073:user/sesac08를 신뢰) — Terraform에 없던 건 당시 콘솔에서
# 수동 생성했기 때문이고, 설정 자체(신뢰정책 MFA 조건 없음, eks-describe 인라인
# 정책의 Resource "*")를 그대로 조회해서 재희님 몫에 동일하게 맞췄다(2026-10-14
# 팀 결정 — MFA 조건 불필요, changyoung 방식 그대로 따라감). changyoung 쪽 기존
# Role 자체는 이 파일이 손대지 않는다 — 새 Role만 추가한다.
locals {
  cross_account_members = {
    jaehee = {
      external_principal_arn = "arn:aws:iam::926762923779:user/sesac09"
    }
  }
}

resource "aws_iam_role" "cross_account_member" {
  for_each = local.cross_account_members

  name = "${var.project_name}-member-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = each.value.external_principal_arn
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

# changyoung의 기존 인라인 정책과 이름·내용을 동일하게 맞춘다(이름: eks-describe,
# Resource: "*" — 클러스터 ARN으로 좁히는 게 더 엄격하지만, 이번엔 "기존 방식 그대로"
# 요청에 따라 그대로 재현한다).
resource "aws_iam_role_policy" "cross_account_member_eks_describe" {
  for_each = local.cross_account_members

  name = "eks-describe"
  role = aws_iam_role.cross_account_member[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
        ]
        Resource = "*"
      }
    ]
  })
}

# 재희님 요청(2026-10-14)으로 추가한 알람 파이프라인 트랙 B(Route53 헬스체크 →
# CloudWatch → SNS) 읽기전용 권한을, 같은 날 창영님도 동일하게 요청해서 역할
# 이름 목록으로 일반화한다. changyoung 롤(aquasentinel-member-changyoung)은 이
# 레포가 소유권을 갖지 않는 기존 수동 생성 리소스라 aws_iam_role로 가져오지
# (import) 않고 이름 문자열만 참조해서 인라인 정책만 추가한다 — 롤 자체(신뢰정책
# 등)는 건드리지 않으므로 import/삭제 위험이 없다.
# 전부 List/Get/Describe라 리소스 변경 불가 — Resource "*"는 완화가 아니라
# 이 액션들(Route53/CloudWatch/SNS/ACM list·describe류, ec2:DescribeInstances)이
# 리소스 단위 ARN 제약 자체를 지원하지 않아서 불가피하다(eks-describe와 동일 사유).
locals {
  alarm_pipeline_readonly_roles = {
    jaehee     = aws_iam_role.cross_account_member["jaehee"].name
    changyoung = "${var.project_name}-member-changyoung"
  }
}

resource "aws_iam_role_policy" "alarm_pipeline_readonly" {
  for_each = local.alarm_pipeline_readonly_roles

  name = "alarm-pipeline-readonly"
  role = each.value

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AlarmPipelineReadOnly"
        Effect = "Allow"
        Action = [
          "route53:ListHealthChecks",
          "route53:GetHealthCheck",
          "route53:GetHealthCheckStatus",
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "sns:ListTopics",
          "sns:ListSubscriptionsByTopic",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      }
    ]
  })
}
