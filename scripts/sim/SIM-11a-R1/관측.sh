#!/usr/bin/env bash
# SIM-11a-R1 관측 명령 묶음 — 🔴 읽기만 한다. 주입·해제는 이 스크립트가 하지 않는다.
#
# 주입과 해제는 README.md 의 kubectl 명령으로 직접 한다. 자동화하면 적용된 내용을
# 눈으로 못 보고 지나가고, 중단이 필요한 순간에 스크립트를 기다리게 된다.
#
# 쓰는 법
#   ./관측.sh before     # 1단계 — 전 상태 (주입 전에 반드시)
#   ./관측.sh watch      # 3단계 — 30초 간격 추적 (Ctrl-C 로 끝냄)
#   ./관측.sh after      # 5단계 — t1 · t2 를 경보 이력에서 읽는다
#   ./관측.sh csv        # 5단계 — 🔴 CloudWatch 1분 값을 CSV 로 (측정 당일 필수)
#   ./관측.sh snap       # 아무 때나 한 번 찍기
#
# 환경변수(기본값은 구역 1 / 운영 공통 코드 기준)
#   NS=web  APP=status-svc  URL=https://zer0cloud.cloud/readyz
#   ALARM_HTTPS=aquasentinel-dev-edge-readyz  ALARM_TCP=aquasentinel-dev-edge-tcp
#   OUT=./증거            # csv · 로그가 쌓이는 곳
set -uo pipefail

NS="${NS:-web}"
APP="${APP:-status-svc}"
URL="${URL:-https://zer0cloud.cloud/readyz}"
ALARM_HTTPS="${ALARM_HTTPS:-aquasentinel-dev-edge-readyz}"
ALARM_TCP="${ALARM_TCP:-aquasentinel-dev-edge-tcp}"
OUT="${OUT:-./증거}"
R53_REGION="us-east-1"   # 🔴 Route53 헬스체크 지표는 us-east-1 에만 있다

mkdir -p "$OUT"
ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
hr()  { printf '%s\n' "────────────────────────────────────────────────"; }

# ── 외부 진입 ──────────────────────────────────────────────────
ext() {
  local code t
  t=$(ts)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null || echo "000")
  printf '%s  외부 %s → %s\n' "$t" "$URL" "$code"
  echo "$t,$code" >> "$OUT/외부_curl.csv"
}

