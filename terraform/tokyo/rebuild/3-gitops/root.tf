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
