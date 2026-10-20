#!/usr/bin/env bash
# 도쿄 리전 DR 선행 조건 — Secrets Manager 공백 메우기 (2026-10-20)
#
# 왜 필요한가
#   도쿄 3-gitops 는 ClusterSecretStore 의 리전을 var.region(도쿄)로 패치한다.
#   즉 도쿄 클러스터의 ESO 는 **도쿄 Secrets Manager만** 읽고 서울 값을 못 본다.
#   2026-10-20 실측: 서울 19개 / 도쿄 8개 — 도쿄가 찾는데 없는 것이 9개였다.
#
#   그중 일부는 **값이 서울과 같아야 한다.** Keycloak 은 클라이언트 비밀값을
#   자기 DB 안에 저장하고, 리전 DR 은 서울 백업에서 DB 를 복구한다. DB 안
#   admin-cli-service 비밀값은 서울 값인데 오퍼레이터가 바로 그 자격증명으로
#   인증하므로, 값이 다르면 401 로 잠겨 아무 설정도 반영하지 못한다(SIM-09c).
#   공공 API 키 4개도 "발급받은 실제 키"라 같은 값이어야 한다.
#
#   그래서 그 6개는 **복제**(replicate-secret-to-regions)로 넣는다 — 이름과 값이
#   서울과 같게 유지되고 이후 서울에서 값을 바꾸면 자동으로 따라간다.
#   도쿄 3-gitops 가 그 ExternalSecret 들의 키를 **일부러 패치하지 않는** 이유가
#   이것이다(tokyo/rebuild/3-gitops/applications.tf 주석).
#
#   나머지 3개는 값이 달라도 되므로(오퍼레이터·CNPG 가 맞춰 준다) 도쿄 전용
#   이름으로 따로 만든다 — 이 스크립트는 **없는 것만 알려주고 만들지 않는다**
#   (알람 웹훅처럼 사람이 값을 정해야 하는 것이 섞여 있다).
#
# 쓰는 법
#   ./tokyo-secret-replication.sh              # 무엇이 없는지 보기만 (기본)
#   ./tokyo-secret-replication.sh --apply      # 복제 6개 설정
#
# 안전장치
#   - 운영 계정(379937169195)에서만 동작한다 — 시험 계정에서 돌리면 중단
#   - 기본이 dry-run
#   - 이미 복제된 시크릿은 건너뛴다
#   - 비밀값을 화면·로그에 찍지 않는다

set -euo pipefail

SEOUL=ap-northeast-2
TOKYO=ap-northeast-1
PROD_ACCOUNT=379937169195
APPLY=false

[[ "${1:-}" == "--apply" ]] && APPLY=true

# 서울에서 도쿄로 복제할 것 — 값이 서울과 같아야 하는 것들
REPLICATE=(
  "aquasentinel-dev-keycloak-admin-client-secret"
  "aquasentinel-dev-api-module-dtrecent-key"
  "aquasentinel-dev-api-module-nifs-key-bulletin"
  "aquasentinel-dev-api-module-nifs-key-fishery-sea"
  "aquasentinel-dev-api-module-nifs-key-line"
  "aquasentinel-dev-grafana-db-ro-password"
)

# 도쿄 전용으로 사람이 만들어야 하는 것 — 값이 달라도 된다
TOKYO_OWN=(
  "aquasentinel-dr-tokyo-grafana-oidc-client-secret|아무 32자 문자열. 오퍼레이터가 Keycloak DB 를 이 값으로 덮는다"
  "aquasentinel-dr-tokyo-alertmanager-receivers|서울과 같은 Discord 웹훅 JSON 을 권장(같은 채널로 모으려면)"
  "aquasentinel-dr-tokyo-argocd-notifications|〃"
)

acct=$(aws sts get-caller-identity --query Account --output text)
if [[ "$acct" != "$PROD_ACCOUNT" ]]; then
  echo "중단 — 운영 계정($PROD_ACCOUNT)에서만 돌립니다. 지금 계정: $acct" >&2
  exit 1
fi

echo "계정 $acct · 서울 $SEOUL → 도쿄 $TOKYO"
$APPLY && echo "모드: 실제 적용" || echo "모드: 계획만 (--apply 로 실행)"
echo

echo "## 복제 대상 ${#REPLICATE[@]}개 (값이 서울과 같아야 하는 것)"
for name in "${REPLICATE[@]}"; do
  printf '  %-52s ' "$name"

  if ! aws secretsmanager describe-secret --secret-id "$name" --region "$SEOUL" >/dev/null 2>&1; then
    echo "건너뜀 — 서울에 없음"
    continue
  fi

  # 이미 도쿄에 복제돼 있나
  if aws secretsmanager describe-secret --secret-id "$name" --region "$TOKYO" >/dev/null 2>&1; then
    echo "이미 있음"
    continue
  fi

  if ! $APPLY; then
    echo "복제 예정"
    continue
  fi

  if ERR=$(aws secretsmanager replicate-secret-to-regions \
      --secret-id "$name" \
      --region "$SEOUL" \
      --add-replica-regions "Region=$TOKYO" \
      --output text 2>&1 >/dev/null); then
    echo "복제함"
  else
    echo "실패"
    printf '      %s\n' "$ERR" | head -3
  fi
done

echo
echo "## 도쿄 전용으로 만들어야 하는 것 ${#TOKYO_OWN[@]}개 (이 스크립트는 만들지 않습니다)"
for row in "${TOKYO_OWN[@]}"; do
  name="${row%%|*}"; note="${row#*|}"
  printf '  %-52s ' "$name"
  if aws secretsmanager describe-secret --secret-id "$name" --region "$TOKYO" >/dev/null 2>&1; then
    echo "이미 있음"
  else
    echo "없음"
    printf '      → %s\n' "$note"
  fi
done

echo
echo "## 확인 — 도쿄 ExternalSecret 이 찾는 이름이 다 있는지"
echo "   aws secretsmanager list-secrets --region $TOKYO --query 'SecretList[].Name' --output text | tr '\\t' '\\n' | sort"
echo
echo "복제는 이름을 그대로 유지합니다. 도쿄 3-gitops 가 이 6개의 ExternalSecret 키를"
echo "일부러 패치하지 않는 이유가 그것입니다 — 패치를 추가하면 복제본을 못 찾습니다."
