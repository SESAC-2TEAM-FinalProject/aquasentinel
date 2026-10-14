#!/bin/bash
# GitLab Runner EC2 부트스트랩 — Docker executor.
# 로그는 /var/log/cloud-init-output.log(SSM으로 조회).
#
# privileged는 기존 클러스터 내부 러너와 동일하게 true로 둔다(2026-10-14).
# 원래 계획은 "EC2에서는 DinD가 필요 없으니 false"였는데, 실제 레포를 확인해
# 보니 web(app)은 kaniko로 전환 완료라 false로도 되지만 **api-module이 아직
# docker:24-dind를 쓴다** — dind는 privileged가 필수라 false로 두면 그 레포
# CI가 깨진다. 마이그레이션은 동작을 보존하는 게 우선이라(실행 위치 이전과
# 빌드 방식 변경을 동시에 하면 장애 원인 분간이 안 됨), api-module이 kaniko로
# 넘어온 뒤에 false로 내린다.
set -euxo pipefail

dnf update -y
dnf install -y docker aws-cli
systemctl enable --now docker

curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | bash
dnf install -y gitlab-runner

# 등록 토큰은 AWS Secrets Manager에서 가져온다(평문을 user-data/git에 남기지
# 않기 위함 — PAT 유출 사고 교훈과 같은 이유). 시크릿 자체는 GitLab UI에서
# 발급한 뒤 AWS CLI로 미리 넣어둬야 한다(이 컴포넌트가 만들지 않음 — 다른
# 모든 시크릿과 동일한 수동 관리 패턴).
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

# concurrent는 register가 기본값(1)으로 이미 써두는 최상위 설정이라, 줄을
# 추가하면 TOML 키 중복으로 설정 파싱 자체가 실패한다(2026-10-14 첫 부팅에서
# 실제로 발생 — "Key 'concurrent' has already been defined"). 추가가 아니라
# 치환해야 한다.
sed -i "s/^concurrent = .*/concurrent = ${concurrent}/" /etc/gitlab-runner/config.toml

systemctl enable --now gitlab-runner
