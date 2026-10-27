#!/usr/bin/env bash
# Terraform 상태 backend 를 서울 ↔ 도쿄 복제본으로 전환 (2026-10-26)
#
# 왜 필요한가
#   DR 시나리오의 「서울이 죽었다」 가정과 코드가 어긋나 있다. 13개 컴포넌트의
#   backend.hcl 이 **전부** 서울 버킷(ap-northeast-2)을 가리킨다. 진짜 서울
#   장애면 도쿄를 세우려고 `terraform init` 하는 순간 서울 S3 를 때리고 막힌다.
#   DR 시나리오 문서가 `[가정 예외]` 로 적어 둔 그 지점이고, 복제본만 만들어도
#   backend 를 바꾸지 않으면 아무 의미가 없다.
#
#   🔴 bucket 이름까지 바뀐다. S3 버킷 이름은 전역 유일이라 복제본은
#   `-replica` 가 붙는다 — region 만 바꾸면 안 된다. 손으로 13개를 고치면
#   하나를 빠뜨리고, 그 하나가 장애 한가운데서 드러난다. 그래서 스크립트다.
#
# 쓰는 법
#   ./dr-switch-tfstate-backend.sh                # 지금 상태 보기 (기본)
#   ./dr-switch-tfstate-backend.sh --to-replica   # 도쿄 복제본으로 전환
#   ./dr-switch-tfstate-backend.sh --to-primary   # 서울 원본으로 되돌리기
#
# 전환 뒤에 반드시
#   각 컴포넌트에서 `terraform init -backend-config=backend.hcl -reconfigure`
#   를 해야 Terraform 이 새 backend 를 본다. 🔴 `-migrate-state` 를 쓰면 안 된다 —
#   그건 "상태를 옮긴다"는 뜻이고, 복제본에는 이미 복제된 상태가 있다.
#   `-reconfigure` 는 "그냥 저쪽을 쓴다"는 뜻이다.
#
# 안전장치
#   - 기본이 보기 모드. 바꾸려면 플래그를 줘야 한다
#   - 바꾸기 전에 복제본 버킷이 실재하는지 확인한다(없으면 중단)
#   - 바꾼 파일마다 before → after 를 출력한다
#   - 🔴 되돌릴 때 복제본 쪽에서 apply 한 적이 있으면 경고한다(상태가 갈라졌다)

set -euo pipefail

PRIMARY_REGION="ap-northeast-2"
REPLICA_REGION="ap-northeast-1"
ACCOUNT="379937169195"
PRIMARY_BUCKET="aquasentinel-tfstate-${ACCOUNT}"
REPLICA_BUCKET="aquasentinel-tfstate-replica-${ACCOUNT}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT}/terraform"

MODE="status"
case "${1:-}" in
  --to-replica) MODE="to-replica" ;;
  --to-primary) MODE="to-primary" ;;
  ""|--status)  MODE="status" ;;
  -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *)            echo "모르는 인자: $1 (--help)" >&2; exit 2 ;;
esac

# 🔴 mapfile 을 쓰면 안 된다 — macOS 기본 bash 는 3.2 이고 mapfile 이 없다.
# `bash -n` 은 통과하고 실행할 때서야 "command not found" 로 깨진다.
FILES=()
while IFS= read -r _line; do FILES+=("$_line"); done < <(find "$TF_DIR" -name backend.hcl | sort)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "backend.hcl 을 찾지 못했다: $TF_DIR" >&2
  exit 1
fi

# 🔴 \s 를 쓰면 안 된다 — macOS(BSD) 의 sed·grep 은 \s 를 모른다. 치환이 조용히
# 실패해서 줄 전체가 값으로 잡히고, 13개가 전부 "알 수 없음" 이 된다(2026-10-26 실측).
# POSIX 문자 클래스 [[:space:]] 는 BSD·GNU 양쪽에서 동작한다.
bucket_of() { grep -E '^[[:space:]]*bucket[[:space:]]*=' "$1" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/'; }
region_of() { grep -E '^[[:space:]]*region[[:space:]]*=' "$1" | head -1 | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/'; }

# ── 보기 모드 ──────────────────────────────────────────────────────────────
if [ "$MODE" = "status" ]; then
  echo "backend.hcl ${#FILES[@]}개"
  echo
  n_primary=0 n_replica=0 n_other=0
  for f in "${FILES[@]}"; do
    b="$(bucket_of "$f")" r="$(region_of "$f")"
    rel="${f#"$TF_DIR"/}" rel="${rel%/backend.hcl}"
    case "$b" in
      "$PRIMARY_BUCKET") tag="원본(서울)"  ; n_primary=$((n_primary+1)) ;;
      "$REPLICA_BUCKET") tag="복제본(도쿄)"; n_replica=$((n_replica+1)) ;;
      *)                 tag="🔴 알 수 없음"; n_other=$((n_other+1)) ;;
    esac
    printf "  %-34s %-14s %s\n" "$rel" "$r" "$tag"
  done
  echo
  echo "  원본 ${n_primary} · 복제본 ${n_replica} · 알 수 없음 ${n_other}"
  if [ "$n_primary" -gt 0 ] && [ "$n_replica" -gt 0 ]; then
    echo "  🔴 섞여 있다 — 컴포넌트마다 다른 버킷을 본다. 한쪽으로 맞출 것"
  fi
  exit 0
