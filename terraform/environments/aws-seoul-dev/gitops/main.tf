terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = var.project_name
      owner       = var.owner
      environment = var.environment
      managed_by  = "terraform"
      component   = "gitops"
    }
  }
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # aws-observability-storage 등과 동일하게 "${name_prefix}-*" 네이밍을 따른다 —
  # aws-eso 모듈의 IAM 정책이 이 접두사로 접근 범위를 좁혀놓았다.
  gitops_pat_secret_name = "${local.name_prefix}-argocd-gitops-token"
  gitops_repo_url        = "https://github.com/SESAC-2TEAM-FinalProject/aquasentinel-gitops.git"
}

data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/eks/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "aws_eks_cluster_auth" "this" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

data "aws_secretsmanager_secret_version" "gitops_pat" {
  secret_id = local.gitops_pat_secret_name
}

module "eso" {
  source = "../../../modules/aws-eso"

  project_name      = var.project_name
  environment       = var.environment
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url = data.terraform_remote_state.eks.outputs.oidc_provider_url
}

data "terraform_remote_state" "observability_storage" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/observability-storage/terraform.tfstate"
    region = var.tfstate_bucket_region
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
      "eks.amazonaws.com/role-arn" = module.eso.role_arn
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
      "eks.amazonaws.com/role-arn" = data.terraform_remote_state.observability_storage.outputs.loki_role_arn
    }
  }
}

# kube-prometheus-stack의 serviceAccount는 (loki/eso와 달리) 여기서 미리 안 만든다 —
# 이 차트는 prometheus.serviceAccount.create=false면 kubelet ServiceMonitor 인증용
# 토큰 시크릿 렌더링을 차트 레벨에서 막아버린다(helm template 에러, 2026-09-28 확인).
# 그래서 kube_prometheus_stack_app 리소스에서 차트 기본 동작(create=true)에
# annotation만 얹는다.

# ---------------------------------------------------------------------------
# manifests/ 기반 raw 매니페스트 중 리전별로 값이 달라지는 것들 — CNPG 오퍼레이터나
# ESO 컨트롤러가 CR 스펙을 계속 재조정하는 대상이라, "SA만 미리 만들어두고 재사용"
# 방식이 안 통한다(2026-09-28 발견). 그래서 이 Application들 자체를 apps/가 아니라
# 여기서 직접 만든다. 서울은 git 원본이 이미 서울 값이라 patches가 비어 있고,
# 도쿄(environments/aws-tokyo-dr/gitops/main.tf)는 같은 이름의 로컬에 실제 패치를
# 채운다 — README "리전별로 달라지는 값" 참고.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "dns" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/dns/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

locals {
  patched_apps = {
    "cloudnativepg-cluster" = {
      path      = "manifests/cloudnativepg-cluster"
      namespace = "aquasentinel-db"
      patches   = []
    }
    "grafana-secret" = {
      path      = "manifests/grafana-secret"
      namespace = "monitoring"
      patches   = []
    }
    "api-module-db-secret" = {
      path      = "manifests/api-module-db-secret"
      namespace = "api-module"
      patches   = []
    }
    # ACM 인증서 ARN은 서울/도쿄 둘 다 예측 불가능한 값이라, 다른 항목들과
    # 달리 양쪽 다 실제 패치를 채운다(manifests/gateway-api/loadbalancer-config.yaml
    # 주석 참고).
    "gateway-api" = {
      path      = "manifests/gateway-api"
      namespace = "ingress"
      patches = [
        {
          target = { kind = "LoadBalancerConfiguration", name = "aquasentinel-alb-config" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/listenerConfigurations/0/defaultCertificate"
              value = data.terraform_remote_state.dns.outputs.certificate_arn
            }
          ])
        },
      ]
    }
    # 실제 도메인(auth 서브도메인)도 cert ARN과 같은 이유로 패치한다 — 공개
    # 레포에 실제 도메인을 직접 적지 않음. dns 모듈의 failover_hostnames에
    # "auth"가 이미 들어있어야 이 레코드가 실제로 뜬다(environments/*/dns).
    "keycloak" = {
      path      = "manifests/keycloak"
      namespace = "keycloak"
      patches = [
        {
          target = { kind = "Keycloak", name = "aquasentinel-keycloak" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/hostname/hostname"
              value = "auth.${data.terraform_remote_state.dns.outputs.domain_name}"
            }
          ])
        },
        {
          target = { kind = "HTTPRoute", name = "keycloak" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/hostnames/0"
              value = "auth.${data.terraform_remote_state.dns.outputs.domain_name}"
            }
          ])
        },
        # 대시보드 클라이언트의 redirect/webOrigin/appUrl — 대시보드는 apex
        # 레코드(안건④)를 쓰기로 이미 정해져 있어 auth 서브도메인과 같은 도메인
        # 값을 그대로 재사용한다(대시보드 HTTPRoute 자체는 네임스페이스 미정으로
        # 보류 중이지만, Keycloak 클라이언트 등록은 선행해도 무방).
        {
          target = { kind = "KeycloakOIDCClient", name = "aquasentinel-dashboard" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/client/redirectUris/0"
              value = "https://${data.terraform_remote_state.dns.outputs.domain_name}/auth/callback"
            },
            {
              op    = "replace"
              path  = "/spec/client/webOrigins/0"
              value = "https://${data.terraform_remote_state.dns.outputs.domain_name}"
            },
            {
              op    = "replace"
              path  = "/spec/client/appUrl"
              value = "https://${data.terraform_remote_state.dns.outputs.domain_name}"
            }
          ])
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "patched_app" {
  for_each = local.patched_apps

  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = each.key
      namespace = "argocd"
    }
    spec = {
      project = "default"

      source = merge(
        {
          repoURL        = local.gitops_repo_url
          targetRevision = "main"
          path           = each.value.path
        },
        length(each.value.patches) > 0 ? {
          kustomize = {
            patches = each.value.patches
          }
        } : {}
      )

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = each.value.namespace
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
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
        bucket   = data.terraform_remote_state.observability_storage.outputs.bucket_name
        endpoint = "s3.${var.region}.amazonaws.com"
        region   = var.region
      }
      prefix = data.terraform_remote_state.observability_storage.outputs.thanos_prefix
    })
  }
}

