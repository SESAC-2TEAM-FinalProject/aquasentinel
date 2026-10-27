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
#   ./tokyo-secret-replication.sh --apply-own  # 도쿄 전용 3개 생성
#
#   # 🔴 값은 전부 환경변수로 넘긴다 — argv 는 ps 에 보이고 셸 이력에도 남는다.
#   TOKYO_CRITICAL_WEBHOOK='https://discord.com/api/webhooks/…' \
#   TOKYO_WARNING_WEBHOOK='https://discord.com/api/webhooks/…'  \
#   TOKYO_ARGOCD_WEBHOOK='https://discord.com/api/webhooks/…'   \
#   TOKYO_DEADMAN_URL='https://hc-ping.com/<도쿄체크>'          \
#       ./tokyo-secret-replication.sh --apply-own
#
#   넷 다 **필수**다(2026-10-27 재희님 지시 — 알림 수신처는 전부 도쿄 전용).
#   하나라도 없으면 그 시크릿을 **만들지 않고 건너뛴다** — 서울 웹훅이 도쿄로
#   조용히 복사되는 쪽이 훨씬 나쁘기 때문이다. 같은 수신처를 공유하면 도쿄가
#   보낸 핑·알림이 「서울이 죽었다」를 가린다.
#
#   🔸 grafana-oidc-client-secret 은 기본이 **서울 값 복사**다(2026-10-26 결정,
#      위 주석). 도쿄 전용 값으로 가기로 바뀌면 그때만 아래를 더한다:
#        TOKYO_GRAFANA_OIDC_SECRET='<새 값>'
#      🔴 그 경우 훈련 중 Grafana 로그인이 안 된다 — 도쿄 Grafana 가 훈련
#      중에는 서울 Keycloak 을 보기 때문이다(2026-10-27 실측).
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
# 환경변수 쪽이 기본이다 — argv 는 ps 에 보인다(아래 --deadman-url 주석).
DEADMAN_URL="${TOKYO_DEADMAN_URL:-}"
# 🔴 2026-10-27 추가 — 알림 수신처를 전부 도쿄 전용으로(재희님 지시).
CRITICAL_WEBHOOK="${TOKYO_CRITICAL_WEBHOOK:-}"
WARNING_WEBHOOK="${TOKYO_WARNING_WEBHOOK:-}"
ARGOCD_WEBHOOK="${TOKYO_ARGOCD_WEBHOOK:-}"
# 🔸 선택 — 비우면 서울 값 복사(2026-10-26 결정).
GRAFANA_OIDC_SECRET="${TOKYO_GRAFANA_OIDC_SECRET:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --apply-own) APPLY_OWN=true; shift ;;
    --deadman-url)
      # 🔴 argv 는 ps 에 보인다. 아래 환경변수 쪽을 쓰는 것이 맞고, 이 플래그는
      # 남겨 두되 경고한다 — 이 스크립트는 다른 비밀값은 이미 argv 를 피하고 있다
      # (0600 임시 파일 경유, 152행 주석). 알람 README 도 "키와 UUID는 git·채팅·
      # 로그에 남기지 않는다" 로 같은 규칙을 적고 있다.
      DEADMAN_URL="${2:-}"
      echo "  ⚠️ --deadman-url 은 ps 에 노출됩니다. TOKYO_DEADMAN_URL 환경변수를 쓰십시오:" >&2
      echo "       TOKYO_DEADMAN_URL='<주소>' $(basename "$0") --apply-own" >&2
      shift 2 ;;
    *) echo "모르는 옵션: $1 (--apply | --apply-own · 데드맨은 TOKYO_DEADMAN_URL)" >&2; exit 2 ;;
  esac
done