# ── 파드 4항목: ContainersReady · Ready · 게이트 · 재시작 ───────
# 🔴 넷을 따로 본다. 기대는 ContainersReady 이고, Ready 와 게이트는 False 로 가도 예상이다.
pods() {
  kubectl -n "$NS" get pod -l "app=$APP" -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in d.get('items',[]):
    c={x['type']:x['status'] for x in p['status'].get('conditions',[])}
    gates=[g['conditionType'] for g in p['spec'].get('readinessGates',[])]
    rs=sum(s.get('restartCount',0) for s in p['status'].get('containerStatuses',[]) or [])
    gv=' '.join(f'{g.split(\"/\")[-1]}={c.get(g,\"-\")}' for g in gates) or '게이트없음'
    print(f\"  {p['metadata']['name']:34s} ContainersReady={c.get('ContainersReady','-'):5s} Ready={c.get('Ready','-'):5s} 재시작={rs}  {gv}\")
" || echo "  (파드 조회 실패)"
}

# ── Service 엔드포인트 수 (🔴 Ready 를 따르므로 이탈 가능) ──────
endpoints() {
  local n
  n=$(kubectl -n "$NS" get endpoints "$APP" -o json 2>/dev/null \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print(sum(len(s.get('addresses',[])) for s in d.get('subsets',[]) or []))" 2>/dev/null)
  printf '  Service 엔드포인트: %s\n' "${n:-조회실패}"
}

# ── ALB 대상 그룹 헬스 ─────────────────────────────────────────
tg() {
  local arns
  arns=$(aws elbv2 describe-target-groups --output json 2>/dev/null \
    | python3 -c "
import sys,json
for t in json.load(sys.stdin).get('TargetGroups',[]):
    if 'web' in t['TargetGroupName'] or 'status' in t['TargetGroupName']:
        print(t['TargetGroupArn'])
" 2>/dev/null)
  [ -z "$arns" ] && { echo "  (대상 그룹 못 찾음 — 이름 규칙 확인)"; return; }
  while read -r a; do
    [ -z "$a" ] && continue
    aws elbv2 describe-target-health --target-group-arn "$a" --output json 2>/dev/null \
      | python3 -c "
import sys,json,os
d=json.load(sys.stdin)
nm='${a##*/}'
st=[h['TargetHealth']['State'] for h in d.get('TargetHealthDescriptions',[])]
from collections import Counter
print(f\"  대상그룹 …{nm[-20:]}  {dict(Counter(st)) or '대상없음'}\")
" 2>/dev/null
  done <<< "$arns"
}

# ── 발화 경보 · Argo 앱 ────────────────────────────────────────
alerts() {
  local n
  n=$(kubectl -n monitoring exec -q deploy/kube-prometheus-stack-operator -- true 2>/dev/null; echo)
  kubectl get applications -n argocd -o json 2>/dev/null | python3 -c "
import sys,json
apps=json.load(sys.stdin).get('items',[])
bad=[a['metadata']['name'] for a in apps
     if a.get('status',{}).get('health',{}).get('status')!='Healthy'
     or a.get('status',{}).get('sync',{}).get('status')!='Synced']
print(f\"  Argo 앱 {len(apps)}개 · 정상 아님 {len(bad)}개\" + (f\": {bad}\" if bad else ''))
" 2>/dev/null || echo "  (Argo 조회 실패)"
}

# ── CloudWatch 경보 상태 / 이력 ────────────────────────────────
alarm_state() {
  for a in "$ALARM_HTTPS" "$ALARM_TCP"; do
    aws cloudwatch describe-alarms --region "$R53_REGION" --alarm-names "$a" --output json 2>/dev/null \
      | python3 -c "
import sys,json
from datetime import datetime, timezone
# 🔴 aws cli 는 시각을 **실행하는 PC 의 시간대**로 내놓는다(KST 면 +09:00).
# t0 는 README 대로 date -u 라 UTC 이므로, 바꾸지 않고 그대로 찍으면
# t2 − t0 를 손으로 뺄 때 9시간 틀린다. 2026-10-22 창영님(B) 구역 1 시험에서
# 실제로 +09:00 으로 찍히는 것을 확인했다 — !59(edge-availability.py)와 같은 원인.
def utc(s):
    if not s: return '-'
    t = datetime.fromisoformat(str(s).replace('Z','+00:00'))
    if not t.tzinfo: t = t.replace(tzinfo=timezone.utc)
    return t.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
m=json.load(sys.stdin).get('MetricAlarms',[])
for x in m: print(f\"  경보 {x['AlarmName']:36s} {x['StateValue']:12s} 전이 {utc(x.get('StateUpdatedTimestamp'))}\")
" 2>/dev/null
  done
}

# ── 🔴 어느 구역을 보고 있나 (창영님 제안 2026-10-22) ────────────
# 스크립트가 구역을 확인하지 않는다 — 컨텍스트나 프로필이 다른 곳을 가리키면
# **다른 계정의 경보·헬스체크를 읽는다.** 눈으로 보는 것만으로는 증거에 안 남아,
# 판정 때 "이 값이 구역 1 것"이라는 근거가 없다. 그래서 파일에 찍어 둔다.
whereami() {
  local ctx acct arn
  ctx=$(kubectl config current-context 2>/dev/null || echo "조회실패")
  arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "조회실패")
  acct=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "조회실패")
  printf '  어디냐: 컨텍스트=%s\n' "$ctx"
  printf '           계정=%s  주체=%s\n' "$acct" "$arn"
  printf '           AWS_PROFILE=%s  AWS_REGION=%s\n' "${AWS_PROFILE:-(없음)}" "${AWS_REGION:-${AWS_DEFAULT_REGION:-(없음)}}"
  case "$acct" in
    383344224073) printf '           → 시험 구역 1 ✅\n' ;;
    926762923779) printf '           → 🔴 시험 구역 2 — 11a 대상이 아니다\n' ;;
    379937169195) printf '           → 🔴🔴 운영이다. 11a 는 구역 1 에서만 한다. 멈추십시오\n' ;;
    *)            printf '           → 🔴 모르는 계정 — 확인 필요\n' ;;
  esac
}

snap() {
  hr; echo "[$(ts)]"; hr
  whereami
  ext
  pods
  endpoints
  tg
  alarm_state
  alerts
}

case "${1:-}" in
  before)
    echo "=== 1단계 전 상태 · $(ts) ===" | tee "$OUT/01_전상태.txt"
    snap 2>&1 | tee -a "$OUT/01_전상태.txt"
    echo
    echo "🔴 4장 실행 직전 확인 — 아래 셋을 눈으로 보고 기록하십시오"
    echo "  ① 정책 집행 켜짐?"
    kubectl -n kube-system get ds aws-node -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}' 2>/dev/null | tr ' ' '\n' | sed 's/^/      컨테이너: /'
    kubectl -n kube-system get ds aws-node -o json 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for c in d['spec']['template']['spec']['containers']:
    if 'nodeagent' in c['name']:
        args=' '.join(c.get('args',[]) or [])
        print('      nodeagent args:', args or '(없음)')
        print('      → enable-network-policy:', 'true' in args.split('enable-network-policy=')[-1][:5] if 'enable-network-policy' in args else '🔴 못 찾음')