fi

# ── 바꾸기 ────────────────────────────────────────────────────────────────
if [ "$MODE" = "to-replica" ]; then
  FROM_BUCKET="$PRIMARY_BUCKET" TO_BUCKET="$REPLICA_BUCKET"
  FROM_REGION="$PRIMARY_REGION" TO_REGION="$REPLICA_REGION"
  CHECK_REGION="$REPLICA_REGION"
else
  FROM_BUCKET="$REPLICA_BUCKET" TO_BUCKET="$PRIMARY_BUCKET"
  FROM_REGION="$REPLICA_REGION" TO_REGION="$PRIMARY_REGION"
  CHECK_REGION="$PRIMARY_REGION"
fi

echo "전환: ${FROM_BUCKET} (${FROM_REGION}) → ${TO_BUCKET} (${TO_REGION})"
echo

# 🔴 가려는 쪽 버킷이 실재하는지 먼저 본다. 없는데 바꾸면 13개를 전부
# 못 쓰는 상태로 만들고, 그 사실은 init 할 때서야 드러난다.
if ! aws s3api head-bucket --bucket "$TO_BUCKET" --region "$CHECK_REGION" >/dev/null 2>&1; then
  echo "🔴 중단 — 가려는 버킷이 없거나 접근할 수 없다: ${TO_BUCKET} (${CHECK_REGION})" >&2
  if [ "$MODE" = "to-replica" ]; then
    echo "   복제가 아직 안 켜졌을 수 있다. terraform/global/bootstrap 에서" >&2
    echo "   enable_tfstate_replication = true 로 apply 했는지 확인할 것" >&2
    echo "   (runbooks/Terraform상태_리전전환.md 1장)" >&2
  fi
  exit 1
fi
echo "  ✅ 가려는 버킷 확인: ${TO_BUCKET}"

# 되돌리는 경우 — 복제본 쪽에서 apply 한 적이 있으면 상태가 갈라졌다.
if [ "$MODE" = "to-primary" ]; then
  echo
  echo "  🔴 되돌리기 전에 확인할 것 — DR 중 도쿄에서 apply 했다면 **복제본 쪽이"
  echo "     더 최신**이다. 그대로 서울로 돌리면 그 작업이 상태에서 사라진다."
  echo "     복제는 서울 → 도쿄 **한 방향**이므로 자동으로 돌아오지 않는다."
  echo "     DR 중 도쿄에서 apply 했다면 되돌리기 전에 상태를 서울로 옮길 것"
  echo "     (runbooks/Terraform상태_리전전환.md 4장)."
fi

echo
changed=0 skipped=0
for f in "${FILES[@]}"; do
  rel="${f#"$TF_DIR"/}" rel="${rel%/backend.hcl}"
  b="$(bucket_of "$f")"
  if [ "$b" != "$FROM_BUCKET" ]; then
    printf "  건너뜀 %-34s (이미 %s)\n" "$rel" "$b"
    skipped=$((skipped+1))
    continue
  fi
  # 같은 줄의 값만 바꾼다 — key 줄은 건드리지 않는다(컴포넌트 경로라 그대로 쓴다)
  sed -i.bak \
    -e "s|^\([[:space:]]*bucket[[:space:]]*=[[:space:]]*\)\"${FROM_BUCKET}\"|\1\"${TO_BUCKET}\"|" \
    -e "s|^\([[:space:]]*region[[:space:]]*=[[:space:]]*\)\"${FROM_REGION}\"|\1\"${TO_REGION}\"|" \
    "$f"
  rm -f "${f}.bak"
  printf "  ✅ %-34s %s → %s\n" "$rel" "$FROM_REGION" "$TO_REGION"
  changed=$((changed+1))
done

echo
echo "  바꿈 ${changed} · 건너뜀 ${skipped}"
echo
echo "🔴 다음 — 각 컴포넌트에서 backend 를 다시 읽어야 한다:"
echo "     terraform -chdir=terraform/<컴포넌트> init -backend-config=backend.hcl -reconfigure"
echo "   (-migrate-state 가 아니다 — 위 머리말 참고)"
