# Terraform이 직접 만드는 K8s/Helm 부트스트랩 리소스 — 서울과 동일 패턴
# (bootstrap.tf 주석 참고). GitLab Runner SA는 없다 — 도쿄는 CI가 돌지 않는다.

data "aws_secretsmanager_secret_version" "gitops_pat" {
  secret_id = local.gitops_pat_secret_name
}

# api-module 네임스페이스는 patched_app "api-module-db-secret"이 ArgoCD
# Application으로 CreateNamespace=true를 거는데, 그 동기화는 비동기라
# depends_on만으로는 존재를 보장 못 한다(서울과 동일 이유, 서울
# bootstrap.tf 주석 참고 — 2026-10-10 발견).
resource "null_resource" "wait_for_api_module_namespace" {
  depends_on = [kubernetes_manifest.patched_app["api-module-db-secret"]]

  provisioner "local-exec" {
    command = <<-EOT
      CA_FILE=$(mktemp)
      echo "${data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data}" | base64 -d > "$CA_FILE"
      for i in $(seq 1 60); do
        kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} get namespace api-module >/dev/null 2>&1 && break
        sleep 5
      done
      kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} get namespace api-module
      rm -f "$CA_FILE"
    EOT
  }
}

# api-module의 collector·processor ServiceAccount — 평소엔 도쿄에서 안 돌지만
# 페일오버 시 바로 쓸 수 있도록 서울과 동일하게 미리 만들어둔다.
resource "kubernetes_service_account_v1" "api_module_collector" {
  depends_on = [null_resource.wait_for_api_module_namespace]

  metadata {
    name      = "collector"
    namespace = "api-module"
    annotations = {
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.cluster.outputs.collector_role_arn
    }
  }
}

resource "kubernetes_service_account_v1" "api_module_processor" {
  depends_on = [null_resource.wait_for_api_module_namespace]

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
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.9.2"
  namespace        = "argocd"
  create_namespace = true
}

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
# role-arn을 심어둔다(서울과 동일 이유, bootstrap.tf 주석 참고).
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

# Thanos(Prometheus 사이드카)의 오브젝트 스토리지 설정 — 서울과 동일 이유,
# 값만 도쿄 것(persistent remote_state에서 가져옴).
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
