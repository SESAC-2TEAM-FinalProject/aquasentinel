# root Application(app-of-apps)을 Terraform 이 만든다 — GitOps 저장소 주소 일원화 안 A.
# 저장소 주소(local.gitops_repo_url) · 브랜치(var.gitops_revision)가 여기 한 곳에서 정해져,
# root 가 apps/ 를 Kustomize 로 읽으며 라벨 aquasentinel.io/gitops-source=true 가 붙은 하위 앱들의
# repoURL · targetRevision 을 패치로 덮어쓴다(grafana는 2026-10-16부터 apps/에 없음 — kubernetes_manifest.grafana_app
# 참고). 시험 구역 · 도쿄 · 브랜치 미리보기는 변수만 바꾸면 된다.
# 예전엔 root 를 이 컴포넌트와 gitops bootstrap/root-app.yaml 두 곳에서 손으로 맞춰야 해서 뺐는데,
# 이번엔 root-app.yaml 을 지워 이 파일 하나만 원본으로 남긴다.
# root 에는 삭제 연쇄 설정(resources-finalizer)이 있어 지웠다 다시 만들면 하위 앱이 전부 지워졌다 다시 생긴다 —
# 이미 떠 있는 root 는 지우지 않고 가져온다(import, 서울만).
resource "kubernetes_manifest" "root_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "root"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = local.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = "apps"
        kustomize = {
          # 🔴 patches 를 concat 으로 쓰는 이유는 맨 끝 collector 패치 하나다 —
          # 그건 var.suspend_collectors 가 true 일 때만 **목록에 들어가야** 한다.
          # false 를 값으로 내려보내면 안 된다(아래 그 패치 주석 참고).
          patches = concat([
            {
              target = { kind = "Application", labelSelector = "aquasentinel.io/gitops-source=true" }
              patch = jsonencode([
                { op = "replace", path = "/spec/source/repoURL", value = local.gitops_repo_url },
                { op = "replace", path = "/spec/source/targetRevision", value = var.gitops_revision },
              ])
            },
            # 동기화 재시도를 apps/ 의 Application 전체에 얹는다(2026-10-19) —
            # 서울 root.tf 와 같은 패치다. 근거와 값은 main.tf 의
            # local.app_sync_retry 주석, labelSelector 를 일부러 안 거는 이유와
            # syncPolicy 전제는 서울 root.tf 주석 참고.
            {
              target = { kind = "Application" }
              patch = jsonencode([
                { op = "add", path = "/spec/syncPolicy/retry", value = local.app_sync_retry },
              ])
            },
            # 원천 저장소 버킷 — 버킷 이름에 계정 ID 가 들어 있어 환경마다 다르다(gitops root-app.yaml 의 같은 패치를 옮겨 옴)
            {
              target = { kind = "Application", name = "api-module-config" }
              patch = jsonencode([
                {
                  op   = "add"
                  path = "/spec/source/kustomize"
                  value = {
                    patches = [
                      {
                        target = { kind = "ConfigMap", name = "api-module-infra-config" }
                        patch = jsonencode([
                          { op = "replace", path = "/data/RAW_STORE_DSN", value = "s3://${data.terraform_remote_state.persistent.outputs.bucket_names["api_raw_store"]}/" },
                        ])
                      },
                    ]
                  }
                },
              ])
            },
            ],
            # ─────────────────────────────────────────────────────────────
            # 🔴 훈련 모드 — 도쿄 collector 를 멈춘 채로 띄운다.
            #
            # 왜 필요한지는 var.suspend_collectors 설명에 적었다(요지: 공공 API
            # 키가 서울과 같은 값이어서, 서울이 살아 있는 동안 같이 돌면 호출량이
            # 2배가 되고 운영 수집이 한도에 걸려 판정 #6·#7 이 깨진다).
            #
            # 🔴 false 를 **값으로 내려보내지 않고 패치 자체를 빼는** 이유:
            # target 이 CronJob 전체라 value=false 면 git 원본에서 의도적으로
            # suspend: true 로 둔 collector-bulletin-offseason 까지 깨운다
            # (비시즌 수집기가 시즌 중에 돌아 중복 수집이 된다 —
            # collector-bulletin.yaml 6행·61행 참고. 2026-10-22 kustomize
            # build 로 실제 재현했다). 패치를 빼면 git 값이 그대로 남아
            # offseason=true · 나머지=기본 false 가 된다.
            #
            # 그래서 실제 리전 장애 때는 -var suspend_collectors=false 로 주고
            # 승격한다(DR 페일오버 런북 단계) — 그 순간 이 패치가 목록에서
            # 사라지고 서울에서 쓰던 그대로의 스케줄이 도쿄에서 돈다.
            #
            # target 에 name 을 걸지 않는 이유: 이 Application 의 CronJob 6개가
            # 전부 공공 API 호출이고(collector-{tide,line,bulletin-season,
            # bulletin-offseason,fishery-watch,completeness} · 전부
            # api-module-collector-secrets 를 envFrom 으로 받는다), 나중에
            # collector 가 늘어도 자동으로 걸리게 하려는 것이다.
            # collector-fishery-backfill 은 kustomization.yaml 이 의도적으로
            # 제외한 수동 1회 Job 이라 Argo 가 배포하지 않는다 — 다만 공공 API
            # 키를 쓰므로 훈련 중 손으로 실행하면 안 된다.
            #
            # api-module-collector 는 apps/ 에 있는 Application 이라
            # (라벨 aquasentinel.io/gitops-source=true) patched_apps 가 아니라
            # 여기 root 패치로 다룬다 — patched_apps 에 같은 이름을 넣으면
            # Terraform 과 root 가 같은 Application 을 두 번 만들어 충돌한다.
            # ─────────────────────────────────────────────────────────────
            var.suspend_collectors ? [
              {
                target = { kind = "Application", name = "api-module-collector" }
                patch = jsonencode([
                  {
                    op   = "add"
                    path = "/spec/source/kustomize"
                    value = {
                      patches = [
                        {
                          target = { kind = "CronJob" }
                          patch = jsonencode([
                            # replace 가 아니라 add 다 — suspend 가 매니페스트에
                            # 적혀 있지 않은 CronJob 이 5개다(기본값 false 라
                            # 생략됨). replace 면 그쪽에서 패치가 실패한다.
                            # RFC 6902 의 add 는 이미 있으면 값을 바꾼다.
                            { op = "add", path = "/spec/suspend", value = true },
                          ])
                        },
                      ]
                    }
                  },
                ])
              },
          ] : [])
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
        retry       = local.app_sync_retry
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }

  # 지금 root 는 kubectl 로 적용돼 필드 소유자가 kubectl 이다 — 같은 값을 Terraform 이 넘겨받는다
  field_manager {
    force_conflicts = true
  }

  depends_on = [helm_release.argocd]
}
