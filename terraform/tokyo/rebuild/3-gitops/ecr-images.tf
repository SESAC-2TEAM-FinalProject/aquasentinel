# 도쿄 ECR 주소 전환 — gitops 매니페스트의 이미지 주소를 이 리전 것으로 바꿔 읽는다.
#
# 왜 필요한가
#   gitops `manifests/` 의 ECR 주소 21곳이 전부 `ap-northeast-2`(서울)로 적혀
#   있고, 리전으로 갈리는 장치가 없었다. 도쿄 root 는 서울과 **같은 `apps/`**
#   디렉터리를 읽으므로(root.tf 의 path = "apps") 도쿄를 띄우면 그 주소를 그대로
#   당긴다. 서울이 살아 있는 동안은 동작하지만, 서울 리전이 통째로 빠지는
#   시나리오에서는 서울 ECR 도 함께 빠지고 도쿄는 노드 0대에서 시작해 이미지
#   캐시가 없다 → 파드가 뜨지 못한다. **DR 2단계가 성립하지 않는다.**
#
# 방식(「도쿄 반영 목록」 #1 의 A 안)
#   gitops 를 고치지 않고, 도쿄 Terraform 이 Argo CD Application 의
#   `spec.source.kustomize.images` 에 치환 규칙을 주입한다. 서울 영향 0.
#   Argo CD 는 이 값을 검증 없이 `kustomize edit set image <값>` 으로 넘긴다.
#
#   형식은 `찾을이름=바꿀이름` 만 쓴다(태그 없이). kustomize 가 `newName` 만
#   바꾸고 **태그는 git 에 적힌 것을 그대로 둔다** — 태그는 CI 가 계속 올리므로
#   여기에 태그를 적으면 새 이미지가 나올 때마다 도쿄 코드를 손봐야 한다.
#   다이제스트 고정 이미지(egress-proxy)만 `=바꿀이름@sha256:…` 형식을 쓴다.
#
# 🔴 왼쪽(찾을 이름)은 gitops 에 적힌 문자열과 **한 글자도 달라선 안 된다.**
#   다르면 Kustomize 가 조용히 아무것도 바꾸지 않는다 — 오류 없이 서울 주소로
#   뜬다. 그래서 계정 ID 를 caller_identity 로 추론하지 않고 gitops 가 쓰는 값을
#   그대로 적고, 도쿄 주소는 거기서 **리전만** 치환해 만든다(계정은 같다).
#   gitops 쪽 주소가 바뀌면 여기도 바뀌어야 한다:
#     git grep -n 'dkr.ecr' gitlab/main -- manifests
locals {
  # gitops 매니페스트에 적힌 서울 레지스트리 — 위 주석의 이유로 리터럴이다.
  ecr_registry_seoul = "379937169195.dkr.ecr.ap-northeast-2.amazonaws.com"
  ecr_registry_tokyo = replace(local.ecr_registry_seoul, "ap-northeast-2", var.region)

  # 🔴 이미지 경로의 `aquasentinel-dev` 는 local.name_prefix 가 아니다.
  #   ECR 리포지토리 이름은 두 리전에서 같고(복제 필터가 `aquasentinel-dev`
  #   PREFIX_MATCH), 도쿄에서도 그 이름 그대로 복제돼 있다. name_prefix
  #   (= aquasentinel-dr-tokyo)를 쓰면 없는 리포지토리를 가리킨다.
  ecr_repo_ns = "aquasentinel-dev"

  # 리전만 바꾸는 치환 한 줄을 만든다.
  ecr_same_repo = {
    for repo in [
      "api-module/collector",
      "api-module/evaluation",
      "api-module/grading",
      "api-module/interpolation",
      "api-module/processor",
      "ocean-batch",
      "status-svc",
      "web-frontend",
      ] : repo => join("=", [
        "${local.ecr_registry_seoul}/${local.ecr_repo_ns}/${repo}",
        "${local.ecr_registry_tokyo}/${local.ecr_repo_ns}/${repo}",
    ])
  }

  # Application 이름 → Argo CD 에 넣을 images 목록.
  #
  # 치환은 **Application 단위**라, 같은 이미지를 쓰는 Application 이 여러 개면
  # 각각에 넣어야 한다 — `api-module/processor` 는 세 곳이 함께 쓴다
  # (processor · completeness-check · raw-coverage).
  #
  # 이미지가 0개인 Application 은 넣지 않는다(api-module-config 등).
  ecr_images = {
    "api-module-collector"          = [local.ecr_same_repo["api-module/collector"]]
    "api-module-completeness-check" = [local.ecr_same_repo["api-module/processor"]]
    "api-module-evaluation"         = [local.ecr_same_repo["api-module/evaluation"]]
    "api-module-grading"            = [local.ecr_same_repo["api-module/grading"]]
    "api-module-interpolation"      = [local.ecr_same_repo["api-module/interpolation"]]
    "api-module-processor"          = [local.ecr_same_repo["api-module/processor"]]
    "api-module-raw-coverage"       = [local.ecr_same_repo["api-module/processor"]]

    # egress-proxy 는 다이제스트로 고정돼 있다. 찾을 이름이 ECR 주소가 아니라
    # **원본 이미지 이름**인 것에 주의한다 — kustomization.yaml 의 images 항목이
    # `name: docker.io/ubuntu/squid` 로 적혀 있고, kustomize 는 그 name 으로
    # 항목을 찾는다. 다이제스트는 crane copy 로 옮겨 원본과 같은 값이라
    # 리전이 바뀌어도 그대로 쓴다(2026-10-15 인프라 확인).
    "egress-proxy" = [join("=", [
      "docker.io/ubuntu/squid",
      "${local.ecr_registry_tokyo}/${local.ecr_repo_ns}/egress-proxy@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029",
    ])]

    # web 은 apps/ 가 아니라 patched_apps 로 만든다(applications.tf) — 거기서
    # 이 항목을 lookup 한다. 🔴 쿠버네티스 객체 이름은 2026-10-26 에
    # status-svc → web-backend 로 바뀌었지만 **ECR 리포지토리 이름은
    # `status-svc` 그대로**다(실측). 이미지 이름을 같이 바꾸면 안 된다.
    "web" = [
      local.ecr_same_repo["ocean-batch"],
      local.ecr_same_repo["status-svc"],
      local.ecr_same_repo["web-frontend"],
    ]
  }

  # root 패치로 다룰 것 = apps/ 에 있는 Application. web 만 뺀다 — 그쪽은
  # patched_apps 다. collector 처럼 패치가 같이 붙는 Application 도 그냥 둔다 —
  # images 와 patches 를 합치는 일은 apps-kustomize.tf 가 한다.
  ecr_images_apps = {
    for app, imgs in local.ecr_images : app => imgs if app != "web"
  }

  # patched_apps(applications.tf)쪽에서 Application 이름으로 찾는다 — 없으면 빈 목록.
  #
  # 🔴 local.patched_apps 항목에 images 키를 직접 더하지 않는 이유: 그 map 을
  # for_each 가 쓰고, Terraform 은 map 원소의 타입이 모두 같기를 요구한다.
  # 일부 항목에만 키를 더하면 타입 통일이 깨져 apply 전에 막힌다.
  ecr_images_for = {
    for app in keys(local.patched_apps) : app => lookup(local.ecr_images, app, [])
  }
}