# Loki는 원격 Helm 차트라(manifests/ 경로가 아님) 위 patched_app의 Kustomize
# 패치가 적용될 git 파일이 없다 — 그래서 apps/에도 두지 않고, Application 전체
# (Helm values 포함)를 여기서 리전별로 다시 구성한다. serviceAccount는 위에서
# 미리 만든 것을 재사용(annotation 불필요), 버킷 이름과 리전만 리전별로 다르다.
locals {
  loki_values = <<-EOT
    deploymentMode: SingleBinary

    loki:
      auth_enabled: false
      commonConfig:
        replication_factor: 1
      storage:
        type: s3
        bucketNames:
          chunks: ${data.terraform_remote_state.observability_storage.outputs.loki_bucket_name}
          ruler: ${data.terraform_remote_state.observability_storage.outputs.loki_bucket_name}
          admin: ${data.terraform_remote_state.observability_storage.outputs.loki_bucket_name}
        s3:
          region: ${var.region}
      schemaConfig:
        configs:
          - from: "2024-01-01"
            store: tsdb
            object_store: s3
            schema: v13
            index:
              prefix: index_
              period: 24h

    singleBinary:
      replicas: 1
      persistence:
        size: 10Gi
        storageClass: gp2

    serviceAccount:
      create: false
      name: loki

    gateway:
      enabled: false

    read:
      replicas: 0
    write:
      replicas: 0
    backend:
      replicas: 0

    chunksCache:
      enabled: false
    resultsCache:
      enabled: false
  EOT
}

resource "kubernetes_manifest" "loki_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "loki"
      namespace = "argocd"
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://grafana.github.io/helm-charts"
        chart          = "loki"
        targetRevision = "7.3.0"
        helm = {
          values = local.loki_values
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "monitoring"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd, kubernetes_service_account_v1.loki]
}

# kube-prometheus-stack — Loki와 같은 이유로 Application 전체를 Terraform이 소유한다
# (위 주석 참고). role-arn만 리전별로 다르고 나머지는 apps/에 있던 원본 그대로.
locals {
  kube_prometheus_stack_values = <<-EOT
    grafana:
      enabled: false

    prometheus:
      serviceAccount:
        annotations:
          eks.amazonaws.com/role-arn: "${data.terraform_remote_state.observability_storage.outputs.thanos_role_arn}"

      prometheusSpec:
        retention: 2d

        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: gp2
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 20Gi

        thanos:
          objectStorageConfig:
            existingSecret:
              name: thanos-objstore-config
              key: object-store.yaml
  EOT
}

resource "kubernetes_manifest" "kube_prometheus_stack_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "kube-prometheus-stack"
      namespace = "argocd"
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://prometheus-community.github.io/helm-charts"
        chart          = "kube-prometheus-stack"
        targetRevision = "91.5.0"
        helm = {
          values = local.kube_prometheus_stack_values
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "monitoring"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd, kubernetes_secret_v1.thanos_objstore_config]
}

# AWS Load Balancer Controller — role-arn/clusterName/vpcId가 리전마다 달라
# kube-prometheus-stack과 같은 이유로 Application 전체를 Terraform이 소유한다.
# IAM 역할 자체는 modules/aws-ingress(environments/*/ingress)가 이미 만들어둠 —
# 여기선 그 역할을 Helm values에 annotation으로 꽂기만 한다.
#
# controllerConfig.featureGates.ALBGatewayAPI: true — 안건 3(외부 진입점,
# 2026-09-30, 잠정 Gateway API) 확정 방향에 대비해 켜둔다. 차트 버전 3.5.0
# (컨트롤러 v3.5.0)부터 지원 확인(공식 values.yaml 기준). 단, Gateway API
# CRD(GatewayClass/Gateway/HTTPRoute) 자체는 이 차트가 설치하지 않으므로
# 별도 설치가 필요하다 — 다음 작업(서울 Gateway API 진입점 구축)에서 처리.
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

data "terraform_remote_state" "ingress" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "${var.environment}/${var.region}/ingress/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

locals {
  aws_load_balancer_controller_values = <<-EOT
    clusterName: ${data.terraform_remote_state.eks.outputs.cluster_name}
    region: ${var.region}
    vpcId: ${data.terraform_remote_state.network.outputs.vpc_id}

    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: "${data.terraform_remote_state.ingress.outputs.role_arn}"

    controllerConfig:
      featureGates:
        ALBGatewayAPI: true
  EOT
}

resource "kubernetes_manifest" "aws_load_balancer_controller_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "aws-load-balancer-controller"
      namespace = "argocd"
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://aws.github.io/eks-charts"
        chart          = "aws-load-balancer-controller"
        targetRevision = "3.5.0"
        helm = {
          values = local.aws_load_balancer_controller_values
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "kube-system"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# aquasentinel-gitops의 bootstrap/root-app.yaml과 내용이 동일해야 한다(수동 동기화).
resource "kubernetes_manifest" "root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"

      source = {
        repoURL        = local.gitops_repo_url
        targetRevision = "main"
        path           = "apps"
        directory = {
          recurse = true
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
}
