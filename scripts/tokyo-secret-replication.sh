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
#   나머지 3개는 **이름이 달라야** 한다 — 도쿄 3-gitops 가 ExternalSecret 의 키를
#   `aquasentinel-dr-tokyo-*` 로 패치하기 때문이다. 이름이 같은 복제본으로는
#   그 이름이 생기지 않아 안 된다. 그래서 도쿄에서 따로 만든다.
#
#   🔴 **값은 서울과 같게 한다**(2026-10-26 결정 — 백업 후 복구 방식 기준).
#   전에는 *"값이 달라도 된다(오퍼레이터가 맞춰 준다)"* 고 적어 뒀는데, 그건
#   **전환 중에 할 일을 하나 늘린다**. 백업 후 복구에서 도쿄 Keycloak DB 는
#   서울 백업의 복구본이므로, 서울과 같은 값이면 복구 직후 이미 맞고 오퍼레이터가
#   바꿀 것이 없다. 다른 값이면 "Keycloak 기동 → 오퍼레이터 리콘실 성공" 이라는
#   의존이 장애 한가운데 하나 더 붙는다.
#
# 쓰는 법
#   ./tokyo-secret-replication.sh              # 무엇이 없는지 보기만 (기본)
#   ./tokyo-secret-replication.sh --apply      # 복제 6개 설정
#   ./tokyo-secret-replication.sh --apply-own  # 도쿄 전용 2개 생성(서울 값 복사)
#   ./tokyo-secret-replication.sh --apply-own --deadman-url https://hc-ping.com/<도쿄체크>
#                                              # 3개 전부 — alertmanager 는 deadman 만 교체
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
APPLY_OWN=false
DEADMAN_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --apply-own) APPLY_OWN=true; shift ;;
    --deadman-url) DEADMAN_URL="${2:-}"; shift 2 ;;
    *) echo "모르는 옵션: $1 (--apply | --apply-own [--deadman-url URL])" >&2; exit 2 ;;
  esac
done

