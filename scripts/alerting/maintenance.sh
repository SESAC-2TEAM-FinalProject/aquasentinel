#!/usr/bin/env bash
set -euo pipefail
# 점검 모드 진입·해제 스크립트 — Alertmanager Silence + Healthchecks.io 데드맨 일시정지를
# 한 번에 처리한다. 작업자 로컬·GitLab CI 잡 공용.
#
# 순서가 "Silence → 핑 중단 확인 → 일시정지"인 이유:
#   Watchdog이 Silence에 걸려야 Alertmanager가 1분마다 보내던 핑을 멈춘다.
#   Healthchecks.io는 핑을 받으면 자동 재개(manual_resume=false)되므로
#   핑이 멈춘 것을 확인한 뒤에 일시정지해야 paused 상태가 유지된다.
#   순서를 바꾸면 일시정지가 다음 핑에 즉시 깨진다.
#
# 해제를 잊어도 괜찮은 이유:
#   Silence가 끝나면(만료·stop·재구축) Watchdog 알림이 다시 전달돼 핑이 재개되고,
#   체크가 자동으로 다시 감시한다. Alertmanager는 PVC에 Silence를 보관하므로
#   파드 재시작·재배치만으로는 Silence가 풀리지 않는다(재구축은 새 PVC라 풀린다).
#
# 재구축 직후 알림 억제는 ClusterBootstrapping 억제 규칙이 담당한다.
#   이 스크립트는 teardown·점검 같은 계획된 작업에만 사용한다.
#   (manifests/alerting/routing/alertmanagerconfig.yaml inhibitRules 참고)
#
# 사용 예:
#   HC_API_KEY=<key> HC_CHECK_UUID=<uuid> ./maintenance.sh start "DB 마이그레이션" 2h
#   HC_API_KEY=<key> HC_CHECK_UUID=<uuid> ./maintenance.sh stop
#   HC_API_KEY=<key> HC_CHECK_UUID=<uuid> ./maintenance.sh status

# ── 환경변수 설정 ────────────────────────────────────────────────────
HC_API_KEY="${HC_API_KEY:-}"
HC_CHECK_UUID="${HC_CHECK_UUID:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
AM_NAMESPACE="${AM_NAMESPACE:-monitoring}"
# gitops manifests/alerting/routing/rbac-maintenance.yaml 의 resourceNames 와 같아야 한다
# (CI 권한은 이 파드 하나의 get·exec 뿐 — 이름이 바뀌면 두 곳을 함께 고친다)
AM_POD="${AM_POD:-alertmanager-kube-prometheus-stack-alertmanager-0}"
HC_API_URL="${HC_API_URL:-https://healthchecks.io/api/v3}"
KUBECTL="${KUBECTL:-kubectl}"
CURL="${CURL:-curl}"
WAIT_SILENCE_SEC="${WAIT_SILENCE_SEC:-90}"
CONFIRM_SEC="${CONFIRM_SEC:-75}"
WAIT_RESUME_SEC="${WAIT_RESUME_SEC:-180}"
POLL_SEC="${POLL_SEC:-15}"

SILENCE_AUTHOR="aquasentinel-maintenance"
MAX_DURATION_HOURS=12
MAX_DURATION_MINUTES=$(( MAX_DURATION_HOURS * 60 ))

# ── 공통 함수 ────────────────────────────────────────────────────────
log()  { echo "[maintenance] $*"; }
warn() { echo "[maintenance] WARNING: $*" >&2; }
die()  { local code="$1"; shift; echo "[maintenance] ERROR: $*" >&2; exit "$code"; }

usage() {
  cat >&2 <<'USAGE'
사용법: maintenance.sh <명령> [인자...]

  start <사유> [기간]   Silence 걸고 데드맨 일시정지. 기간 기본 2h, 최대 12h (형식: Nm·Nh)
  stop                  Silence 해제. 데드맨은 핑 재개 시 자동으로 풀림
  status                Silence 목록과 데드맨 체크 상태 출력

필수 환경변수:
  HC_API_KEY      Healthchecks.io 읽기·쓰기 키
  HC_CHECK_UUID   데드맨 체크 UUID

종료 코드:
  0  성공
  1  사용법·환경변수 오류 (아무것도 호출하지 않음)
  2  Alertmanager(amtool) 단계 실패
  3  Healthchecks.io 단계 실패
  4  Watchdog이 시간 안에 Silence되지 않음 (일시정지 안 함)
USAGE
}

