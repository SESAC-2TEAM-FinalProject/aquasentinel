# apps/ 의 Argo CD Application 에 주입하는 kustomize 블록을 한 곳에서 만든다.
#
# 🔴 왜 한 곳에 모으나 — `/spec/source/kustomize` 는 Application 하나당 **한 번만**
# add 할 수 있다. 같은 경로를 두 번 add 하면 뒤가 앞을 덮는다. 전에는 이 경로를
# 세 군데(RAW_STORE_DSN · ECR 이미지 · collector suspend)에서 각자 add 했고,
# 겹치는 Application 을 손으로 빼 가며 피했다. 항목이 늘 때마다 같은 함정을 다시
# 밟게 되므로(2026-10-26 에 api-module 대기 패치를 더하면서 네 번째가 됐다)
# **Application 이름 → kustomize 블록** 하나로 합쳐서 root.tf 가 한 번만 add 한다.
#
# 들어가는 것
#   images   — ECR 리전 치환(ecr-images.tf)
#   patches  — 아래 세 묶음을 Application 별로 이어 붙인 것
locals {
  # ① 원천 저장소 버킷 — 버킷 이름에 계정 ID 가 들어 있어 환경마다 다르다
  #    (gitops 의 옛 root-app.yaml 에 있던 같은 패치를 옮겨 온 것).
  app_patches_config = {
    "api-module-config" = [
      {
        target = { kind = "ConfigMap", name = "api-module-infra-config" }
        patch = jsonencode([
          { op = "replace", path = "/data/RAW_STORE_DSN", value = "s3://${data.terraform_remote_state.persistent.outputs.bucket_names["api_raw_store"]}/" },
        ])
      },
    ]
  }

  # ② 훈련 모드 — 도쿄 collector 를 멈춘 채로 띄운다.
  #
  # 왜 필요한지는 var.suspend_collectors 설명에 적었다(요지: 공공 API 키가 서울과
  # 같은 값이어서, 서울이 살아 있는 동안 같이 돌면 호출량이 2배가 되고 운영 수집이
  # 한도에 걸려 판정 #6·#7 이 깨진다).
  #
  # 🔴 false 를 **값으로 내려보내지 않고 묶음 자체를 비우는** 이유: target 이
  # CronJob 전체라 value=false 면 git 원본에서 의도적으로 suspend: true 로 둔
  # collector-bulletin-offseason 까지 깨운다(비시즌 수집기가 시즌 중에 돌아 중복
  # 수집이 된다 — collector-bulletin.yaml 참고. 2026-10-22 kustomize build 로 실제
  # 재현했다). 패치를 빼면 git 값이 그대로 남아 offseason=true · 나머지=기본
  # false 가 된다.
  #
  # target 에 name 을 걸지 않는 이유: 이 Application 의 CronJob 6개가 전부 공공
  # API 호출이고, 나중에 collector 가 늘어도 자동으로 걸리게 하려는 것이다.
  # collector-fishery-backfill 은 kustomization.yaml 이 의도적으로 제외한 수동 1회
  # Job 이라 Argo 가 배포하지 않는다 — 다만 공공 API 키를 쓰므로 훈련 중 손으로
  # 실행하면 안 된다.
  app_patches_suspend_collectors = var.suspend_collectors ? {
    "api-module-collector" = [
      {
        target = { kind = "CronJob" }
        patch = jsonencode([
          # replace 가 아니라 add 다 — suspend 가 매니페스트에 적혀 있지 않은
          # CronJob 이 5개다(기본값 false 라 생략됨). replace 면 그쪽에서 패치가
          # 실패한다. RFC 6902 의 add 는 이미 있으면 값을 바꾼다.
          { op = "add", path = "/spec/suspend", value = true },
        ])
      },
    ]
  } : {}

  # ③ 대기 모드 — api-module 가공·판정을 꺼 둔다(결정 ③ · 2026-10-26).
  #
  # 끄는 이유가 Keycloak·web-backend 와 **같다**: 도쿄 CNPG 는 Replica Cluster 라
  # `transaction_read_only = on` 이고, 이 워크로드들은 결과를 DB 에 쓴다 — 읽기
  # 전용 위에서는 **구조적으로 못 돈다.** 2026-10-25 실측에서 파드 11개가
  # CrashLoop 이고 Application 5개가 Progressing 으로 남았다.
  #
  # 🔴 **전환(dr_mode=active) 때는 이 묶음이 빠져서 깨어난다. 그래야 한다** —
  # DR 복구 완료의 기준이 "해양 데이터가 다시 신선해지는 것"이고 그걸 되살리는
  # 주체가 바로 이 워크로드들이다. 끄는 것은 **훈련 전용**이다.
  #
  # 손대지 않는 것
  #   - api-module-raw-coverage: 읽기만 해서 Replica 에서도 정상 완료한다
  #     (2026-10-25 실측 Complete). 판정 근거를 만드는 도구라 그대로 둔다.
  #   - Deployment 쪽 여분 파드: Rollout 이 workloadRef 로 참조하는 Deployment 가
  #     파드를 1개 남기는 알려진 문제가 따로 있다(Argo Rollouts 의 revision==1
  #     게이트 한계). 여기서 Deployment 까지 0 으로 패치하면 Rollouts 컨트롤러와
  #     Argo CD selfHeal 이 서로 되돌리는 싸움이 될 수 있어 건드리지 않는다.
  # 🟢 2026-10-28 해결 — 원인은 **「패치 키가 사라지는 것」**이었다(아래 app_kustomize)
  #
  # 증상: dr_mode=active 로 apply 하면 root Application 의 live 값은 올바르게
  # 바뀌는데(해당 앱 패치가 {images} 만 남음) **자식** Application
  # (api-module-evaluation 등)이 standby 패치 3건을 그대로 들고 `Synced`/`Healthy`
  # 로 판정된다. 결과로 Rollout 4개가 replicas=0 · ScaledObject 0개로 남아 **DR
  # 전환이 완료되지 않는다**(훈련 1부 6단계). 우회 3종 전부 실패: 대기 7분 ·
  # `argocd.argoproj.io/refresh=hard` · application-controller 재시작 5분.
  #
  # 원인: active 모드에서 `patches` **키 자체가 없어졌다.** 키가 없으면 Argo 가
  # 만드는 자식 매니페스트에 그 필드가 아예 안 들어가고, Argo 의 diff 는 그것을
  # 「지워야 할 필드」로 보지 않는다 — live 에 남은 옛 patches 를 그대로 둔 채
  # `Synced` 로 판정한다(`argocd app diff root` 가 **0줄 · exit 0** 실측).
  #
  # 수정: active 에서도 키를 남긴다 — `patches = []`. `[3건] → []` 라는 **값의
  # 변화**가 되어 diff 에 잡힌다. 아래 app_kustomize 참고.
  #
  # 실측(같은 날 도쿄 재구축 클러스터 · 막힌 Argo 작업 없는 상태)
  #   10:01:13Z  terraform apply -var dr_mode=active  → 0 added, 4 changed
  #   10:02:07Z  자식 patches 3건 → 0건
  #   10:02:25Z  Rollout replicas 복원(evaluation 1 · grading 2 · interpolation 2 ·
  #              processor 2 = 서울과 동일) · ScaledObject 4개 Ready=True
  #   ⇒ 손 작업 없이 **72초.** 공공 API 수집기 6개는 suspend=true 로 남았다(의도).
  #
  # 🔴 같이 배운 것 — Argo 는 `status.operationState.phase=Running` 인 동안 새
  # 동기화를 **시작하지 않는다.** 내가 `argocd app sync root --force` 로 만든 멈춘
  # 작업 하나가 16분간 모든 전파를 막아 이 수정이 「실패」로 보였다. 당일 무엇도
  # 판정하기 전에 root 의 op phase 를 먼저 본다(런북 1장 ② 의 사전 점검).
  # 리허설 때의 op phase 는 기록하지 않아 그때도 멈춘 작업이 있었는지는 확인할 수
  # 없다. 다만 「키 삭제는 diff 가 아니다」는 위 diff 0줄로 따로 확인됐으므로 이
  # 수정은 어느 쪽이든 필요하다.
  app_patches_dr_standby = local.dr_standby ? {
    # Rollout 이 없는 평범한 Deployment — 매니페스트에 replicas: 1 이 있어 replace.
    "api-module-completeness-check" = [
      {
        target = { kind = "Deployment", name = "completeness-check" }
        patch = jsonencode([
          { op = "replace", path = "/spec/replicas", value = 0 },
        ])
      },
    ]

    # 아래 넷은 Rollout + KEDA ScaledObject 조합이라 web-backend 와 같은 방식이다.
    # 🔴 ScaledObject 를 함께 지워야 한다 — replicas 만 0 으로 바꾸면 KEDA 가 만든
    # HPA 가 곧바로 되돌린다(지표를 못 읽어도 fallback 이 있다). 🔴 `op = "add"` 인
    # 이유는 Rollout 매니페스트에 spec.replicas 가 **없기** 때문이다(KEDA 가 쥐고
    # 있어서) — 경로가 없으면 replace 는 실패한다.
    # 🔴 이름을 리터럴로 네 번 펼쳐 적는다(for 로 만들지 않는다) —
    # scripts/check-tokyo-patch-targets.py 가 `name = "..."` 를 읽어 gitops 에
    # 실재하는지 대조하기 때문이다. 2026-10-26 에 똑같은 패치가 이름 변경으로
    # 조용히 풀린 사고가 있었다(status-svc → web-backend) — 재발을 코드로
    # 막으려면 체커가 볼 수 있어야 한다. 중복보다 검증 가능성이 우선이다.
    "api-module-processor" = [
      {
        target = { kind = "Rollout", name = "processor" }
        patch = jsonencode([
          { op = "add", path = "/spec/replicas", value = 0 },
        ])
      },
      {
        # 리소스 **자체를 없애는** 패치라 JSON Patch 가 아니라 strategic merge 의
        # `$patch: delete` 를 쓴다 — JSON Patch 로는 필드만 지울 수 있다.
        target = { kind = "ScaledObject", name = "processor" }
        patch  = <<-EOT
          apiVersion: keda.sh/v1alpha1
          kind: ScaledObject
          metadata:
            name: processor
            namespace: api-module
          $patch: delete
        EOT
      },
    ]
    "api-module-grading" = [
      {
        target = { kind = "Rollout", name = "grading" }
        patch = jsonencode([
          { op = "add", path = "/spec/replicas", value = 0 },
        ])
      },
      {
        # 리소스 **자체를 없애는** 패치라 JSON Patch 가 아니라 strategic merge 의
        # `$patch: delete` 를 쓴다 — JSON Patch 로는 필드만 지울 수 있다.
        target = { kind = "ScaledObject", name = "grading" }
        patch  = <<-EOT
          apiVersion: keda.sh/v1alpha1
          kind: ScaledObject
          metadata:
            name: grading
            namespace: api-module
          $patch: delete
        EOT
      },
    ]
    "api-module-interpolation" = [
      {
        target = { kind = "Rollout", name = "interpolation" }
        patch = jsonencode([
          { op = "add", path = "/spec/replicas", value = 0 },
        ])
      },
      {
        # 리소스 **자체를 없애는** 패치라 JSON Patch 가 아니라 strategic merge 의
        # `$patch: delete` 를 쓴다 — JSON Patch 로는 필드만 지울 수 있다.
        target = { kind = "ScaledObject", name = "interpolation" }
        patch  = <<-EOT
          apiVersion: keda.sh/v1alpha1
          kind: ScaledObject
          metadata:
            name: interpolation
            namespace: api-module
          $patch: delete
        EOT
      },
      {
        # 하루 1회 보정 재시도 — 결과를 쓰므로 Replica 에서 실패한다
        target = { kind = "CronJob", name = "interpolation-error" }
        patch = jsonencode([
          { op = "add", path = "/spec/suspend", value = true },
        ])
      },
    ]
    "api-module-evaluation" = [
      {
        target = { kind = "Rollout", name = "evaluation" }
        patch = jsonencode([
          { op = "add", path = "/spec/replicas", value = 0 },
        ])
      },
      {
        # 리소스 **자체를 없애는** 패치라 JSON Patch 가 아니라 strategic merge 의
        # `$patch: delete` 를 쓴다 — JSON Patch 로는 필드만 지울 수 있다.
        target = { kind = "ScaledObject", name = "evaluation" }
        patch  = <<-EOT
          apiVersion: keda.sh/v1alpha1
          kind: ScaledObject
          metadata:
            name: evaluation
            namespace: api-module
          $patch: delete
        EOT
      },
      {
        # 10분마다 돌며 실패 Job 을 남긴다(2026-10-25 실측 · 누적은 failedJobsHistoryLimit=1 로 막힘)
        target = { kind = "CronJob", name = "evaluation-sweep" }
        patch = jsonencode([
          { op = "add", path = "/spec/suspend", value = true },
        ])
      },
    ]
  } : {}

  # Application 별로 위 세 묶음을 이어 붙인다.
  app_patches = {
    for app in distinct(concat(
      keys(local.app_patches_config),
      keys(local.app_patches_suspend_collectors),
      keys(local.app_patches_dr_standby),
      )) : app => concat(
      # 🔴 lookup(m, app, []) 을 쓰면 안 된다 — 단일 원소 맵의 값 타입이 「길이 1
      # 튜플」로 굳어서 기본값 `[]` 가 타입이 안 맞는다고 거부된다(2026-10-26 에
      # 실제로 당했다. terraform validate 는 통과하고 평가 단계에서 터진다).
      contains(keys(local.app_patches_config), app) ? local.app_patches_config[app] : [],
      contains(keys(local.app_patches_suspend_collectors), app) ? local.app_patches_suspend_collectors[app] : [],
      contains(keys(local.app_patches_dr_standby), app) ? local.app_patches_dr_standby[app] : [],
    )
  }

  # 최종 — Application 이름 → kustomize 블록. root.tf 가 이것만 보고 한 번 add 한다.
  # 둘 중 하나만 있는 Application 도 있으므로(api-module-config 는 이미지가 0개,
  # egress-proxy 는 패치가 0개) 있는 것만 넣는다.
  app_kustomize = {
    for app in distinct(concat(keys(local.ecr_images_apps), keys(local.app_patches))) :
    app => merge(
      contains(keys(local.ecr_images_apps), app) ? { images = local.ecr_images_apps[app] } : {},
      # 🔴 2026-10-28 — 패치가 0개여도 **키를 남긴다**(`patches = []`).
      #
      # 전에는 `contains(...) ? {patches=...} : {}` 라 `dr_mode=active` 때 그
      # 앱에서 **patches 키 자체가 사라졌다.** 그런데 Argo 의 diff 가 「키 삭제」를
      # 차이로 잡지 않아, 자식 Application 에 옛 패치가 남은 채 `Synced` 로
      # 판정됐다(10/28 도쿄 실측 — `argocd app diff root` 가 **0줄 · exit 0**,
      # `last-applied-configuration` 은 옛 patches 그대로 = 한 번도 안 밀었다).
      # 결과로 Rollout 4개가 replicas=0 · ScaledObject 0개로 남아 **DR 전환이
      # 완료되지 않았다**(훈련 1부 6단계).
      #
      # 키를 남기면 `patches: [3건] → patches: []` 라는 **값의 변화**가 되어 diff 에
      # 잡힌다 — 같은 날 도쿄에서 실측 확인했다(10:01:13Z apply → 10:02:25Z 깨어남,
      # 손 작업 없이 72초). 자세한 경위는 위 app_patches_dr_standby 주석.
      { patches = contains(keys(local.app_patches), app) ? local.app_patches[app] : [] },
    )
  }
}
