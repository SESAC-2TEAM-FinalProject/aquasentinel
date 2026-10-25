# ArgoCD Application을 Terraform이 직접 생성하는 "두 번째 GitOps 엔진" 역할 —
# 서울과 동일한 구조적 이유(seoul/rebuild/3-gitops/applications.tf 주석 참고).
# 서울은 git 원본이 이미 서울 값이라 patches가 비어 있는 항목이 많지만, 도쿄는
# 실제 리전별 값(역할 ARN·도메인·시크릿 이름·Replica Cluster 설정)을 여기서
# 채워 패치한다.

locals {
  patched_apps = {
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
        # 🔴 (2026-10-25) 도쿄가 **쓰는** 경로 — 복제본과 갈라 둔 write prefix 다.
        # 전에는 아래 seoul-source 와 같은 `cloudnativepg/` 였고, 그 자리에 서울
        # 백업 복제본이 계속 쌓여서 CNPG 의 "아카이브가 비어 있어야 한다" 검사에
        # 영구히 걸렸다. 근거는 tokyo/persistent/main.tf 의 해당 local 주석.
        {
          target = { kind = "ObjectStore", name = "aquasentinel-backup-store" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/configuration/destinationPath"
              value = "s3://${data.terraform_remote_state.persistent.outputs.bucket_names["observability"]}/${data.terraform_remote_state.persistent.outputs.cloudnativepg_write_prefix}"
            }
          ])
        },
        # 🔴 (2026-10-25) 복구 소스를 **도쿄 버킷의 복제본**으로 돌린다.
        #
        # gitops 의 object-store-seoul-source.yaml 은 서울 버킷을 가리킨다. 그대로
        # 두면 도쿄 복구가 **서울 S3 를 읽어야만** 성립하는데, 그건 서울 리전이
        # 살아 있을 때 이야기다 — 리전 장애로 서울이 통째로 빠지면 읽을 소스가
        # 없어 DR 이 가장 필요한 순간에 복구가 안 된다.
        #
        # 서울 observability 버킷에는 `replicate-to-tokyo` 복제 규칙이 걸려 있어
        # 같은 키가 도쿄 버킷에 들어와 있다. persistent 의 cloudnativepg_prefix 를
        # "서울과 반드시 같은 값"으로 맞춰 둔 것도 이 복제본을 읽기 위한 설계였다
        # (그 local 주석). 구현만 서울 버킷을 보고 있어 의도와 어긋나 있었다.
        #
        # RPO 는 S3 복제 지연(보통 분 단위)에 좌우된다 — 서울 버킷 직접 읽기보다
        # 약간 뒤처진 시점으로 복구된다는 뜻이다.
        {
          target = { kind = "ObjectStore", name = "aquasentinel-pg-seoul-source" }
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
      path      = "manifests/grafana/secret"
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
        {
          target = { kind = "ExternalSecret", name = "grafana-oidc-client-secret" }
          patch = jsonencode([
            { op = "replace", path = "/spec/data/0/remoteRef/key", value = "${local.name_prefix}-grafana-oidc-client-secret" }
          ])
        },
        # Grafana 외부 노출(2026-10-16) — 서울 쪽과 같은 이유, 도메인은 persistent
        # remote state가 서울과 공유라 실제 값은 같지만 구조상 양쪽 다 패치한다.
        {
          target = { kind = "ConfigMap", name = "grafana-oidc-config" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/data/GF_SERVER_ROOT_URL"
              value = "https://grafana.${data.terraform_remote_state.persistent.outputs.domain_name}/"
            },
            {
              op    = "replace"
              path  = "/data/GF_AUTH_GENERIC_OAUTH_AUTH_URL"
              value = "https://auth.${data.terraform_remote_state.persistent.outputs.domain_name}/realms/aquasentinel/protocol/openid-connect/auth"
            },
            {
              op    = "replace"
              path  = "/data/GF_AUTH_GENERIC_OAUTH_TOKEN_URL"
              value = "https://auth.${data.terraform_remote_state.persistent.outputs.domain_name}/realms/aquasentinel/protocol/openid-connect/token"
            },
            {
              op    = "replace"
              path  = "/data/GF_AUTH_GENERIC_OAUTH_API_URL"
              value = "https://auth.${data.terraform_remote_state.persistent.outputs.domain_name}/realms/aquasentinel/protocol/openid-connect/userinfo"
            },
          ])
        },
      ]
    }
    # Grafana HTTPRoute — keycloak/web과 같은 이유로 별도 patched_app.
    "grafana-httproute" = {
      path      = "manifests/grafana/httproute"
      namespace = "monitoring"
      patches = [
        {
          target = { kind = "HTTPRoute", name = "grafana" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/hostnames/0"
              value = "grafana.${data.terraform_remote_state.persistent.outputs.domain_name}"
            }
          ])
        },
      ]
    }
    # 알람 수신처(Discord·데드맨)와 ArgoCD 알림 시크릿 — 서울과 같은 매니페스트에 도쿄
    # Secrets Manager 이름만 패치한다(알람 파이프라인 묶음 B, 2026-10-14). 도쿄용 값(특히
    # 데드맨 핑 URL은 서울과 다른 체크)은 도쿄 Warm Standby 구성 때 등록한다.
    "alerting-secret" = {
      path      = "manifests/alerting/secret"
      namespace = "monitoring"
      patches = [
        {
          target = { kind = "ExternalSecret", name = "alertmanager-receivers" }
          patch = jsonencode([
            { op = "replace", path = "/spec/dataFrom/0/extract/key", value = "${local.name_prefix}-alertmanager-receivers" }
          ])
        },
      ]
    }
    "argocd-notifications-secret" = {
      path      = "manifests/argocd/notifications-secret"
      namespace = "argocd"
      patches = [
        {
          target = { kind = "ExternalSecret", name = "argocd-notifications-secret" }
          patch = jsonencode([
            { op = "replace", path = "/spec/dataFrom/0/extract/key", value = "${local.name_prefix}-argocd-notifications" }
          ])
        },
      ]
    }
    "api-module-db-secret" = {
      path      = "manifests/api-module/db-secret"
      namespace = "api-module"
      patches = [
        # 🔴🔴 평상시 도쿄에서는 이 PushSecret 을 **리소스째 제거한다** —
        # 2026-10-01 팀 결정의 복원(2026-10-25 재적용). Keycloak·status-svc 와
        # 같은 누락 경로다(`environments/aws-tokyo-dr/` → `tokyo/rebuild/` 재편 때
        # 안 옮겨졌다).
        #
        # 🔴 **왜 끄는 것이 맞는가**: 이 PushSecret 은 `aquasentinel-db` 의
        # `aquasentinel-pg-app` Secret 을 읽어 Secrets Manager 로 밀어 넣는다.
        # 그런데 **Replica Cluster 는 app 사용자를 만들지 않으므로**(소스를 그대로
        # 따라간다) CNPG 가 그 Secret 을 **애초에 생성하지 않는다** —
        # 2026-10-25 실측: 서울 `aquasentinel-pg-app` 11키 ·
        # `ownerReferences: kind=Cluster` / 🔴 도쿄 **NotFound**.
        # 그래서 source 가 없어 영구 실패한다:
        #
        #     PushSecret api-module-database  Errored
        #     Ready=False: could not get source secret
        #
        # 🔴 Keycloak 의 `instances` 처럼 **끄는 스위치가 PushSecret 에는 없어서**
        # 2026-10-01 에 "리소스 자체를 제거" 로 정했다. JSON Patch 로는 리소스를
        # 지울 수 없으므로 strategic merge 의 `$patch: delete` 를 쓴다.
        #
        # 🔴 **승격(DR 전환) 때는 이 패치를 지우고 아래 주석의 키 치환 패치를
        # 되살린다** — 런북 ③단계. 승격 후에는 CNPG 가 app 사용자를 관리하게 되어
        # Secret 이 생기고, 그때 remoteKey 를 도쿄 이름으로 바꿔 줘야 한다.
        # 삭제 패치와 키 치환 패치는 **공존할 수 없다**(없는 리소스에 JSON Patch 를
        # 걸면 Kustomize 가 "no matches for target" 으로 실패한다) — 그래서 원본을
        # 지우지 않고 아래에 그대로 남겨 둔다:
        #
        #     {
        #       target = { kind = "PushSecret", name = "api-module-database" }
        #       patch = jsonencode([
        #         for i, field in ["username", "password", "host", "port", "dbname"] : {
        #           op    = "replace"
        #           path  = "/spec/data/${i}/match/remoteRef/remoteKey"
        #           value = "${local.name_prefix}-api-module-database-${field}"
        #         }
        #       ])
        #     },
        #
        # 🔴 metadata.namespace 는 `aquasentinel-db` 다(이 Application 의 destination
        # 은 `api-module` 이지만 PushSecret 매니페스트가 자기 namespace 를 명시한다 —
        # manifests/api-module/db-secret/push-secret.yaml).
        {
          target = { kind = "PushSecret", name = "api-module-database" }
          patch  = <<-EOT
            apiVersion: external-secrets.io/v1alpha1
            kind: PushSecret
            metadata:
              name: api-module-database
              namespace: aquasentinel-db
            $patch: delete
          EOT
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
    # 달리 양쪽 다 실제 패치를 채운다(manifests/gateway/instance/loadbalancer-config.yaml
    # 주석 참고).
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
    # 실제 도메인은 cert ARN과 같은 이유로 패치(서울 쪽 주석 참고). DB 비밀번호
    # remoteRef.key도 도쿄 전용 Secrets Manager 이름으로 바꾼다.
    # (2026-10-20) 이 앱의 ExternalSecret 중 **일부러 패치하지 않는 것들**이 있다.
    #
    # 도쿄는 ClusterSecretStore 리전을 var.region 으로 바꿔 도쿄 Secrets Manager
    # 만 읽는다. 그래서 대부분의 ExternalSecret 키를 aquasentinel-dr-tokyo-* 로
    # 패치하는데, **값이 서울과 같아야 하는 것은 패치하면 안 된다.**
    #
    #   aquasentinel-keycloak-admin → aquasentinel-dev-keycloak-admin-client-secret
    #
    # Keycloak 은 클라이언트 비밀값을 자기 DB 안에 저장한다. 리전 DR 은 서울
    # 백업에서 DB 를 복구하므로 DB 안 admin-cli-service 비밀값은 **서울 값**이고,
    # 그걸 맞춰 줄 자동 경로가 없다 — 오퍼레이터가 바로 그 자격증명으로
    # 인증하기 때문이다(401 로 잠기면 아무것도 반영 못 함, SIM-09c 실측).
    # grafana 클라이언트는 CR 의 secretRef 로 오퍼레이터가 DB 를 덮어 주므로
    # 값이 달라도 되지만, 이건 아니다.
    #
    # 해결은 **서울 시크릿을 도쿄로 복제**하는 것이다(replicate-secret-to-regions).
    # 복제는 이름을 그대로 유지하므로, 패치하지 않은 이 ExternalSecret 이 그
    # 이름을 그대로 찾아 맞아떨어진다. **여기에 패치를 추가하면 복제본을 못 찾는다.**
    # 같은 이유로 api-module 공공 API 키 4개와 grafana-db-ro-password 도 패치하지
    # 않는다. 자세한 공백 목록은
    # AWS/docs/테스트필드_기동_필요조건_실측정리_2026-10-19.md 「도쿄 시크릿 공백」.
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
        # Grafana confidential 클라이언트(2026-10-16) — 서울 쪽과 같은 이유.
        {
          target = { kind = "KeycloakOIDCClient", name = "aquasentinel-grafana" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/spec/client/redirectUris/0"
              value = "https://grafana.${data.terraform_remote_state.persistent.outputs.domain_name}/login/generic_oauth"
            }
          ])
        },
        {
          target = { kind = "ExternalSecret", name = "grafana-oidc-client-secret" }
          patch = jsonencode([
            { op = "replace", path = "/spec/data/0/remoteRef/key", value = "${local.name_prefix}-grafana-oidc-client-secret" }
          ])
        },
        # 🔴🔴 평상시 도쿄 Keycloak 은 **꺼 둔다** — 2026-10-01 팀 결정의 복원
        # (2026-10-25 재적용).
        #
        # 도쿄 CNPG 는 Replica Cluster(`spec.replica.enabled = true`)라
        # `pg_is_in_recovery() = true` · `transaction_read_only = on` 으로 **항상**
        # 떠 있다(2026-10-25 도쿄 DB 에 직접 질의해 재확인). Keycloak 은 기동할 때
        # 스키마를 만들고 써야 하므로 이 상태에서는 **구조적으로 뜰 수 없다**:
        #
        #     Caused by: org.postgresql.util.PSQLException:
        #       Could not find a server with specified targetServerType: primary
        #
        # 🔴 그래서 2026-10-01 에 **"평상시 도쿄 Keycloak 은 instances=0 으로
        # 꺼둔다"** 로 결정했다. 그런데 그 패치는 당시
        # `environments/aws-tokyo-dr/gitops/main.tf` 에 있었고, 도쿄 구성이
        # `tokyo/rebuild/*` 로 재편될 때 **옮겨지지 않았다.** 도쿄를 그 뒤로 한 번도
        # 띄우지 않아 24일간 드러나지 않았고, 2026-10-25 최초 기동에서
        # CrashLoopBackOff(18회 재시작 / 82분)로 나타났다.
        #
        # 🔴 **승격(DR 전환) 때는 이 패치를 지운다** — 런북 순서는
        # ① Cluster `replica.enabled: true→false`(승격) ② 이 패치 제거(instances 복원)
        # ③ api-module-db-secret 의 PushSecret 삭제 패치 제거
        # ④ Route53 확인(자동) ⑤ app·keycloak 비밀번호를 복구된 DB 값과 맞추기
        # ⑥ 이미지 주소를 도쿄 ECR 로 전환.
        #
        # 🔴 서울에는 이 패치가 없다(그쪽이 Primary 라 instances=1 이 정상).
        {
          target = { kind = "Keycloak", name = "aquasentinel-keycloak" }
          patch = jsonencode([
            { op = "replace", path = "/spec/instances", value = 0 }
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
        # 상태조회 캐시 주소(2026-10-16) — 서울과 같게 이 리전 ElastiCache 기본 엔드포인트를 넣는다
        {
          target = { kind = "ConfigMap", name = "aquasentinel-web" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/data/CACHE_ENDPOINT"
              value = data.terraform_remote_state.cluster.outputs.redis_endpoint
            }
          ])
        },
        # 🔴 (2026-10-25) DB 접속 시크릿 이름을 이 리전 것으로 바꾼다.
        #
        # gitops 의 manifests/web/external-secret.yaml 은 `aquasentinel-dev-api-module-
        # database-*` 를 하드코딩한다. 두 리전 공용 매니페스트인데 Secrets Manager
        # 이름은 리전별로 다르다 — 도쿄에는 `aquasentinel-dr-tokyo-api-module-
        # database-*` 로 들어가 있다(값은 이미 다 있다). 그대로 두면 ESO 가
        # 서울 이름을 찾다가 실패한다:
        #
        #     SecretSyncedError — err: Secret does not exist
        #     key: aquasentinel-dev-api-module-database-username
        #
        # 그러면 web/aquasentinel-pg-app Secret 이 안 생기고, 그걸 env 로 받는
        # status-svc(2벌) · alert-worker · grafana 가 CreateContainerConfigError 로
        # 영원히 못 뜬다. 2026-10-25 도쿄 최초 기동에서 실제로 그랬다.
        #
        # 같은 치환을 `api-module-db-secret` 쪽은 이미 하고 있다(이 파일 위쪽) —
        # 거기만 있고 여기가 빠져 있었다. 필드는 3개뿐이고(username·password·
        # dbname) 순서도 매니페스트 그대로다. 🔴 매니페스트의 data 순서가 바뀌면
        # 이 인덱스도 같이 고쳐야 한다(api-module 쪽과 같은 제약).
        {
          target = { kind = "ExternalSecret", name = "aquasentinel-pg-app" }
          patch = jsonencode([
            for i, field in ["username", "password", "dbname"] : {
              op    = "replace"
              path  = "/spec/data/${i}/remoteRef/key"
              value = "${local.name_prefix}-api-module-database-${field}"
            }
          ])
        },
        # 🔴🔴 평상시 도쿄 status-svc 는 **0벌로 꺼 둔다** — 2026-10-01 팀 결정의
        # 복원(2026-10-25 재적용). Keycloak(위) 과 같은 사유·같은 누락 경로다.
        #
        # 🔴 이쪽은 Keycloak 보다 **더 늦게 발견되는 형태**라 결정이 필요했다 —
        # `app/backend/status-svc/app/main.py` 의 `/readyz` 는 `db.ro()`(읽기 전용)
        # 만 확인하고 `db.rw()` 는 보지 않는다(2026-10-25 코드 재확인):
        #
        #     with db.ro().connect() as c: c.execute(text("select 1"))
        #
        # 즉 읽기 전용 Replica Cluster 에서도 이 프로브는 **"ready" 를 반환**하고,
        # `POST /api/farms` · `PATCH /api/farms/{id}` 같은 **쓰기 요청만 조용히
        # 500 으로 실패**한다. 파드가 아예 안 뜨는 Keycloak 과 달리 "떠 있는데
        # 쓰기만 깨짐" 이라 눈에 안 띈다. 🔴 **앱 코드는 고치지 않고**(웹팀 레포는
        # 태그로 고정 · `handoff/` 불변 원칙) 도쿄에서만 끄는 것으로 정했다.
        #
        # 🔴 **ScaledObject 를 함께 지워야 한다** — status-svc 는 Rollout 이고
        # KEDA ScaledObject(`minReplicaCount: 2` · `fallback.replicas: 2`)가 그
        # Rollout 을 대상으로 삼는다. replicas 만 0 으로 바꾸면 **KEDA 가 만든 HPA 가
        # 곧바로 2벌로 되돌린다**(지표를 못 읽어도 fallback 2벌). 둘을 같이 처리해야
        # 실제로 꺼진다.
        #
        # 🔴 `op = "add"` 인 이유: `manifests/web/status-svc-rollout.yaml` 에는
        # `spec.replicas` 가 **없다**(KEDA 가 스케일을 쥐고 있어서). 경로가 없으면
        # `replace` 는 실패하므로 `add` 로 새로 넣는다.
        #
        # PDB `status-svc`(`minAvailable: 1`)는 그대로 둔다 — 대상 파드가 0개면
        # 축출 제어할 것이 없어 무효이고, 승격 때 복원하면 바로 다시 유효해진다.
        #
        # 🔴 **승격(DR 전환) 때는 아래 두 패치를 지운다** — Keycloak 주석의 런북
        # ②단계와 같은 타이밍이다.
        {
          target = { kind = "Rollout", name = "status-svc" }
          patch = jsonencode([
            { op = "add", path = "/spec/replicas", value = 0 }
          ])
        },
        # 🔴 리소스 **자체를 없애는** 패치라 JSON Patch(op/path/value)가 아니라
        # strategic merge 의 `$patch: delete` 를 쓴다 — JSON Patch 로는 필드만
        # 지울 수 있고 리소스를 지울 수 없다. Kustomize 가 렌더링 단계에서 빼므로
        # Argo 는 이 리소스를 아예 받지 않고, `prune: true` 라 이미 있던 것은
        # 삭제된다. (`api-module-db-secret` 의 PushSecret 도 같은 방식이다.)
        {
          target = { kind = "ScaledObject", name = "status-svc" }
          patch  = <<-EOT
            apiVersion: keda.sh/v1alpha1
            kind: ScaledObject
            metadata:
              name: status-svc
              namespace: web
            $patch: delete
          EOT
        },
      ]
    }

    # (2026-10-20 리전 대조) 서울에만 있던 앱. 두 리전이 **같은 aws-data 모듈**로
    # ElastiCache 를 만들고(2-cluster module "data") 도쿄도 redis_endpoint 출력을
    # 갖는데, 그걸 긁는 exporter 가 도쿄에만 없었다 — 리전 DR 에서 Redis 지표가
    # 전혀 수집되지 않는다. 위 CACHE_ENDPOINT 패치가 "도쿄에도 Redis 가 있다"는
    # 증거다. 인증 토큰 미사용이라 ConfigMap 패치로 충분하다(서울과 동일).
    "redis-exporter" = {
      path      = "manifests/redis-exporter"
      namespace = "monitoring"
      patches = [
        {
          target = { kind = "ConfigMap", name = "redis-exporter-config" }
          patch = jsonencode([
            {
              op    = "replace"
              path  = "/data/REDIS_ADDR"
              value = "redis://${data.terraform_remote_state.cluster.outputs.redis_endpoint}:6379"
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
        retry = local.app_sync_retry
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  # gitops_repo_creds(bootstrap.tf)에도 의존해야 한다 — 서울과 동일 레이스 방지
  # (2026-10-14, 서울 applications.tf 수정과 동일 이유).
  depends_on = [helm_release.argocd, kubernetes_secret_v1.gitops_repo_creds]
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

    # (2026-10-20 리전 대조) 서울이 2026-10-15 에 켠 것이 도쿄에 빠져 있었다 —
    # ServiceMonitor 가 없어 **Loki 본체·loki-canary 지표가 Prometheus 에 전혀
    # 들어오지 않는다.** 서울에서는 "커버리지 점검 중 발견"으로 고쳤는데 도쿄에
    # 반영되지 않았다. 리전 DR 에서 로그 파이프라인 상태를 못 보게 된다.
    monitoring:
      serviceMonitor:
        enabled: true

    singleBinary:
      replicas: 1
      persistence:
        size: 10Gi
        storageClass: gp2
      # (2026-10-20 리전 대조) 서울과 같은 값. requests 가 없으면 BestEffort 라
      # 메모리 압박 시 축출 1순위가 된다 — 고유 데이터(로그)를 들고 1벌로 도는
      # 워크로드라 축출되면 그대로 멈춘다. 서울 값은 보유 데이터 P95 기준 산정분
      # (서비스 배치 최종 제안 2026-10-15 7장)이고, 도쿄도 같은 모듈·같은 노드
      # 구성이라 같은 값을 쓴다.
      resources:
        requests:
          cpu: 25m
          memory: 230Mi
      # 🔴 2026-10-25 추가 — 2-cluster 가 node_labels·node_taints 를 넘기게 되면서
      # 도쿄 노드 3대가 전부 `aquasentinel.io/nodepool=stateful` 라벨 +
      # `dedicated=stateful:NoSchedule` taint 를 갖는다. 이전 전제("도쿄엔 라벨도
      # taint 도 없다")가 뒤집혀서, 이제는 **toleration 이 없는 쪽이 Pending** 이다.
      # 서울 loki_values 와 같은 값이다(그쪽 주석이 왜 온디맨드 고정 노드인지 설명).
      nodeSelector:
        aquasentinel.io/nodepool: stateful
      tolerations:
        - key: dedicated
          operator: Equal
          value: stateful
          effect: NoSchedule

    # (2026-10-20 리전 대조) loki-canary 도 서울과 같은 값.
    # tolerations 는 넣는다 — 이건 키 없는 `operator: Exists` 라 **특정 노드 라벨에
    # 의존하지 않는다**(모든 NoSchedule taint 허용). DaemonSet 이라 모든 노드에
    # 떠야 하므로, 도쿄에 나중에 taint 가 생겨도 그대로 맞다. nodeSelector 처럼
    # 라벨을 요구하는 값만 빼는 것이 기준이다.
    lokiCanary:
      tolerations:
        - operator: Exists
          effect: NoSchedule
      resources:
        requests:
          cpu: 5m
          memory: 20Mi

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
        retry = local.app_sync_retry
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

    # EKS는 컨트롤플레인(scheduler·controller-manager·etcd)을 AWS가 관리해서
    # 지표를 수집할 수 없다 — 켜 두면 KubeSchedulerDown·KubeControllerManagerDown이
    # 영원히 발화한다(2026-10-14 라이브 확인). 수집 대상·규칙·대시보드를 함께 끈다.
    kubeScheduler:
      enabled: false
    kubeControllerManager:
      enabled: false
    kubeEtcd:
      enabled: false

    alertmanager:
      alertmanagerSpec:
        # (2026-10-20 리전 대조) 서울과 같은 값. requests 가 없으면 BestEffort 다.
        resources:
          requests:
            cpu: 5m
            memory: 200Mi
        # 🔴 2026-10-25 추가 — 노드 taint 대응(이 파일 loki singleBinary 주석 참고).
        nodeSelector:
          aquasentinel.io/nodepool: stateful
        tolerations:
          - key: dedicated
            operator: Equal
            value: stateful
            effect: NoSchedule
        # 기본값(OnNamespace)이면 AlertmanagerConfig가 자기 네임스페이스 알림만
        # 받는다 — monitoring에 둔 라우팅 트리(gitops manifests/alerting)가 web·
        # api-module·aquasentinel-db·nats 알림과, 네임스페이스 라벨이 없는 노드
        # 알림·Watchdog을 못 받는다(2026-10-14 라이브 확인). 클러스터가 하나뿐이라
        # 아래 prometheusSpec의 셀렉터 전체 매칭과 같은 이유로 제한을 끈다.
        alertmanagerConfigMatcherStrategy:
          type: None
        # (2026-10-20 리전 대조) 서울에만 있던 PVC. 없으면 Alertmanager 가
        # 재시작될 때 **Silence 와 알림 전송 기록이 사라진다** — 리전 DR 직후
        # 노드가 재배치되는 구간에서 바로 겪게 된다. gp2 최소 단위가 1Gi 라
        # 그대로 쓴다(실제 사용량은 수십~수백 KB).
        storage:
          volumeClaimTemplate:
            spec:
              storageClassName: gp2
              accessModes: ["ReadWriteOnce"]
              resources:
                requests:
                  storage: 1Gi

    prometheus:
      serviceAccount:
        annotations:
          eks.amazonaws.com/role-arn: "${data.terraform_remote_state.cluster.outputs.thanos_role_arn}"

      prometheusSpec:
        # retention 이 서울(14d)과 다른 2d 다 — DR 대기 리전이라 의도된 값으로
        # 보이지만 근거가 코드·문서에 없다. 리전 DR 측정 기간이 이보다 길어지면
        # 지표가 잘리므로 팀 확인이 필요하다(2026-10-20 리전 대조에서 표시만 함,
        # 값은 바꾸지 않았다).
        retention: 2d

        # (2026-10-20 리전 대조) 서울과 같은 값. requests 가 없으면 BestEffort 라
        # 메모리 압박 시 축출 1순위가 되고, 1벌이라 축출되면 수집이 멈춘다.
        resources:
          requests:
            cpu: 60m
            memory: 950Mi
        # 🔴 2026-10-25 추가 — 노드 taint 대응(이 파일 loki singleBinary 주석 참고).
        nodeSelector:
          aquasentinel.io/nodepool: stateful
        tolerations:
          - key: dedicated
            operator: Equal
            value: stateful
            effect: NoSchedule

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

    # 🔴 2026-10-25 신설 — 도쿄에는 이 두 키가 아예 없었다. 노드 taint 가 생긴
    # 지금은 둘 다 필수다(이 파일 loki singleBinary 주석 참고).
    #
    # Argo CD 차트에서 global 로 닫은 것(bootstrap.tf)과 **같은 부류**지만, 이
    # 차트에는 컴포넌트 전체에 걸리는 global 스케줄링 키가 없어 컴포넌트별로 적는다
    # (서울 kube_prometheus_stack_values 의 같은 주석).
    #
    # 🔴 admissionWebhooks.patch 는 **설치 때 도는 Job 두 개** 몫이다 — 여기가
    # 비면 차트 설치 자체가 Job Pending 으로 멈춘다(Argo CD 의 redisSecretInit 이
    # 09:07Z 에 그렇게 멈췄던 것과 같은 모양).
    #
    # 서울에는 prometheusOperator 에 `affinity.nodeAffinity`(예비 풀 stateful-spare
    # 차단)도 붙어 있으나 **도쿄에는 옮기지 않는다** — 도쿄엔 카펜터도 예비 풀도
    # 없어서 가리킬 대상이 없다. 도쿄에 노드풀이 늘어나면 그때 같이 들여온다.
    prometheusOperator:
      admissionWebhooks:
        patch:
          nodeSelector:
            aquasentinel.io/nodepool: stateful
          tolerations:
            - key: dedicated
              operator: Equal
              value: stateful
              effect: NoSchedule
      tolerations:
        - key: dedicated
          operator: Equal
          value: stateful
          effect: NoSchedule

    # kube-state-metrics 는 판정 목표 #2·#3 을 **재는 수단**이라 서울에서도
    # nodeSelector(필수)로 고정했다. 도쿄는 아직 재는 대상이 아니지만, 리전 간
    # 설정 드리프트를 만들지 않기 위해 같은 값을 쓴다.
    kube-state-metrics:
      nodeSelector:
        aquasentinel.io/nodepool: stateful
      tolerations:
        - key: dedicated
          operator: Equal
          value: stateful
          effect: NoSchedule
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
        retry = local.app_sync_retry
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

    # (2026-10-20 리전 대조) 서울에만 있던 제약. 2벌이지만 같은 노드 한 대에
    # 몰릴 수 있어(서울에서 실측으로 확인됨) 그 노드가 사라지면 2벌이 동시에
    # 없어진다 — **진입점을 만드는 컨트롤러라 리전 DR 에서 특히 아프다.**
    # labelSelector 를 생략하면 스큐 계산 대상을 못 찾아 제약이 무효가 된다
    # (이 차트는 자동으로 채워주지 않음, 서울 2026-10-15 실측).
    # 노드 라벨에 의존하지 않는 제약이라 도쿄에도 그대로 쓴다.
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: aws-load-balancer-controller
            app.kubernetes.io/instance: aws-load-balancer-controller

    # 🔴 2026-10-25 추가 — 노드 taint 대응(이 파일 loki singleBinary 주석 참고).
    # 위 hostname 분산이 `DoNotSchedule` 이라 2벌이 서로 다른 노드에 앉아야 하는데,
    # toleration 이 없으면 **앉을 수 있는 노드가 0 대**라 둘 다 Pending 이다.
    # nodeSelector 는 서울에도 없어 넣지 않는다(서울은 affinity 로 예비 풀만 차단).
    tolerations:
      - key: dedicated
        operator: Equal
        value: stateful
        effect: NoSchedule
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
        retry = local.app_sync_retry
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  depends_on = [helm_release.argocd]
}

# Grafana — 서울과 동일 구조적 이유로 Application 전체를 Terraform이 소유한다
# (seoul/rebuild/3-gitops/applications.tf 주석 참고). CloudWatch 데이터소스는
# 아직 서울 전용이라 이 SA엔 role-arn annotation이 없다 — authType: default라
# 자격증명 체인을 못 찾으면 그 데이터소스만 조용히 인증 실패한다(Grafana 기동
# 자체엔 영향 없음).
locals {
  grafana_values = <<-EOT
    admin:
      existingSecret: grafana-admin-credentials
      userKey: admin-user
      passwordKey: admin-password

    persistence:
      enabled: true
      storageClassName: gp2
      size: 5Gi

    deploymentStrategy:
      type: Recreate

    resources:
      requests:
        cpu: 5m
        memory: 170Mi

    # 🔴 2026-10-25 — nodeSelector 를 **되살렸다.** 위 조건이 충족됐다.
    #
    # 경위: 2026-10-16(79c2312)에 서울 값을 복사해 nodeSelector 가 들어갔으나,
    # 그때 도쿄 2-cluster 는 node_labels 를 넘기지 않아 그 라벨을 가진 노드가 없어
    # Grafana 가 영구 Pending 이었다 → 2026-10-19 에 nodeSelector 만 뺐다. 그리고
    # 그 자리에 **"카펜터 도입과 함께 taint·라벨이 들어오는 순간 … nodeSelector 도
    # 같이 되살려야 한다"** 고 적어 두었다.
    #
    # 오늘 2-cluster 가 node_labels·node_taints 를 넘기면서(카펜터가 아니라 3 AZ ·
    # 온디맨드 3대 고정 작업으로) 노드 3대에 라벨과 taint 가 모두 붙었다. 이제
    # nodeSelector 는 통과하고, 오히려 **toleration 이 없는 쪽이 Pending** 이다.
    nodeSelector:
      aquasentinel.io/nodepool: stateful
    tolerations:
      - key: dedicated
        operator: Equal
        value: stateful
        effect: NoSchedule

    sidecar:
      dashboards:
        enabled: true
        label: grafana_dashboard
        labelValue: "1"
        searchNamespace: monitoring

    envFromConfigMaps:
      - name: grafana-oidc-config
    envFromSecrets:
      - name: grafana-oidc-client-secret

    envValueFrom:
      GRAFANA_PG_RO_USER:
        secretKeyRef:
          name: grafana-db-ro-credentials
          key: username
      GRAFANA_PG_RO_PASSWORD:
        secretKeyRef:
          name: grafana-db-ro-credentials
          key: password

    serviceAccount:
      create: false
      name: grafana

    datasources:
      datasources.yaml:
        apiVersion: 1
        datasources:
          - name: Prometheus
            type: prometheus
            url: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
            access: proxy
            isDefault: true
          - name: Loki
            type: loki
            url: http://loki.monitoring.svc.cluster.local:3100
            access: proxy
          - name: PostgreSQL (읽기 전용)
            type: postgres
            url: aquasentinel-pg-ro.aquasentinel-db.svc.cluster.local:5432
            database: app
            user: $GRAFANA_PG_RO_USER
            access: proxy
            jsonData:
              sslmode: require
              postgresVersion: 1700
            secureJsonData:
              password: $GRAFANA_PG_RO_PASSWORD
          - name: CloudWatch
            type: cloudwatch
            jsonData:
              authType: default
              defaultRegion: ap-northeast-2
  EOT
}

resource "kubernetes_manifest" "grafana_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "grafana"
      namespace = "argocd"
    }
    spec = {
      project = "default"

      sources = [
        {
          repoURL        = "https://grafana.github.io/helm-charts"
          chart          = "grafana"
          targetRevision = "10.5.15"
          helm = {
            values = local.grafana_values
          }
        },
        {
          repoURL        = local.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "manifests/grafana/dashboards"
        },
      ]

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "monitoring"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        retry = local.app_sync_retry
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  }

  # gitops_repo_creds 에도 의존해야 한다 — 이 Application 은 두 번째 소스로
  # **비공개** gitops 레포를 읽는다(멀티소스). helm_release.argocd 에만 의존하면
  # 시크릿보다 먼저 만들어질 수 있고, 그러면 Argo CD 가 레포를 못 읽어
  # `HTTP Basic: Access denied` 로 동기화가 멈춘다. root 앱(patched_app)이
  # 같은 이유로 이미 이렇게 돼 있다 — 2026-10-14 주석 참고.
  #
  # (2026-10-19) 시험 구역 1 구축에서 karpenter_app 이 이 레이스에 걸려
  # CRD 가 안 생겼고, wait_for_karpenter_crds 가 5분 타임아웃으로 죽었다.
  # -target 으로 단계를 나누면 확정적으로 재현된다. 같은 구조인
  # grafana_app 도 같이 고친다(아직 안 터졌을 뿐 같은 구멍).
  depends_on = [helm_release.argocd, kubernetes_secret_v1.gitops_repo_creds, kubernetes_service_account_v1.grafana]
}

# LBC + Gateway API CRD 부트스트랩 경쟁 조건(서울과 동일 구조적 이슈,
# seoul/rebuild/3-gitops/applications.tf 주석 참고) — Terraform이 자동 복구한다.
resource "time_sleep" "wait_for_lbc_bootstrap" {
  depends_on      = [kubernetes_manifest.aws_load_balancer_controller_app]
  create_duration = "60s"
}

resource "null_resource" "restart_lbc_for_gateway_api" {
  depends_on = [time_sleep.wait_for_lbc_bootstrap]

  # (2026-10-14, 서울과 동일 수정) rm -f가 마지막 줄이면 kubectl 실패가 가려진다.
  #
  # 🔴 (2026-10-25) 이 리소스도 같은 이유로 tainted 가 됐다 — CI 러너 이미지에
  # kubectl 이 없다. 경위와 해결은 main.tf 의 local.ensure_kubectl 주석 참고.
  # 접속 정보를 environment 로 옮긴 이유(토큰 로그 노출)도 같은 곳에 적어 두었다.
  provisioner "local-exec" {
    environment = {
      K8S_SERVER = data.terraform_remote_state.cluster.outputs.cluster_endpoint
      K8S_CA_B64 = data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data
      K8S_TOKEN  = data.aws_eks_cluster_auth.this.token
    }
    command = <<-EOT
      ${local.ensure_kubectl}
      CA_FILE=$(mktemp)
      echo "$K8S_CA_B64" | base64 -d > "$CA_FILE"
      kubectl --server="$K8S_SERVER" --certificate-authority="$CA_FILE" --token="$K8S_TOKEN" -n kube-system rollout restart deployment aws-load-balancer-controller
      STATUS=$?
      rm -f "$CA_FILE"
      exit $STATUS
    EOT
  }
}

# root Application 은 root.tf 에서 Terraform 이 만든다(GitOps 저장소 주소 일원화 안 A, 2026-10-14).