require_env() {
  local missing=0
  for v in HC_API_KEY HC_CHECK_UUID; do
    if [ -z "${!v}" ]; then warn "필수 환경변수 누락: $v"; missing=1; fi
  done
  if [ "$missing" -eq 1 ]; then usage; exit 1; fi
}

amtool_exec() {
  local ctx=()
  if [ -n "$KUBE_CONTEXT" ]; then ctx=(--context "$KUBE_CONTEXT"); fi
  # 빈 배열을 set -u 에서도 안전하게 펼친다(bash 4.4 미만 대비)
  "$KUBECTL" ${ctx[@]+"${ctx[@]}"} -n "$AM_NAMESPACE" exec "$AM_POD" -c alertmanager \
    -- amtool "$@" --alertmanager.url=http://localhost:9093
}

HC_BODY="" HC_CODE="" _TMPFILE=""
# EXIT trap 안에서 실패하는 명령을 두지 않는다 — set -e 때문에 원래 종료 코드(2·3·4)가 1로 덮인다
_cleanup() { if [ -n "$_TMPFILE" ]; then rm -f "$_TMPFILE"; fi; }
trap _cleanup EXIT

hc_request() {
  local method="$1" path="$2"
  # 응답 본문 임시 파일은 한 번만 만들어 재사용한다(종료 때 trap 이 지운다)
  if [ -z "$_TMPFILE" ]; then _TMPFILE="$(mktemp)"; fi
  HC_CODE="000"
  local url="${HC_API_URL}/checks/${HC_CHECK_UUID}${path}"
  # 키를 명령줄 인자에 넣지 않고 curl -K 표준입력으로 넘긴다 (프로세스 목록·CI 로그 노출 방지)
  HC_CODE="$(printf 'header = "X-Api-Key: %s"\n' "$HC_API_KEY" \
    | "$CURL" -K - -sS -X "$method" --max-time 20 \
      -o "$_TMPFILE" -w '%{http_code}' "$url")" || HC_CODE="000"
  HC_BODY="$(cat "$_TMPFILE")"
}

hc_status() {
  hc_request GET ""
  [ "$HC_CODE" != "200" ] && { echo "unknown"; return; }
  local st
  # API 응답은 "status": "up" 처럼 콜론 뒤에 공백이 있다 — 공백 유무 모두 허용
  st="$(echo "$HC_BODY" | grep -o '"status": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  echo "${st:-unknown}"
}

watchdog_silenced() {
  amtool_exec alert query --silenced --no-active alertname=Watchdog -o json 2>/dev/null \
    | grep -q "Watchdog"
}

our_silence_ids() {
  amtool_exec silence query --created-by="$SILENCE_AUTHOR" -q 2>/dev/null
}