# 넷 다 https 여야 한다. 오타를 여기서 잡지 못하면 CR 이 조용히 거부된다.
for _pair in "데드맨 주소:$DEADMAN_URL" "critical 웹훅:$CRITICAL_WEBHOOK" \
             "warning 웹훅:$WARNING_WEBHOOK" "argocd 웹훅:$ARGOCD_WEBHOOK"; do
  _label="${_pair%%:*}"; _val="${_pair#*:}"
  if [[ -n "$_val" && "$_val" != https://* ]]; then
    echo "중단 — $_label 는 https:// 로 시작해야 합니다" >&2
    exit 2
  fi
done
unset _pair _label _val

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
  "aquasentinel-dr-tokyo-alertmanager-receivers|aquasentinel-dev-alertmanager-receivers|Discord·데드맨 수신처 JSON(키 critical·warning·deadman). 🔴 deadman 은 TOKYO_DEADMAN_URL 로 받은 도쿄 전용 주소로 교체한다"
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
#      → 그래서 이 스크립트는 주소 없이는 이 시크릿을 **만들지 않는다.**
#      🔴 도쿄 전용 체크는 **원래 설계**다 — `scripts/alerting/README.md` 22행이
#      "데드맨 체크 UUID(서울·도쿄가 다르다)" 로 적어 두고 있고,
#      `.gitlab-ci.yml` 391행도 "도쿄가 필요하면 HC_CHECK_UUID 를 바꿔 실행한다" 다.
#      같은 UUID 가 teardown 때 점검 모드(maintenance.sh)에도 쓰인다.
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
echo "## 도쿄 전용 ${#TOKYO_OWN[@]}개 (이름은 도쿄 것 · 수신처는 도쿄 전용 · 나머지는 서울 값 복사)"

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

  # 🔴 도쿄 전용 값으로 덮어쓸 JSON 키 — "키=환경변수값" 목록(2026-10-27).
  # 알림 수신처는 전부 도쿄 전용이어야 한다. 같은 수신처를 공유하면 도쿄가
  # 보낸 것이 「서울이 죽었다」를 가린다.
  overrides=()
  missing_env=()
  case "$name" in
    *alertmanager-receivers)
      [[ -n "$CRITICAL_WEBHOOK" ]] && overrides+=("critical=$CRITICAL_WEBHOOK") || missing_env+=("TOKYO_CRITICAL_WEBHOOK")
      [[ -n "$WARNING_WEBHOOK"  ]] && overrides+=("warning=$WARNING_WEBHOOK")   || missing_env+=("TOKYO_WARNING_WEBHOOK")
      [[ -n "$DEADMAN_URL"      ]] && overrides+=("deadman=$DEADMAN_URL")       || missing_env+=("TOKYO_DEADMAN_URL")
      ;;
    *argocd-notifications)
      [[ -n "$ARGOCD_WEBHOOK" ]] && overrides+=("discord=$ARGOCD_WEBHOOK") || missing_env+=("TOKYO_ARGOCD_WEBHOOK")
      ;;
    *grafana-oidc-client-secret)
      # 🔸 선택이다 — 비우면 서울 값 그대로(2026-10-26 결정).
      [[ -n "$GRAFANA_OIDC_SECRET" ]] && overrides+=("secret=$GRAFANA_OIDC_SECRET")
      ;;
  esac

  if (( ${#missing_env[@]} > 0 )); then
    echo "건너뜀 — 환경변수가 필요합니다: ${missing_env[*]}"
    printf '      → 서울 값을 그대로 복사하면 도쿄 알림이 **서울 수신처**로 갑니다.\n'
    printf '        그러면 도쿄가 보낸 것이 「서울이 죽었다」를 가립니다\n'
    printf '        (2026-10-26·10-27 재희님 결정: 수신처는 도쿄 전용).\n'
    printf '        Discord #regiondr-tokyo 의 웹훅과 Healthchecks.io 도쿄 체크\n'
    printf '        핑 주소를 환경변수로 넘겨 다시 돌리십시오 — 머리말 「쓰는 법」 참고.\n'
    continue
  fi

  if ! $APPLY_OWN; then
    if (( ${#overrides[@]} > 0 )); then
      # 🔴 값이 아니라 **키 이름만** 찍는다.
      _keys=(); for _o in "${overrides[@]}"; do _keys+=("${_o%%=*}"); done
      echo "생성 예정 ← $src (도쿄 전용으로 교체할 키: ${_keys[*]})"
      unset _keys _o
    else
      echo "생성 예정 ← $src (서울 값 그대로)"
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
  if (( ${#overrides[@]} > 0 )); then
    # 🔴 sed 가 아니라 JSON 파서로 바꾼다 — 웹훅 URL 에 / 와 ? 가 들어 있어
    # 구분자 충돌이 나고, 조용히 깨진 JSON 을 넣으면 오퍼레이터가 CR 전체를
    # 거부한다. 값은 출력하지 않는다. 덮어쓸 값은 argv 가 아니라 **stdin** 으로
    # 넘긴다 — argv 는 ps 에 보인다.
    if ! printf '%s\0' "${overrides[@]}" | python3 - "$tmp" <<'PYEOF'
import json, sys
path = sys.argv[1]
# stdin 은 "키=값" 을 NUL 로 구분한 목록. 값에 = 가 들어 있어도 1회만 자른다.
pairs = [q for q in sys.stdin.buffer.read().decode().split("\0") if q]
over = dict(q.split("=", 1) for q in pairs)

with open(path) as f:
    raw = f.read()
try:
    obj = json.loads(raw)
except json.JSONDecodeError as e:
    sys.exit("서울 값이 JSON 이 아닙니다: %s" % e)
if not isinstance(obj, dict):
    sys.exit("서울 값이 JSON 객체가 아닙니다")

# 서울 값에 그 키가 애초에 없으면 구조가 바뀐 것이다 — 조용히 더하지 않고 멈춘다.
absent = [k for k in over if k not in obj]
if absent:
    sys.exit("서울 값에 키가 없습니다: %s" % ", ".join(sorted(absent)))

obj.update(over)
with open(path, "w") as f:
    json.dump(obj, f, ensure_ascii=False)
PYEOF
    then
      echo "실패 — 도쿄 전용 값 교체 중 중단(위 메시지 참고)"
      rm -f "$tmp"; tmp=""
      continue
    fi
  fi

  if ERR=$(aws secretsmanager create-secret \
      --name "$name" \
      --region "$TOKYO" \
      --description "도쿄 DR 전용 — $src 기반$( (( ${#overrides[@]} > 0 )) && echo " · 도쿄 전용 키 교체")(2026-10-27)" \
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
