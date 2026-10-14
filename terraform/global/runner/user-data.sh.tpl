#!/bin/bash
# GitLab Runner EC2 부트스트랩 — Docker executor(호스트 Docker 직접 사용,
# DinD 불필요 — 클러스터 내부 Kubernetes executor 때와 달리 privileged=false로
# 충분하다). 로그는 /var/log/cloud-init-output.log(SSM으로 조회).
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
  --docker-privileged=false

# concurrent는 register가 안 건드리는 최상위 설정이라 별도로 주입한다.
sed -i "1i concurrent = ${concurrent}" /etc/gitlab-runner/config.toml

systemctl enable --now gitlab-runner