# ── start ────────────────────────────────────────────────────────────
cmd_start() {
  local reason="${1:-}" duration="${2:-2h}"
  [ -z "$reason" ] && { warn "사유를 입력하세요"; usage; exit 1; }
  echo "$duration" | grep -qE '^[0-9]+[mh]$' \
    || die 1 "기간 형식 오류: '$duration' (예: 30m, 2h)"
  local minutes
  if [ "${duration%h}" != "$duration" ]; then minutes=$(( 10#${duration%h} * 60 )); else minutes=$(( 10#${duration%m} )); fi
  if [ "$minutes" -gt "$MAX_DURATION_MINUTES" ] || [ "$minutes" -eq 0 ]; then
    die 1 "기간은 1m 이상 ${MAX_DURATION_HOURS}h 이하여야 합니다: '$duration'"
  fi

  # ① 기존 Silence 확인 (중복 허용 — 경고만)
  local existing; existing="$(our_silence_ids)" || die 2 "Silence 조회 실패 — 클러스터 권한·파드 이름(AM_POD) 확인"
  [ -n "$existing" ] && warn "이미 활성 Silence가 있습니다. 새 기간으로 하나 더 추가합니다"

  # ② Silence 추가 — 실패 시 일시정지 없이 종료
  local actor="${GITLAB_USER_LOGIN:-${USER:-${USERNAME:-unknown}}}"
  local sid
  sid="$(amtool_exec silence add 'alertname=~".+"' \
    --author="$SILENCE_AUTHOR" \
    --comment="maintenance: ${reason} (by ${actor})" \
    --duration="$duration")" || die 2 "Silence 추가 실패"
  log "Silence 추가됨: $sid"

  # ③ Watchdog이 Silence됐는지 폴링 — 안 되면 일시정지 없이 종료
  local elapsed=0
  while [ "$elapsed" -lt "$WAIT_SILENCE_SEC" ]; do
    if watchdog_silenced; then log "Watchdog Silence 확인 (${elapsed}s)"; break; fi
    sleep "$POLL_SEC"
    elapsed=$(( elapsed + POLL_SEC ))
  done
  if ! watchdog_silenced; then
    warn "Watchdog이 ${WAIT_SILENCE_SEC}s 안에 Silence되지 않았습니다 (Silence $sid 은 남아 있음)"
    warn "Watchdog이 발화 중인지 확인하세요"
    exit 4
  fi

  # ④ 데드맨 일시정지 — 실패 시 Silence는 그대로 두고 종료
  hc_request POST /pause
  if [ "$HC_CODE" != "200" ]; then
    warn "데드맨 일시정지 실패 (HTTP $HC_CODE). Silence는 걸렸지만 데드맨은 유예 5분 뒤 울릴 수 있습니다"
    exit 3
  fi
  log "데드맨 일시정지 요청 완료"

  # ⑤ CONFIRM_SEC 후 상태 재확인, paused 아니면 한 번만 재시도
  sleep "$CONFIRM_SEC"
  local st; st="$(hc_status)"
  if [ "$st" != "paused" ]; then
    warn "상태 '$st' — /pause 재시도"
    hc_request POST /pause
    if [ "$HC_CODE" != "200" ]; then
      warn "재시도 실패 (HTTP $HC_CODE)"
      exit 3
    fi
    sleep "$CONFIRM_SEC"
    st="$(hc_status)"
    if [ "$st" != "paused" ]; then
      warn "재시도 후에도 상태 '$st' — 핑이 계속 들어오는 중일 수 있다. Watchdog Silence 확인 필요"
      exit 3
    fi
  fi

  # ⑥ 결과 출력
  log "Silence 목록:"
  amtool_exec silence query --created-by="$SILENCE_AUTHOR" || true
  log "데드맨 체크 상태: $(hc_status)"
}

# ── stop ─────────────────────────────────────────────────────────────
cmd_stop() {
  # ① Silence 만료 — created-by로 걸러 다른 Silence에는 손대지 않는다
  local ids; ids="$(our_silence_ids)" || die 2 "Silence 조회 실패"
  if [ -z "$ids" ]; then
    log "만료할 Silence 없음"
  else
    local -a id_arr=()
    while IFS= read -r id; do [ -n "$id" ] && id_arr+=("$id"); done <<< "$ids"
    amtool_exec silence expire "${id_arr[@]}" || die 2 "Silence 만료 실패"
    log "Silence 만료 완료"
  fi

  # ② Silence 해제 후 핑이 재개되면 체크가 자동으로 paused 해제된다
  local elapsed=0 st; st="$(hc_status)"
  while [ "$st" = "paused" ] && [ "$elapsed" -lt "$WAIT_RESUME_SEC" ]; do
    sleep "$POLL_SEC"
    elapsed=$(( elapsed + POLL_SEC ))
    st="$(hc_status)"
  done

  if [ "$st" != "paused" ]; then
    log "데드맨 체크 재개됨 (${elapsed}s, 상태: $st)"
  else
    # ③ 시간 안에 자동 재개 안 되면 수동 resume
    log "/resume 수동 호출"
    hc_request POST /resume
    [ "$HC_CODE" != "200" ] && [ "$HC_CODE" != "409" ] \
      && die 3 "데드맨 재개 실패 (HTTP $HC_CODE)"
  fi

  # ④ 결과 출력
  local rem; rem="$(our_silence_ids)"
  local cnt=0; [ -n "$rem" ] && cnt="$(echo "$rem" | grep -c .)" || true
  log "남은 우리 Silence 수: $cnt (0이어야 함)"
  log "데드맨 체크 상태: $(hc_status)"
}

# ── status ───────────────────────────────────────────────────────────
cmd_status() {
  local ec=0
  log "Silence 목록:"
  amtool_exec silence query --created-by="$SILENCE_AUTHOR" || { warn "Silence 조회 실패"; ec=2; }
  local st; st="$(hc_status)"
  if [ "$st" = "unknown" ]; then
    warn "데드맨 체크 조회 실패"
    [ "$ec" -eq 0 ] && ec=3
  else
    log "데드맨 체크 상태: $st"
  fi
  return "$ec"
}

# ── 진입점 ───────────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"
  case "$cmd" in
    -h|--help) usage; exit 0 ;;
    start|stop|status) require_env ;;
    *) usage; exit 1 ;;
  esac
  case "$cmd" in
    start)  cmd_start "${2:-}" "${3:-2h}" ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
  esac
}

main "$@"
