# Terraform이 직접 만드는 K8s/Helm 부트스트랩 리소스 — ArgoCD 자체 설치,
# ArgoCD가 쓸 레포 자격증명, 그리고 ESO/Loki/Thanos/api-module/GitLab
# Runner용 ServiceAccount(2-cluster가 만든 IRSA role-arn을 annotation으로
# 심어둠 — role 생성 자체는 더 이상 이 컴포넌트가 하지 않는다, D2).
# ArgoCD Application 생성(두 번째 GitOps 엔진 역할)은 applications.tf 참고.

data "aws_secretsmanager_secret_version" "gitops_pat" {
  secret_id = local.gitops_pat_secret_name
}

# api-module의 collector·processor ServiceAccount — loki/eso와 같은 이유로
# Terraform이 미리 만들어 IRSA role-arn을 심어둔다. api-module 네임스페이스
# 자체는 patched_app "api-module-db-secret"이 CreateNamespace=true로 먼저
# 만들므로 여기서 kubernetes_namespace_v1은 만들지 않는다(이중 소유 충돌 방지).
# 이름은 2-cluster의 기본값(collector_service_account_name="collector",
# processor_service_account_name="processor")과 반드시 일치해야 IRSA
# 신뢰조건(sub)이 맞는다 — reprocess Job과 completeness-check Deployment도
# processor 이미지를 쓰므로 이 processor SA를 그대로 공유한다.
resource "kubernetes_service_account_v1" "api_module_collector" {
  metadata {
    name      = "collector"
    namespace = "api-module"
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.collector_role_arn
    }
  }
}

resource "kubernetes_service_account_v1" "api_module_processor" {
  metadata {
    name      = "processor"
    namespace = "api-module"
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.processor_role_arn
    }
  }
}

# ---------------------------------------------------------------------------
# Terraform이 직접 설치하는 유일한 Helm 차트. 이후 모든 워크로드(ESO 포함)는
# 이 Argo CD가 aquasentinel-gitops 레포를 보고 스스로 동기화한다.
# ---------------------------------------------------------------------------
# applications.tf의 kubernetes_manifest(argoproj.io/Application)가 이 차트가
# 설치하는 CRD를 쓴다 — plan이 전체 그래프를 미리 스키마 검증하므로 같은 apply
# 안에서는 depends_on만으로 "CRD가 아직 없음" 에러를 못 피한다. CI가
# `terraform apply -target=helm_release.argocd`를 먼저 실행해 CRD부터
# 등록시킨다(.gitlab-ci.yml의 apply:seoul 참고, 2026-10-10 첫 실제 적용에서
# 발견).
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.2"
  namespace        = "argocd"
  create_namespace = true
}

# Argo CD가 private 레포를 clone할 때 쓰는 자격증명.
# ESO를 거치지 않고 Terraform이 직접 심는다 — ESO 자신도 이 레포의 Application으로
# 배포되므로, ESO를 거치면 "ESO가 뜨기 전엔 ESO를 못 가져온다"는 순환 의존이 생긴다.
resource "kubernetes_secret_v1" "gitops_repo_creds" {
  metadata {
    name      = "aquasentinel-gitops-repo-creds"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    url      = local.gitops_repo_url
    username = "x-access-token"
    password = data.aws_secretsmanager_secret_version.gitops_pat.secret_string
  }

  type = "Opaque"

  depends_on = [helm_release.argocd]
}

# ---------------------------------------------------------------------------
# ESO/Loki/Thanos(Prometheus)의 ServiceAccount를 Terraform이 미리 만들어 IRSA
# role-arn을 심어둔다 — GitOps 쪽(apps/*)은 serviceAccount.create=false로 이
# 이름을 그대로 쓴다. role-arn은 리전마다 다른데, 이 값을 GitOps 매니페스트에
# 직접 적으면 그 파일 자체가 리전별로 갈라져야 한다(2026-09-28 도쿄 재현성 테스트에서
# 서울 ARN이 박혀 있던 걸 발견 — aquasentinel-gitops README "리전별로 달라지는 값"
# 참고). Terraform은 이미 리전별로 정확한 값을 알고 있으므로 여기서 붙인다.
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "kubernetes_service_account_v1" "external_secrets" {
  metadata {
    name      = "external-secrets"
    namespace = kubernetes_namespace_v1.external_secrets.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.eso_role_arn
    }
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "kubernetes_service_account_v1" "loki" {
  metadata {
    name      = "loki"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.loki_role_arn
    }
  }
}

# Thanos(Prometheus 사이드카)의 오브젝트 스토리지 설정 — 버킷/엔드포인트/리전을
# apps/kube-prometheus-stack의 Helm values에 직접 적지 않고, 이 시크릿을
# existingSecret으로 참조하게 한다(차트가 objectStorageConfig.existingSecret을
# 지원함 — .secret과 달리 리전별 값을 Helm values 밖에 둘 수 있다).
resource "kubernetes_secret_v1" "thanos_objstore_config" {
  metadata {
    name      = "thanos-objstore-config"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    "object-store.yaml" = yamlencode({
      type = "S3"
      config = {
        bucket   = data.terraform_remote_state.persistent.outputs.bucket_names["observability"]
        endpoint = "s3.${var.region}.amazonaws.com"
        region   = var.region
      }
      prefix = data.terraform_remote_state.persistent.outputs.thanos_prefix
    })
  }
}

# ---------------------------------------------------------------------------
# GitLab Runner(EKS 자체 러너, api-module/web/gitops 레포 CI용) 잡 파드
# ServiceAccount — IRSA role 생성 자체는 2-cluster(D2)에서 한다. 러너
# 매니저 파드 자신은 이 SA를 쓰지 않는다(차트 기본 SA로 충분 — 잡 파드를
# 띄우는 RBAC만 있으면 됨). 이 SA는 실제 빌드를 실행하는 잡 파드 전용이고,
# .gitlab-ci.yml 쪽에서 KUBERNETES_SERVICE_ACCOUNT_OVERWRITE로 지정하거나
# Runner 설정(config.toml)의 기본 service_account로 건다. 도쿄는 CI가
# 돌지 않으므로 이 러너 자체가 필요 없다(서울 전용).
# ---------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "gitlab_runner" {
  metadata {
    name = "gitlab-runner"
  }
}

resource "kubernetes_service_account_v1" "gitlab_runner_build" {
  metadata {
    name      = "gitlab-runner-build"
    namespace = kubernetes_namespace_v1.gitlab_runner.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.gitlab_runner_build_role_arn
    }
  }
}
