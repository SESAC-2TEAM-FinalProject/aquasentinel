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
# 방식이 안 통한다(2026-09-28 발견). 서울(environments/aws-seoul-dev/gitops/main.tf)의
# 동일 로컬과 다르게, 여기서는 실제 patches를 채워 도쿄 값으로 인라인 오버라이드한다 —
# git의 manifests/* 원본 자체는 서울 값 그대로 둔 채, 이 Application의
# source.kustomize.patches가 apply 시점에만 덮어쓴다. README "리전별로 달라지는 값" 참고.
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
  api_module_db_fields = ["username", "password", "host", "port", "dbname"]

  patched_apps = {
    "cloudnativepg-cluster" = {
      path      = "manifests/cloudnativepg-cluster"
      namespace = "aquasentinel-db"
      patches = [
        {
          target = { kind = "Cluster", name = "aquasentinel-pg" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/serviceAccountTemplate/metadata/annotations/eks.amazonaws.com~1role-arn"
              value = data.terraform_remote_state.observability_storage.outputs.cloudnativepg_backup_role_arn
            }
          ])
        },
        {
          target = { kind = "ObjectStore", name = "aquasentinel-backup-store" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/configuration/destinationPath"
              value = "s3://${data.terraform_remote_state.observability_storage.outputs.bucket_name}/${data.terraform_remote_state.observability_storage.outputs.cloudnativepg_prefix}"
            }
          ])
        },
        # 도쿄만 Replica Cluster(방식 B, 2026-09-28 결정)로 만든다 — 서울의
        # cluster.yaml 원본은 그대로 두고 여기서 op:add로 세 블록을 주입한다.
        # externalClusters[].plugin.parameters는 plugin-barman-cloud 공식
        # 예제(cluster-replica-log-shipping.yaml) 그대로: barmanObjectName은
        # object-store-seoul-source.yaml의 ObjectStore 이름, serverName은
        # 서울 Cluster의 metadata.name(백업이 그 이름으로 버킷에 쌓여있음).
        {
          target = { kind = "Cluster", name = "aquasentinel-pg" }
          patch = jsonencode([
            {
              op    = "add"
              path  = "/spec/bootstrap"
              value = { recovery = { source = "seoul" } }
            },
            {
              op    = "add"
              path  = "/spec/replica"
              value = { enabled = true, source = "seoul" }
            },
            {
              op   = "add"
              path = "/spec/externalClusters"
              value = [
                {
                  name = "seoul"
                  plugin = {
                    name = "barman-cloud.cloudnative-pg.io"
                    parameters = {
                      barmanObjectName = "aquasentinel-pg-seoul-source"
                      serverName       = "aquasentinel-pg"
                    }
                  }
                }
              ]
            }
          ])
        },
      ]
    }
    "grafana-secret" = {
      path      = "manifests/grafana-secret"
      namespace = "monitoring"
      patches = [
        {
          target = { kind = "ClusterSecretStore", name = "aws-secretsmanager" }
          patch = jsonencode([
            { op = "replace", path = "/spec/provider/aws/region", value = var.region }
          ])
        },
        {
          target = { kind = "ExternalSecret", name = "grafana-admin-credentials" }
          patch = jsonencode([
            { op = "replace", path = "/spec/data/0/remoteRef/key", value = "${local.name_prefix}-grafana-admin-password" }
          ])
        },
      ]
    }
    "api-module-db-secret" = {
      path      = "manifests/api-module-db-secret"
      namespace = "api-module"
      patches = [
        {
          target = { kind = "PushSecret", name = "api-module-database" }
          patch = jsonencode([
            for i, field in local.api_module_db_fields : {
              op    = "replace"
              path  = "/spec/data/${i}/match/remoteRef/remoteKey"
              value = "${local.name_prefix}-api-module-database-${field}"
            }
          ])
        },
        {
          target = { kind = "ExternalSecret", name = "api-module-database" }
          patch = jsonencode([
            for i, field in local.api_module_db_fields : {
              op    = "replace"
              path  = "/spec/data/${i}/remoteRef/key"
              value = "${local.name_prefix}-api-module-database-${field}"
            }
          ])
        },
      ]
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

# Thanos(Prometheus 사이드카)의 오브젝트 스토리지 설정 — 서울과 동일한 이유
# (environments/aws-seoul-dev/gitops/main.tf 주석 참고), 값만 도쿄 것.
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

# Loki — 서울과 동일한 이유(environments/aws-seoul-dev/gitops/main.tf 주석 참고),
# 값만 도쿄 것.
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

# kube-prometheus-stack — 서울과 동일한 이유(environments/aws-seoul-dev/gitops/main.tf
# 주석 참고), role-arn 값만 도쿄 것.
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

# AWS Load Balancer Controller — 서울과 동일한 이유(environments/aws-seoul-dev/
# gitops/main.tf 주석 참고), 값만 도쿄 것.
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
