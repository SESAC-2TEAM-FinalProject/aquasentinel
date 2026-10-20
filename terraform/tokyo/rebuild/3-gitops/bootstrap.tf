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

  # (2026-10-14, 서울 bootstrap.tf와 동일 수정) 마지막 줄이 rm -f면 60회 polling이
  # 전부 실패해도 항상 exit 0으로 끝나 타임아웃이 가려진다 — 종료 코드를 명시적으로
  # 판정한다. 도쿄는 아직 한 번도 실제 적용된 적 없어서 최초 기동 때 이 버그가
  # 그대로 재현될 뻔했다(회신 문서 Q9 참고).
  provisioner "local-exec" {
    command = <<-EOT
      CA_FILE=$(mktemp)
      echo "${data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data}" | base64 -d > "$CA_FILE"
      for i in $(seq 1 60); do
        kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} get namespace api-module >/dev/null 2>&1 && break
        sleep 5
      done
      kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} get namespace api-module
      STATUS=$?
      rm -f "$CA_FILE"
      if [ "$STATUS" -ne 0 ]; then
        echo "TIMEOUT: api-module namespace not found after 5m" >&2
        exit 1
      fi
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

# Notifications 설정이 Helm values에 있는 이유: ConfigMap·Secret이 Helm 소유라
# 직접 고치면 재구축·helm upgrade 때 사라진다.
# secret.create: false인 이유: 웹훅을 git·Terraform state에 두지 않으려고
# ExternalSecret(manifests/argocd/notifications-secret, Terraform patched_apps)이
# 시크릿을 만든다.
# Discord를 webhook 서비스로 보내는 이유: ArgoCD에 Discord 전용 서비스가 없다.
# on-degraded-10m의 10분 조건: 재구축 때 Application들이 잠깐 Degraded를 거치므로,
# 동기화가 끝나고 10분 넘게 이어질 때만 보낸다. Alertmanager의 재구축 억제 규칙은
# 이 경로에 적용되지 않는다.
# 🔴 10분을 재는 기준점은 "Degraded가 된 시각"이 아니라 "마지막 동기화가 끝난 시각
# (operationState.finishedAt)"이다. 그래서 평상시에는 게이트가 열려 있어 Degraded가
# 되는 순간 바로 알림이 간다(서울 2026-10-20 실측). 그래서 알림 제목에 "10분 이상"을
# 쓰지 않는다 — 실제 발송 시점과 어긋난다. 서울과 같은 값을 유지한다.
# 구독을 Application 31개에 annotation으로 달지 않고 전역 구독 하나로 건 이유:
# 새 Application도 자동으로 포함된다.
# 템플릿의 toJson·trunc: 실패 메시지에 따옴표·줄바꿈이 있어도 JSON이 깨지지 않게
# 하고, Discord 메시지 한도(2000자) 안에 들게 한다.
# 서울·도쿄가 같은 값을 쓴다(웹훅 값은 각 리전 Secrets Manager에서 온다).
locals {
  # 인프라 설정 — 서울 bootstrap.tf 의 첫 번째 values 블록에서 **스케줄링을 뺀**
  # 것과 같다. 스케줄링을 왜 빼는지는 helm_release.argocd 주석 참고.
  argocd_infra_values = <<-EOT
    configs:
      # Server-Side Diff — 오퍼레이터·CRD 웹훅이 채우는 암묵적 기본값 때문에
      # 생기는 영구 OutOfSync 를 막는다. 서울은 2026-10-15 에 켰고(621c4f9)
      # 도쿄는 빠져 있었다(2026-10-20 발견).
      params:
        controller.diff.server.side: "true"

      # Keycloak 오퍼레이터 CR 의 커스텀 health (2026-10-19 요청 K-3).
      # Argo CD 는 커스텀 health 가 없는 CR 을 무조건 Healthy 로 본다 — 그래서
      # KeycloakOIDCClient 가 `HasErrors=True` 여도 Application 이 녹색으로 보였고,
      # 계정 간 복구 뒤 "파드는 다 떠 있는데 로그인만 안 되는" 상태가 가려졌다
      # (SIM-09c). 근거와 판정 규칙은 서울 bootstrap.tf 의 같은 블록 주석 참고.
      cm:
        resource.customizations.health.k8s.keycloak.org_KeycloakOIDCClient: |
          local hs = {}
          if obj.status ~= nil and obj.status.conditions ~= nil then
            for _, c in ipairs(obj.status.conditions) do
              if c.type == "HasErrors" then
                if tostring(c.status) == "True" then
                  hs.status = "Degraded"
                  hs.message = c.message or "HasErrors=True (어드민 API 반영 실패)"
                  return hs
                elseif tostring(c.status) == "False" then
                  hs.status = "Healthy"
                  hs.message = "HasErrors=False"
                  return hs
                end
              end
            end
          end
          hs.status = "Progressing"
          hs.message = "오퍼레이터가 HasErrors 를 보고하기 전"
          return hs

        resource.customizations.health.k8s.keycloak.org_KeycloakSamlClient: |
          local hs = {}
          if obj.status ~= nil and obj.status.conditions ~= nil then
            for _, c in ipairs(obj.status.conditions) do
              if c.type == "HasErrors" then
                if tostring(c.status) == "True" then
                  hs.status = "Degraded"
                  hs.message = c.message or "HasErrors=True (어드민 API 반영 실패)"
                  return hs
                elseif tostring(c.status) == "False" then
                  hs.status = "Healthy"
                  hs.message = "HasErrors=False"
                  return hs
                end
              end
            end
          end
          hs.status = "Progressing"
          hs.message = "오퍼레이터가 HasErrors 를 보고하기 전"
          return hs

        resource.customizations.health.k8s.keycloak.org_KeycloakRealmImport: |
          local hs = {}
          if obj.status ~= nil and obj.status.conditions ~= nil then
            for _, c in ipairs(obj.status.conditions) do
              if c.type == "HasErrors" and tostring(c.status) == "True" then
                hs.status = "Degraded"
                hs.message = c.message or "HasErrors=True (realm 가져오기 실패)"
                return hs
              end
            end
            for _, c in ipairs(obj.status.conditions) do
              if c.type == "Done" and tostring(c.status) == "True" then
                hs.status = "Healthy"
                hs.message = "realm 가져오기 완료"
                return hs
              end
            end
          end
          hs.status = "Progressing"
          hs.message = "realm 가져오기 진행 중"
          return hs

        resource.customizations.health.k8s.keycloak.org_Keycloak: |
          local hs = {}
          if obj.status ~= nil and obj.status.conditions ~= nil then
            for _, c in ipairs(obj.status.conditions) do
              if c.type == "HasErrors" and tostring(c.status) == "True" then
                hs.status = "Degraded"
                hs.message = c.message or "HasErrors=True"
                return hs
              end
            end
            for _, c in ipairs(obj.status.conditions) do
              if c.type == "Ready" and tostring(c.status) == "True" then
                hs.status = "Healthy"
                hs.message = "Ready"
                return hs
              end
            end
          end
          hs.status = "Progressing"
          hs.message = "Keycloak 기동 중"
          return hs
  EOT

  argocd_values = <<-EOT
    notifications:
      secret:
        create: false

      notifiers:
        service.webhook.discord: |
          url: $discord-webhook-url
          headers:
            - name: Content-Type
              value: application/json

      templates:
        template.app-degraded: |
          webhook:
            discord:
              method: POST
              body: |
                {"username": "ArgoCD", "content": {{ printf "**[ArgoCD] %s — Degraded**\n동기화 리비전: %s\n확인: kubectl get application %s -n argocd -o jsonpath='{.status.health}'" .app.metadata.name .app.status.sync.revision .app.metadata.name | toJson }}}
        template.app-sync-failed: |
          webhook:
            discord:
              method: POST
              body: |
                {"username": "ArgoCD", "content": {{ printf "**[ArgoCD] %s — 동기화 실패 (%s)**\n%s" .app.metadata.name .app.status.operationState.phase (.app.status.operationState.message | trunc 1500) | toJson }}}

      triggers:
        trigger.on-degraded-10m: |
          - description: 마지막 동기화가 끝난 뒤 10분 넘게 Degraded
            when: app.status.health.status == 'Degraded' and app.status.operationState != nil and app.status.operationState.finishedAt != nil and time.Now().Sub(time.Parse(app.status.operationState.finishedAt)).Minutes() >= 10
            send: [app-degraded]
        trigger.on-sync-failed: |
          - description: 동기화 실패
            when: app.status.operationState != nil and app.status.operationState.phase in ['Error', 'Failed']
            oncePer: app.status.operationState?.syncResult?.revision
            send: [app-sync-failed]

      subscriptions:
        - recipients:
            - discord
          triggers:
            - on-degraded-10m
            - on-sync-failed
  EOT
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

  # 첫 번째는 인프라 설정(Server-Side Diff · Keycloak CR health), 두 번째는 알림.
  # Helm 은 목록 순서대로 값을 깊게 병합한다.
  #
  # (2026-10-20) 도쿄에는 이 첫 번째 블록이 아예 없었다 — 서울은
  # `values = [인프라설정, 알림]` 인데 도쿄는 알림 하나뿐이었다. 그래서
  # **서울이 2026-10-15 에 고친 Server-Side Diff 가 도쿄에 없었다**(커밋 621c4f9,
  # "암묵적 기본값으로 인한 영구 OutOfSync 근본 해결"). 그대로 리전 DR 을 돌리면
  # 오퍼레이터·CRD 웹훅이 채운 기본값 때문에 여러 앱이 영구 OutOfSync 가 되고,
  # selfHeal 이 켜져 있어 계속 재동기화를 돌린다 — "전부 Synced/Healthy" 가
  # 끝까지 안 나온다.
  #
  # 스케줄링(global · 컴포넌트 7개)은 **일부러 넣지 않는다** — 도쿄 2-cluster 는
  # node_labels·node_taints 를 넘기지 않아 `aquasentinel.io/nodepool` 라벨을 가진
  # 노드가 없다. nodeSelector 를 복사해 넣으면 그 파드는 반드시 Pending 이 된다
  # (grafana_values 에서 실제로 그랬다 — applications.tf 주석 참고).
  values = [local.argocd_infra_values, local.argocd_values]
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

# grafana Application을 Terraform이 소유하면서(서울과 동일 구조적 이유,
# seoul/rebuild/3-gitops/applications.tf 주석 참고) 같은 이름의 SA가 필요해졌다.
# CloudWatch IRSA는 아직 서울 전용(2-cluster에 도쿄용 role이 없음) — role-arn
# annotation 없이 SA만 만들어 차트가 참조할 이름을 갖춘다. 도쿄에서도 CloudWatch
# 데이터소스가 필요해지면 2-cluster에 grafana_irsa 모듈을 추가하고 여기에
# annotation을 붙인다.
resource "kubernetes_service_account_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
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
