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
          patches = [
            {
              target = { kind = "Application", labelSelector = "aquasentinel.io/gitops-source=true" }
              patch = jsonencode([
                { op = "replace", path = "/spec/source/repoURL", value = local.gitops_repo_url },
                { op = "replace", path = "/spec/source/targetRevision", value = var.gitops_revision },
              ])
            },
            # 동기화 재시도를 apps/ 의 Application 전체에 얹는다(2026-10-19) —
            # 부트스트랩에서 "남의 CRD"를 쓰는 앱이 먼저 동기화되면 Argo CD 가
            # Failed 에서 멈추고 같은 리비전을 다시 시도하지 않는다. 근거와 값은
            # main.tf 의 local.app_sync_retry 주석 참고.
            #
            # labelSelector 를 **일부러 걸지 않는다** — gitops-source 라벨이 붙은
            # 14개만 덮으면 argo-rollouts·external-secrets 처럼 라벨 없는 앱이
            # 빠지는데, 그 둘도 PodMonitor(monitoring.coreos.com)를 들고 있어 같은
            # 자리에서 멈춘다. 지금 apps/ 의 Application 25개는 **전부**
            # syncPolicy 를 갖고 있어 add 가 안전하다(2026-10-19 전수 확인).
            #
            # ⚠️ apps/ 에 Application 을 새로 추가할 때 `syncPolicy` 를 빠뜨리면
            # 이 JSON Patch 의 add 대상 부모가 없어 **root 동기화가 깨진다.**
            # apps/ 의 Application 은 반드시 syncPolicy 를 갖는다(기존 관례).
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
          ]
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

# (10-14 서울 root 는 import 블록으로 state 에 가져왔고, 끝난 뒤 블록을 지웠다 — 남겨 두면 root 가 없는
#  새 클러스터(재구축 · 시험 구역)에서 "가져올 대상이 없다"로 plan 이 실패한다.)
