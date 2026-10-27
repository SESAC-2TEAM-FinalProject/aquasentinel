#!/bin/bash
# 도쿄 GitLab Runner EC2 부트스트랩 — Docker executor.
# 로그는 /var/log/cloud-init-output.log(SSM Session Manager 로 조회).
#
# global/runner 의 user-data 와 같은 내용이다. 다른 점은 두 가지뿐이다.
#   ⑴ 토큰 시크릿이 도쿄 리전에 있다(region 이 ap-northeast-1 로 들어온다)
#   ⑵ 🔴 태그는 여기서 정하지 않는다 — 최신 GitLab 의 러너 인증 토큰은
#      "러너를 UI 에서 먼저 만들고" 받는 것이라 태그·Pause 가 토큰에 묶여 있다.
#      그래서 --tag-list 가 없다(서울 러너도 같다).
#      🔴 UI 에서 반드시 태그를 서울과 **같은** eks-self-hosted 로 주고
#      **Paused 로 생성**해야 한다. 이유는 아래.
#        · 같은 태그여야 재해 때 .gitlab-ci.yml 을 한 줄도 고치지 않고
#          tokyo/rebuild/* 수동 잡이 이 러너로 간다.
#        · 그런데 같은 태그로 켜 두면 평소에 서울 잡을 가로챈다. 🔴 Terraform
#          잡은 대체로 성공해 버려서(OIDC 인증 + 서울 EKS 공개 엔드포인트)
#          오히려 알아채기 어렵고, web·api-module 잡은 깨진다 — Kaniko 가
#          인스턴스 프로파일로 ECR push 하는데 이 러너 정책은 도쿄 ECR 로
#          좁혀져 있다(.gitlab-ci.yml:3-4 — 그 레포들도 같은 태그를 쓴다).
#        · Pause 가 그 둘을 동시에 만족시킨다 — 평소엔 잡을 받지 않고,
#          재해 때 Pause 만 풀면 즉시 받는다.
#
# privileged 는 서울 러너와 같이 true 다 — api-module 이 아직 docker:24-dind 를
# 쓰고 dind 는 privileged 가 필수다. 서울 쪽이 kaniko 로 넘어가면 같이 내린다.
set -euxo pipefail

dnf update -y
dnf install -y docker aws-cli
systemctl enable --now docker

curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | bash
dnf install -y gitlab-runner

RUNNER_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id "${token_secret_name}" \
  --region "${region}" \
  --query SecretString --output text)

gitlab-runner register \
  --non-interactive \
  --url "https://gitlab.com/" \
  --token "$RUNNER_TOKEN" \
  --executor "docker" \
  --docker-image "alpine:3.20" \
  --docker-privileged=true

# concurrent 는 register 가 기본값(1)으로 이미 써두는 최상위 키라, 줄을 추가하면
# TOML 키 중복으로 설정 파싱이 실패한다(서울 러너 첫 부팅에서 실제로 발생 —
# "Key 'concurrent' has already been defined"). 추가가 아니라 치환이어야 한다.
sed -i "s/^concurrent = .*/concurrent = ${concurrent}/" /etc/gitlab-runner/config.toml

systemctl enable --now gitlab-runner
