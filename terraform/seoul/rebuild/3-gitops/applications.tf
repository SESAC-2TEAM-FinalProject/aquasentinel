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
    # 백업 역할 ARN · 백업 경로 — git 원본이 서울 값이라 서울에선 같은 값을 다시 넣는 셈이지만,
    # 같은 코드를 다른 계정(시험 구역)에 apply 하면 그 계정 값이 들어가 운영 백업 버킷에 쓰지 않는다
    # (도쿄 applications.tf 의 같은 패치와 같은 모양).
    "cloudnativepg-cluster" = {
      path      = "manifests/cloudnativepg/cluster"
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
      ]
    }
    "grafana-secret" = {
      path      = "manifests/grafana/secret"
      namespace = "monitoring"
      patches   = []
    }
    "api-module-db-secret" = {
      path      = "manifests/api-module/db-secret"
      namespace = "api-module"
      patches   = []
    }
    # ACM 인증서 ARN은 서울/도쿄 둘 다 예측 불가능한 값이라, 다른 항목들과
    # 달리 양쪽 다 실제 패치를 채운다(manifests/gateway/instance/loadbalancer-config.yaml
    # 주석 참고).
    # (2026-10-14) path가 "manifests/gateway-api"로 남아있던 드리프트 수정 —
    # 2026-10-13 gitops 레포 폴더 재정리(커밋 689c0f1) 이후 라이브 Application은
    # 이미 새 경로를 쓰고 있었는데 이 코드만 안 따라와서, 평범한 terraform apply
    # 한 번이면 5개 Application 전부가 존재하지 않는 옛 경로로 되돌아가 prune으로
    # 라이브 리소스가 삭제될 뻔했다(2-5단계 작업 중 plan으로 발견). 라이브
    # source.path를 직접 조회해서 정확한 값으로 맞췄다.
    "gateway-api" = {
      path      = "manifests/gateway/instance"
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
      path      = "manifests/keycloak/instance"
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
        # 로그인 토큰 발급자 주소 — keycloak 패치와 같은 auth 서브도메인. 서울은 git 값과 같고,
        # 시험 구역은 그 구역 도메인의 로그인 서버를 보게 된다.
        {
          target = { kind = "ConfigMap", name = "aquasentinel-web" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/data/OIDC_ISSUER"
              value = "https://auth.${data.terraform_remote_state.persistent.outputs.domain_name}/realms/aquasentinel"
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
          targetRevision = var.gitops_revision
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

  # gitops_repo_creds(bootstrap.tf)에도 의존해야 한다 — 둘 다 helm_release.argocd에만
  # 의존했을 때는 병렬/임의 순서로 생성될 수 있어, 시크릿보다 이 Application이 먼저
  # 만들어지면 ArgoCD가 private 레포를 못 읽어 동기화가 지연된다. api-module-db-secret
  # Application(네임스페이스 api-module 생성 담당)이 이 레이스에 걸리면
  # wait_for_api_module_namespace(bootstrap.tf)의 5분 타임아웃을 넘긴다
  # (2026-10-13 발견, 2026-10-14 수정).
  depends_on = [helm_release.argocd, kubernetes_secret_v1.gitops_repo_creds]
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
      # 서비스 배치 최종 제안(2026-10-15) 7장 단계 2 — requests 없는 BestEffort.
      # 보유 데이터(~46시간) P95 기준 산정.
      resources:
        requests:
          cpu: 25m
          memory: 230Mi

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

    # 서비스 배치 최종 제안(2026-10-15) 7장 단계 2 — 메모리 200Mi는 이미
    # Prometheus Operator가 CR에 resources 설정이 없을 때 적용하는 암묵적
    # 기본값으로 들어가 있던 것(Alertmanager CR 자체엔 비어 있었음, 2026-10-15
    # 확인) — CPU만 비어 있어서 추가. resources를 명시하면 그 암묵적 기본값이
    # 사라지므로 memory도 기존값(200Mi)을 그대로 같이 적어 유지한다.
    alertmanager:
      alertmanagerSpec:
        resources:
          requests:
            cpu: 5m
            memory: 200Mi

    prometheus:
      serviceAccount:
        annotations:
          eks.amazonaws.com/role-arn: "${data.terraform_remote_state.cluster.outputs.thanos_role_arn}"

      prometheusSpec:
        resources:
          requests:
            cpu: 60m
            memory: 950Mi

        # 서비스 배치 최종 제안(2026-10-15) 9장 안건 5 — requests 산정 기준으로
        # "Prometheus 2주치 P95"를 쓰기로 했는데 retention이 2d라 애초에 2주치가
        # 쌓일 수 없었다. 지금 당장의 산정은 보유된 ~2일치로 하되(아래 참고),
        # 앞으로는 쌓이도록 늘려둔다. 하루 사용량 실측 약 0.6GiB → 14일치
        # 약 8.75GiB, 기존 20Gi PVC 안에 여유 있게 들어감(증설 불필요).
        retention: 14d

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

    # 서비스 배치 최종 제안(2026-10-15) 1장 ①-나, 3.4절, 7장 단계 1-d — 이미
    # 2벌이지만 같은 스팟 노드 한 대에 몰려 있어(실측 확인) 그 노드가 회수되면
    # 2벌 다 동시에 사라진다. coredns·ebs-csi와 같은 패턴으로 노드 단위 강제 분산.
    # labelSelector를 생략하면 스큐 계산 대상 파드를 못 찾아 제약이 무효화된다
    # (argo-rollouts 차트와 달리 이 차트는 자동으로 안 채워줌 — 실제 적용해보고
    # 같은 노드에 그대로 몰려있는 걸로 확인, 2026-10-15).
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: aws-load-balancer-controller
            app.kubernetes.io/instance: aws-load-balancer-controller
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

# 카펜터(Karpenter) — 가용성/DR 재구축 개선안(2026-10-13) 2단계. IAM 정책/
# 인터럽션 큐/디스커버리 태그는 2-cluster/karpenter.tf가 이미 만들어뒀다
# (10/13 적용 완료). 여기서는 컨트롤러 자체(Helm)와, 그 아래 NodePool/
# EC2NodeClass(karpenter.tf, 이 디렉토리)를 설치한다.
#
# 공식 배포 채널이 OCI 레지스트리뿐이라(helm install도 oci://로 받음) 다른
# Application들과 달리 repoURL이 차트 경로 자체다 — ArgoCD 2.5+는 repoURL이
# OCI 아티팩트를 직접 가리키면 chart 필드 없이 자동으로 OCI 소스로 인식한다.
#
# settings.clusterEndpoint를 일부러 안 넣는다 — 2-cluster/karpenter.tf의
# EKSIntegrationPolicy(eks:DescribeCluster)가 정확히 이 값을 런타임에
# 스스로 알아내라고 만든 권한이다(수동 설정과 이중 관리 방지).
locals {
  karpenter_values = <<-EOT
    settings:
      clusterName: ${data.terraform_remote_state.cluster.outputs.cluster_name}
      interruptionQueue: ${data.terraform_remote_state.cluster.outputs.karpenter_interruption_queue_name}

    serviceAccount:
      create: false
      name: karpenter

    replicas: 1

    controller:
      resources:
        requests:
          cpu: 200m
          memory: 256Mi
        limits:
          cpu: 500m
          memory: 512Mi

    # 스테이트풀 워크로드 복귀 작업(2026-10-14) — 컨트롤러는 "카펜터가 만든 노드엔
    # 못 뜬다"는 nodeAffinity(karpenter.sh/nodepool DoesNotExist) 때문에 오직 이
    # 관리형 노드그룹에만 뜰 수 있다. 그 노드그룹에 dedicated=stateful taint를 걸
    # 예정이라(2-cluster/main.tf), 미리 toleration을 반영해두지 않으면 taint가
    # 걸리는 순간 컨트롤러가 Pending에 빠져 카펜터 전체가 멈춘다. tolerations는
    # 리스트라 차트 기본값(CriticalAddonsOnly)을 그대로 같이 적어야 덮어써지지
    # 않는다(helm template으로 렌더링 확인 완료).
    tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: dedicated
        operator: Equal
        value: stateful
        effect: NoSchedule
  EOT
}

resource "kubernetes_manifest" "karpenter_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "karpenter"
      namespace = "argocd"
    }
    spec = {
      project = "default"

      source = {
        # OCI 소스는 다른 Application들과 필드 구성이 다르다 — repoURL엔 레지스트리까지만
        # 넣고(oci:// 접두사 없이), 차트 이름은 chart 필드로 분리해야 한다. repoURL에
        # 차트 경로까지 합쳐 넣었다가 "spec.source.repoURL and either spec.source.path
        # or spec.source.chart are required" InvalidSpecError로 처음 실패했다
        # (2026-10-14, ArgoCD 공식 Helm OCI 문서로 교차 확인 후 수정).
        repoURL        = "public.ecr.aws/karpenter"
        chart          = "karpenter"
        targetRevision = "1.0.8" # EKS 1.31 지원 최소 버전(1.0.5) 이후의 패치 릴리스
        helm = {
          values = local.karpenter_values
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

  depends_on = [helm_release.argocd, kubernetes_service_account_v1.karpenter]
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

  # (2026-10-14) 같은 레포의 다른 wait 스크립트들에서 발견된 마스킹 버그(마지막 줄이
  # rm -f라 앞선 kubectl이 실패해도 항상 exit 0)를 여기도 같이 고친다.
  provisioner "local-exec" {
    command = <<-EOT
      CA_FILE=$(mktemp)
      echo "${data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data}" | base64 -d > "$CA_FILE"
      kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} -n kube-system rollout restart deployment aws-load-balancer-controller
      STATUS=$?
      rm -f "$CA_FILE"
      exit $STATUS
    EOT
  }
}

# root Application 은 root.tf 에서 Terraform 이 만든다(GitOps 저장소 주소 일원화 안 A, 2026-10-14).