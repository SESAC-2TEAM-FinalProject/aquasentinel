# ArgoCD Application을 Terraform이 직접 생성하는 "두 번째 GitOps 엔진" 역할.
# 원래 GitOps 취지는 Git 저장소(apps/)가 뭘 배포할지 결정하고 ArgoCD가 그걸
# 보고 알아서 동기화하는 건데, 여기 있는 Application들은 리전별로 값이 달라서
# (S3 버킷/IAM role-arn/도메인 등) Terraform이 계산한 값을 바로 꽂아야 하다
# 보니 이렇게 따로 관리하게 됐다. 일부(api-module 워크로드 7종, 리전값이
# 필요 없었던 케이스)는 이미 apps/ 레포로 옮겼다(Option 3 Step 1, 2026-10-09).
# 나머지는 전부 AWS가 런타임에 생성하는 값(ACM ARN/S3 버킷명/IAM role-arn
# 등)이 필요해 구조적으로 Git에 못 넣는다 — 상세 분석은
# AquaSentinel_테라폼_구조_개선_방향 문서 참고.

# ---------------------------------------------------------------------------
# manifests/ 기반 raw 매니페스트 중 리전별로 값이 달라지는 것들 — CNPG 오퍼레이터나
# ESO 컨트롤러가 CR 스펙을 계속 재조정하는 대상이라, "SA만 미리 만들어두고 재사용"
# 방식이 안 통한다(2026-09-28 발견). 그래서 이 Application들 자체를 apps/가 아니라
# 여기서 직접 만든다. 서울은 git 원본이 이미 서울 값이라 patches가 비어 있고,
# 도쿄(tokyo/rebuild/3-gitops/applications.tf)는 같은 이름의 로컬에 실제
# 패치를 채운다 — README "리전별로 달라지는 값" 참고.
# ---------------------------------------------------------------------------

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
              value = data.terraform_remote_state.persistent.outputs.certificate_arn
            }
          ])
        },
      ]
    }
    # 실제 도메인(auth 서브도메인)도 cert ARN과 같은 이유로 패치한다 — 공개
    # 레포에 실제 도메인을 직접 적지 않음(팀 결정 2026-10-10, 경로 구조 개편안
    # 회신 문서 — 계속 Terraform이 주입). dns 모듈의 failover_hostnames에
    # "auth"가 이미 들어있어야 이 레코드가 실제로 뜬다(4-edge 컴포넌트).
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
      ]
    }
    # 대시보드(웹 서비스) HTTPRoute — keycloak과 같은 이유로 실제 도메인을
    # 직접 적지 않고 패치로 주입한다. apex 레코드(안건④)를 쓰기로 이미
    # 정해져 있어 서브도메인 접두사 없이 domain_name 그대로 쓴다(auth와
    # 달리 "https://" 접두사도 없음 — HTTPRoute hostnames는 호스트 이름만).
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

# kube-prometheus-stack의 serviceAccount는 (loki/eso와 달리) 여기서 미리 안 만든다 —
# 이 차트는 prometheus.serviceAccount.create=false면 kubelet ServiceMonitor 인증용
# 토큰 시크릿 렌더링을 차트 레벨에서 막아버린다(helm template 에러, 2026-09-28 확인).
# 그래서 kube_prometheus_stack_app 리소스에서 차트 기본 동작(create=true)에
# annotation만 얹는다.

# kube-prometheus-stack — Loki와 같은 이유로 Application 전체를 Terraform이 소유한다
# (위 주석 참고). role-arn만 리전별로 다르고 나머지는 apps/에 있던 원본 그대로.
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

        # 기본값(true)이면 release: kube-prometheus-stack 라벨이 있는
        # PodMonitor/ServiceMonitor/PrometheusRule만 인식한다 — NATS 차트가
        # 만드는 PodMonitor(promExporter.podMonitor.enabled=true)에 이 라벨이
        # 없어 실제로는 수집이 안 되고 있었음(2026-10-07 발견). 클러스터가
        # 하나뿐이라 전체 매칭으로 바꾼다.
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
# IAM 역할 자체는 2-cluster가 이미 만들어둠 — 여기선 그 역할을 Helm values에
# annotation으로 꽂기만 한다.
#
# controllerConfig.featureGates.ALBGatewayAPI: true — 외부 진입점(잠정 Gateway
# API) 확정 방향에 대비해 켜둔다. 차트 버전 3.5.0(컨트롤러 v3.5.0)부터 지원
# 확인(공식 values.yaml 기준). 단, Gateway API CRD(GatewayClass/Gateway/
# HTTPRoute) 자체는 이 차트가 설치하지 않으므로 별도 설치가 필요하다.
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

# LBC + Gateway API CRD 부트스트랩 경쟁 조건(2026-10-02 서울 재기동 때 재현
# 확인) — LBC는 프로세스 시작 시 딱 한 번만 Gateway API CRD 존재 여부를
# 확인하고 이후 재확인하지 않는다. Argo CD가 aws-load-balancer-controller와
# gateway-api-crds를 동시에 설치하다 보니, LBC가 체크하는 시점에 CRD가 아직
# 없으면 그 프로세스는 평생 "Gateway API 미지원" 상태로 굳어버린다.
#
# Argo CD sync-wave로 순서를 강제하려 했으나, 두 Application이 같은 부모
# (App-of-Apps) 아래 있지 않아 sync-wave가 적용되지 않는다는 걸 확인했다 —
# 그래서 Terraform에 자동 복구 로직을 추가한다(사람이 수동으로
# kubectl rollout restart를 안 쳐도 되게).
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
# bootstrap/root-app.yaml을 단일 소스로 삼는다 — 이전엔 이 리소스와 그 YAML
# 파일 두 곳을 손으로 동기화해야 했음(둘 중 하나만 바뀌면 조용히 어긋남).
# ArgoCD Helm 설치 후 최초 1회 `kubectl apply -f bootstrap/root-app.yaml`로
# 수동 부트스트랩하면, 이후엔 App-of-Apps 패턴대로 ArgoCD 자체가 apps/ 아래
# 추가되는 모든 Application을 알아서 동기화한다 — Terraform이 계속 관여할
# 필요가 없다.