if [[ -n "$DEADMAN_URL" && "$DEADMAN_URL" != https://* ]]; then
  echo "중단 — --deadman-url 은 https:// 로 시작해야 합니다" >&2
  exit 2
fi

# 서울에서 도쿄로 복제할 것 — 값이 서울과 같아야 하는 것들
REPLICATE=(
  "aquasentinel-dev-keycloak-admin-client-secret"
  "aquasentinel-dev-api-module-dtrecent-key"
  "aquasentinel-dev-api-module-nifs-key-bulletin"
  "aquasentinel-dev-api-module-nifs-key-fishery-sea"
  "aquasentinel-dev-api-module-nifs-key-line"
  "aquasentinel-dev-grafana-db-ro-password"
)

# 도쿄 전용 이름으로 만들 것 — 값은 서울 원본을 그대로 복사한다.
# 형식: 도쿄이름|서울원본|설명
TOKYO_OWN=(
  "aquasentinel-dr-tokyo-grafana-oidc-client-secret|aquasentinel-dev-grafana-oidc-client-secret|Grafana OIDC 클라이언트 비밀값. 서울 값이면 복구된 Keycloak DB 와 바로 일치한다"
  "aquasentinel-dr-tokyo-alertmanager-receivers|aquasentinel-dev-alertmanager-receivers|Discord·데드맨 수신처 JSON(키 critical·warning·deadman). 🔴 deadman 은 --deadman-url 로 받은 도쿄 전용 주소로 교체한다"
  "aquasentinel-dr-tokyo-argocd-notifications|aquasentinel-dev-argocd-notifications|Argo CD 알림 수신처"
)

# alertmanager-receivers — 세 키 critical·warning·deadman (JSON 하나)
# 근거: manifests/alerting/secret/external-secret.yaml · routing/alertmanagerconfig.yaml
#
#   ⑴ ✅ critical·warning(Discord): 같은 값으로 간다 — 서울·도쿄가 같은 채널로 쏘고,
#      어느 쪽이 울렸는지는 **경보의 리전 라벨**로 가린다. 도쿄 Prometheus
#      `externalLabels`(region·cluster)를 2026-10-26 에 넣었다(브랜치
#      feat/tokyo-prometheus-region-labels-20261026). 🔴 서울은 창 뒤에 맞춘다 —
#      지금 넣으면 Prometheus 재시작 공백이 판정 측정에 들어간다.
#
#   ⑵ 🔴 deadman(Healthchecks.io): **도쿄 전용 체크를 쓴다** — 2026-10-26 재희님 결정.
#      서울 값을 그대로 복사하면 도쿄가 서울의 데드맨을 대신 채워서, 도쿄가 떠 있는
#      동안 서울이 죽어도 핑이 계속 가고 **안 울린다.** gitops 쪽 주석도 처음부터
#      그렇게 적어 두었다("데드맨 핑 URL은 리전·계정마다 다른 체크여야 한다").
#      → 그래서 이 스크립트는 `--deadman-url` 없이는 이 시크릿을 **만들지 않는다.**
#      주소는 재희님이 Healthchecks.io 에 도쿄용 체크를 만들어 주신다.
#
#   ⑶ 키가 하나라도 없으면 오퍼레이터가 AlertmanagerConfig **CR 전체를 거부**해
#      Alertmanager 가 기본값(null)으로 돌아간다(그 매니페스트 주석). 즉 지금
#      도쿄는 "알림 2개가 Degraded" 가 아니라 **알림 경로가 전부 죽어 있다.**

acct=$(aws sts get-caller-identity --query Account --output text)
if [[ "$acct" != "$PROD_ACCOUNT" ]]; then
  echo "중단 — 운영 계정($PROD_ACCOUNT)에서만 돌립니다. 지금 계정: $acct" >&2
  exit 1
fi

echo "계정 $acct · 서울 $SEOUL → 도쿄 $TOKYO"
if $APPLY; then echo "모드: 복제 6개 실제 적용"
elif $APPLY_OWN; then echo "모드: 도쿄 전용 3개 실제 생성"
else echo "모드: 계획만 (--apply | --apply-own 로 실행)"; fi
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
echo "## 도쿄 전용 ${#TOKYO_OWN[@]}개 (이름은 도쿄 것 · 값은 서울 원본 복사 · deadman 은 교체)"

# 값을 argv 로 넘기지 않는다(ps 에 보인다) — 권한 0600 임시 파일로 건넨다.
tmp=""
# 🔴 return 0 이 필요하다. `[[ ]] && rm` 형태면 조건이 거짓일 때(= 계획 모드처럼
# 임시 파일을 안 만든 경우) 함수가 1 을 반환하고, `set -e` 아래의 EXIT 트랩에서는
# 그것이 **스크립트 종료코드**가 된다. 그러면 `스크립트 && 다음작업` 체인이
# 조용히 끊긴다(2026-10-26 실측 — 계획 모드가 정상 완료인데 1 을 반환했다).
cleanup() { if [[ -n "$tmp" && -f "$tmp" ]]; then rm -f "$tmp"; fi; return 0; }
trap cleanup EXIT

for row in "${TOKYO_OWN[@]}"; do
  name="${row%%|*}"; rest="${row#*|}"; src="${rest%%|*}"; note="${rest#*|}"
  printf '  %-52s ' "$name"

  if aws secretsmanager describe-secret --secret-id "$name" --region "$TOKYO" >/dev/null 2>&1; then
    echo "이미 있음 — 건너뜀(값은 덮지 않습니다)"
    continue
  fi

  if ! aws secretsmanager describe-secret --secret-id "$src" --region "$SEOUL" >/dev/null 2>&1; then
    echo "중단 — 서울 원본이 없음($src)"
    continue
  fi

  # 🔴 데드맨만 도쿄 전용 값이어야 한다(위 ⑵) — 주소가 없으면 만들지 않는다.
  needs_deadman=false
  [[ "$name" == *alertmanager-receivers ]] && needs_deadman=true

  if $needs_deadman && [[ -z "$DEADMAN_URL" ]]; then
    echo "건너뜀 — --deadman-url 이 필요합니다"
    printf '      → 서울 값을 그대로 복사하면 도쿄가 서울 데드맨을 대신 채워\n'
    printf '        「서울이 죽었다」가 가려집니다(2026-10-26 재희님 결정: 도쿄 전용 체크).\n'
    printf '        재희님이 주시는 Healthchecks.io 도쿄 체크 주소로 다시 돌리십시오:\n'
    printf '          %s --apply-own --deadman-url https://hc-ping.com/<도쿄체크>\n' "$(basename "$0")"
    continue
  fi

  if ! $APPLY_OWN; then
    if $needs_deadman; then
      echo "생성 예정 ← $src (deadman 만 --deadman-url 값으로 교체)"
    else
      echo "생성 예정 ← $src"
    fi
    printf '      → %s\n' "$note"
    continue
  fi

  # 서울 값을 받아 임시 파일에 넣는다 — 화면·로그에 찍지 않는다
  tmp=$(mktemp); chmod 600 "$tmp"
  if ! aws secretsmanager get-secret-value --secret-id "$src" --region "$SEOUL" \
      --query SecretString --output text > "$tmp" 2>/dev/null; then
    echo "실패 — 서울 값을 읽지 못했습니다"
    rm -f "$tmp"; tmp=""
    continue
  fi
  if [[ ! -s "$tmp" ]]; then
    echo "실패 — 서울 값이 비어 있습니다"
    rm -f "$tmp"; tmp=""
    continue
  fi

  # 🔴 deadman 키만 도쿄 전용 주소로 바꾼다. sed 가 아니라 JSON 파서로 하는 이유 —
  # 웹훅 URL 에 / 와 ? 가 들어 있어 구분자 충돌이 나고, 조용히 깨진 JSON 을 넣으면
  # 오퍼레이터가 CR 전체를 거부한다(위 ⑶). 값은 출력하지 않는다.
  if $needs_deadman; then
    if ! DEADMAN_URL="$DEADMAN_URL" python3 - "$tmp" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    raw = f.read()
try:
    obj = json.loads(raw)
except json.JSONDecodeError as e:
    sys.exit("서울 값이 JSON 이 아닙니다: %s" % e)
if not isinstance(obj, dict):
    sys.exit("서울 값이 JSON 객체가 아닙니다")
missing = [k for k in ("critical", "warning", "deadman") if k not in obj]
if missing:
    # 지금 고치지 않으면 도쿄에서 CR 전체가 거부된다 — 여기서 멈추는 쪽이 낫다.
    sys.exit("서울 값에 키가 없습니다: %s" % ", ".join(missing))
obj["deadman"] = os.environ["DEADMAN_URL"]
with open(path, "w") as f:
    json.dump(obj, f, ensure_ascii=False)
PYEOF
    then
      echo "실패 — deadman 교체 중 중단(위 메시지 참고)"
      rm -f "$tmp"; tmp=""
      continue
    fi
  fi

  if ERR=$(aws secretsmanager create-secret \
      --name "$name" \
      --region "$TOKYO" \
      --description "도쿄 DR 전용 — $src 값 복사$($needs_deadman && echo " · deadman 은 도쿄 전용")(2026-10-26)" \
      --secret-string "file://$tmp" \
      --output text 2>&1 >/dev/null); then
    echo "만들었습니다 ← $src"
  else
    echo "실패"
    printf '      %s\n' "$ERR" | head -3
  fi
  rm -f "$tmp"; tmp=""
done

echo
echo "## 확인 — 도쿄 ExternalSecret 이 찾는 이름이 다 있는지"
echo "   aws secretsmanager list-secrets --region $TOKYO --query 'SecretList[].Name' --output text | tr '\\t' '\\n' | sort"
echo
echo "복제는 이름을 그대로 유지합니다. 도쿄 3-gitops 가 이 6개의 ExternalSecret 키를"
echo "일부러 패치하지 않는 이유가 그것입니다 — 패치를 추가하면 복제본을 못 찾습니다."
