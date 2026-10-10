# IRSA Role 생성 공통 모듈 — Terraform이 만드는 워크로드별 IAM Role이 전부
# 같은 모양(OIDC federated trust policy + 정책 attach)이라 공통화했다
# (경로 구조 개편안 D5, 2026-10-10 — 커뮤니티 서브모듈 채택 확정. Phase 0에서
# aws-eso/aws-ingress/aws-cicd/GitLab Runner IRSA 4곳에 먼저 검증함).
#
# 이 모듈은 Role과 트러스트 정책만 만든다 — 실제 권한(IAM Policy 내용)은
# 호출하는 쪽(2-cluster 컴포넌트)이 만들어서 policy_arns로 넘긴다. 워크로드마다
# 권한 범위가 다 다르고(ESO는 Secrets Manager, LBC는 ELB/EC2, thanos/loki/cnpg/
# collector/processor는 S3) 그 정책 자체를 공통화할 이유는 없기 때문이다.
module "this" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = var.role_name

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = var.namespace_service_accounts
    }
  }

  role_policy_arns = var.policy_arns

  tags = var.tags
}
