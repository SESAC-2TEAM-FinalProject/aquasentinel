# ArgoCD Application을 Terraform이 직접 생성하는 "두 번째 GitOps 엔진" 역할 —
# 서울과 동일한 구조적 이유(seoul/rebuild/3-gitops/applications.tf 주석 참고).
# 서울은 git 원본이 이미 서울 값이라 patches가 비어 있는 항목이 많지만, 도쿄는
# 실제 리전별 값(역할 ARN·도메인·시크릿 이름·Replica Cluster 설정)을 여기서
# 채워 패치한다.

locals {
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
              value = data.terraform_remote_state.cluster.outputs.cloudnativepg_role_arn
            }
          ])
        },
        {
          target = { kind = "ObjectStore", name = "aquasentinel-backup-store" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/configuration/destinationPath"
              value = "s3://${data.terraform_remote_state.persistent.outputs.bucket_names["observability"]}/${data.terraform_remote_state.persistent.outputs.cloudnativepg_prefix}"
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
        # Secrets Manager는 리전 서비스라 도쿄 전용 시크릿 이름으로 가리켜야
        # 한다(아래 grafana-secret/api-module-db-secret과 같은 이유) — 다만
        # 실제로 쓰이는 건 도쿄가 Replica Cluster라 평소엔 읽기전용임. Primary로
        # 승격된 뒤에야 의미가 생긴다.
        {
          target = { kind = "ExternalSecret", name = "keycloak-db-password" }
          patch = jsonencode([
            { op = "replace", path = "/spec/data/0/remoteRef/key", value = "${local.name_prefix}-keycloak-db-password" }
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
            for i, field in ["username", "password", "host", "port", "dbname"] : {
              op    = "replace"
              path  = "/spec/data/${i}/match/remoteRef/remoteKey"
              value = "${local.name_prefix}-api-module-database-${field}"
            }
          ])
        },
        {
          target = { kind = "ExternalSecret", name = "api-module-database" }
          patch = jsonencode([
            for i, field in ["username", "password", "host", "port", "dbname"] : {
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
              value = data.terraform_remote_state.persistent.outputs.certificate_arn
            }
          ])
        },
      ]
    }
    # 실제 도메인은 cert ARN과 같은 이유로 패치(서울 쪽 주석 참고). DB 비밀번호
    # remoteRef.key도 도쿄 전용 Secrets Manager 이름으로 바꾼다.
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
              value = "auth.${data.terraform_remote_state.persistent.outputs.domain_name}"
            }
          ])
        },
        {
          target = { kind = "HTTPRoute", name = "keycloak" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/hostnames/0"
              value = "auth.${data.terraform_remote_state.persistent.outputs.domain_name}"
            }
          ])
        },
        # 대시보드 클라이언트의 redirect/webOrigin/appUrl — 서울 쪽과 같은
        # 이유(apex가 대시보드 주소)로 같은 패치를 넣는다.
        {
          target = { kind = "KeycloakOIDCClient", name = "aquasentinel-dashboard" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/client/redirectUris/0"
              value = "https://${data.terraform_remote_state.persistent.outputs.domain_name}/auth/callback"
            },
            {
              op    = "replace"
              path  = "/spec/client/webOrigins/0"
              value = "https://${data.terraform_remote_state.persistent.outputs.domain_name}"
            },
            {
              op    = "replace"
              path  = "/spec/client/appUrl"
              value = "https://${data.terraform_remote_state.persistent.outputs.domain_name}"
            }
          ])
        },
        {
          target = { kind = "ExternalSecret", name = "keycloak-db-credentials" }
          patch = jsonencode([
            { op = "replace", path = "/spec/data/0/remoteRef/key", value = "${local.name_prefix}-keycloak-db-password" }
          ])
        },
      ]
    }
    # 대시보드(웹 서비스) HTTPRoute — keycloak과 같은 이유로 실제 도메인을
    # 직접 적지 않고 패치로 주입한다.
    "web" = {
      path      = "manifests/web"
      namespace = "web"
      patches = [
        {
          target = { kind = "HTTPRoute", name = "aquasentinel-web" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/hostnames/0"
              value = data.terraform_remote_state.persistent.outputs.domain_name
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

# Loki — 원격 Helm 차트라 Kustomize 패치 대상이 없어, Application 전체를 여기서
# 리전별로 다시 구성한다(서울과 동일 이유). 값만 도쿄 것.
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
          chunks: ${data.terraform_remote_state.persistent.outputs.bucket_names["loki"]}
          ruler: ${data.terraform_remote_state.persistent.outputs.bucket_names["loki"]}
          admin: ${data.terraform_remote_state.persistent.outputs.bucket_names["loki"]}
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

# kube-prometheus-stack — Loki와 같은 이유로 Application 전체를 Terraform이
# 소유한다. role-arn만 리전별로 다르고 나머지는 서울과 동일.
locals {
  kube_prometheus_stack_values = <<-EOT
    grafana:
      enabled: false

    prometheus:
      serviceAccount:
        annotations:
          eks.amazonaws.com/role-arn: "${data.terraform_remote_state.cluster.outputs.thanos_role_arn}"

      prometheusSpec:
        retention: 2d

        podMonitorSelectorNilUsesHelmValues: false
        serviceMonitorSelectorNilUsesHelmValues: false
        ruleSelectorNilUsesHelmValues: false

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
locals {
  aws_load_balancer_controller_values = <<-EOT
    clusterName: ${data.terraform_remote_state.cluster.outputs.cluster_name}
    region: ${var.region}
    vpcId: ${data.terraform_remote_state.network.outputs.vpc_id}

    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: "${data.terraform_remote_state.cluster.outputs.lbc_role_arn}"

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

# LBC + Gateway API CRD 부트스트랩 경쟁 조건(서울과 동일 구조적 이슈,
# seoul/rebuild/3-gitops/applications.tf 주석 참고) — Terraform이 자동 복구한다.
resource "time_sleep" "wait_for_lbc_bootstrap" {
  depends_on      = [kubernetes_manifest.aws_load_balancer_controller_app]
  create_duration = "60s"
}

resource "null_resource" "restart_lbc_for_gateway_api" {
  depends_on = [time_sleep.wait_for_lbc_bootstrap]

  provisioner "local-exec" {
    command = <<-EOT
      CA_FILE=$(mktemp)
      echo "${data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data}" | base64 -d > "$CA_FILE"
      kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} -n kube-system rollout restart deployment aws-load-balancer-controller
      rm -f "$CA_FILE"
    EOT
  }
}

# root Application은 Terraform이 아니라 aquasentinel-gitops의
# bootstrap/root-app.yaml을 단일 소스로 삼는다(서울과 동일, 2026-10-09
# 변경 — 이 리소스와 그 YAML 파일 두 곳을 손으로 동기화해야 했던 걸
# 없앰). ArgoCD Helm 설치 후 최초 1회 `kubectl apply -f bootstrap/root-app.yaml`로
# 수동 부트스트랩하면, 이후엔 App-of-Apps 패턴대로 ArgoCD 자체가 apps/ 아래
# 추가되는 모든 Application을 알아서 동기화한다.