" 2>/dev/null
    echo "  ② 게이트 조건 · ③ ALB 대상 헬스 — 위 snap 결과에 있음"
    ;;
  watch)
    echo "=== 3단계 추적 (30초 간격 · Ctrl-C 로 끝냄) ==="
    echo "🔴 첫 외부 실패가 보이면 그 시각이 t0' 입니다"
    while true; do snap 2>&1 | tee -a "$OUT/03_추적.txt"; sleep 30; done
    ;;
  after)
    echo "=== 5단계 t1 · t2 읽기 ===" | tee "$OUT/05_경보이력.txt"
    for a in "$ALARM_HTTPS" "$ALARM_TCP"; do
      echo "--- $a 상태 전이 이력 ---" | tee -a "$OUT/05_경보이력.txt"
      aws cloudwatch describe-alarm-history --region "$R53_REGION" --alarm-name "$a" \
        --history-item-type StateUpdate --max-records 20 --output json 2>/dev/null \
        | python3 -c "
import sys,json
from datetime import datetime, timezone
# 🔴 여기도 UTC 로 바꿔 찍는다 — t2 를 읽는 바로 그 줄이다(위 alarm_state 주석 참고)
def utc(s):
    if not s: return '-'
    t = datetime.fromisoformat(str(s).replace('Z','+00:00'))
    if not t.tzinfo: t = t.replace(tzinfo=timezone.utc)
    return t.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
for h in json.load(sys.stdin).get('AlarmHistoryItems',[]):
    print(f\"  {utc(h['Timestamp'])}  {h['HistorySummary']}\")
" 2>&1 | tee -a "$OUT/05_경보이력.txt"
    done
    echo
    echo "🔴 t2 = 위에서 'to ALARM' 으로 바뀐 시각. t2 − t0 가 감지 시간입니다"
    ;;
  csv)
    echo "=== 🔴 CloudWatch 1분 값 CSV — 측정 당일에 떠야 합니다 ==="
    echo "    (1분 해상도는 15일만 남습니다. 지나면 5분 롤업뿐이고 Minimum 통계라 분 단위를 못 읽습니다)"
    S="${2:-}"; E="${3:-}"
    [ -z "$S" ] || [ -z "$E" ] && { echo "  쓰는 법: ./관측.sh csv 2026-10-23T00:00:00Z 2026-10-23T01:00:00Z"; exit 1; }
    ids=$(aws route53 list-health-checks --output json 2>/dev/null | python3 -c "
import sys,json
for h in json.load(sys.stdin).get('HealthChecks',[]):
    c=h['HealthCheckConfig']
    label=c.get('FullyQualifiedDomainName') or c.get('IPAddress') or '?'
    print(f\"{h['Id']} {c.get('Type')} {label}\")
" 2>/dev/null)
    [ -z "$ids" ] && { echo "  🔴 헬스체크 목록 조회 실패"; exit 1; }
    echo "$ids" | sed 's/^/  헬스체크: /'
    while read -r id typ label; do
      [ -z "$id" ] && continue
      f="$OUT/r53_${typ}_${id}.csv"
      aws cloudwatch get-metric-statistics --region "$R53_REGION" \
        --namespace AWS/Route53 --metric-name HealthCheckStatus \
        --dimensions Name=HealthCheckId,Value="$id" \
        --start-time "$S" --end-time "$E" --period 60 --statistics Minimum \
        --output json 2>/dev/null | python3 -c "
import sys,json
from datetime import timezone
pts=sorted(json.load(sys.stdin).get('Datapoints',[]), key=lambda x:x['Timestamp'])
print('timestamp_utc,minimum')
for p in pts:
    # 🔴 aws cli 는 Timestamp 를 지역 시간대로 줄 수 있다 — 그대로 쓰면 시각이 틀린다
    from datetime import datetime
    t=datetime.fromisoformat(p['Timestamp'].replace('Z','+00:00')) if isinstance(p['Timestamp'],str) else p['Timestamp']
    print(f\"{t.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')},{int(p['Minimum'])}\")
" > "$f" 2>/dev/null
      echo "  → $f ($(( $(wc -l < "$f") - 1 ))점) $label"
    done <<< "$ids"
    ;;
  snap|"") snap ;;
  *) echo "쓰는 법: $0 {before|watch|after|csv <시작Z> <끝Z>|snap}"; exit 1 ;;
esac
