#!/usr/bin/env python3
"""판정 창 #1(외부 진입 성공률) 주 1회 구간 기록 — CloudWatch 1분 데이터를 떠서 보관한다.

읽기만 한다(route53:ListHealthChecks · cloudwatch:GetMetricStatistics). 아무것도 쓰거나 지우지 않는다.

왜 이 스크립트가 필요한가 — CloudWatch 가 판정 창보다 먼저 지운다:

    CloudWatch 1분 해상도 보존 = 15일
    판정 창                    = 19일 (2026-10-22 ~ 11-09)

  11/09 에 판정하려고 보면 창 앞부분(10/22~10/25) 1분 데이터가 이미 없다. 5분 롤업은
  63일 남지만 그것으로 대신할 수 없다 — Route53 HealthCheckStatus 는 Minimum 통계로
  읽는데, 5분 해상도에서는 1분짜리 장애 하나가 5분 구간 전체를 0 으로 만들어 **장애가
  5배로 부풀려진다**. 게다가 창 앞부분은 5분, 뒷부분은 1분이 되어 측정 방식이 중간에
  바뀌므로 19일을 한 덩어리로 쓸 수 없다.

  그래서 주 1회 1분 데이터를 떠서 파일로 남긴다. 재희님 주 1회 구간 기록은 #2 · #3
  (Prometheus 보존 14일)을 위한 것이고 #1 은 그 계획에 없었다 — 둘 다 보존이 창보다
  짧은데 한쪽만 대비돼 있었다(2026-10-22 발견).

가중 평균으로 합치는 법:
  구간마다 (데이터점 수, 정상 점 수)를 남긴다. 창 전체 가용성은
  sum(정상 점) / sum(전체 점) 이다. 구간 길이가 달라도(마지막 주 5일) 점 수가
  가중치 역할을 하므로 따로 보정하지 않는다.

하루씩 끊어 부르는 이유:
  GetMetricStatistics 는 한 번에 1440 점까지만 준다. 7일 × 1440분 = 10,080 점이라
  한 번에 못 받는다. 하루(1440점)씩 끊어 부르고 이어 붙인다.

쓰는 법:
  python3 edge-availability.py --since 2026-10-22T00:00:00Z --until 2026-10-29T00:00:00Z
  python3 edge-availability.py --week 1        # 창 1주차(10/22~10/29)를 자동 계산
  python3 edge-availability.py --since ... --out ~/judgment/week-1

  --health-check-id 를 주지 않으면 계정의 헬스체크를 전부 뜬다(HTTPS · TCP 둘 다).
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone

# 판정 창 — 목표 고정 기록(2026-10-19) · 창 시작 선언(2026-10-22)
WINDOW_START = datetime(2026, 10, 22, 0, 0, tzinfo=timezone.utc)
WINDOW_END = datetime(2026, 11, 10, 0, 0, tzinfo=timezone.utc)  # 11/09 하루를 포함
TARGET = 0.995  # #1 외부 진입 성공률

# CloudWatch 가 1분 해상도를 보관하는 기간. 이보다 오래된 구간은 뜰 수 없다.
RETENTION_DAYS_1MIN = 15


def aws(*args: str) -> dict:
    """aws CLI 를 JSON 으로 부른다. 자격증명은 환경에 이미 있는 것을 쓴다."""
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"aws {' '.join(args[:3])} 실패: {r.stderr.strip()[:300]}")
    return json.loads(r.stdout) if r.stdout.strip() else {}


def health_checks(only: list[str] | None) -> list[dict]:
    """계정의 Route53 헬스체크 목록. --health-check-id 로 좁힐 수 있다."""
    out = []
    for h in aws("route53", "list-health-checks").get("HealthChecks", []):
        if only and h["Id"] not in only:
            continue
        c = h["HealthCheckConfig"]
        out.append({
            "id": h["Id"],
            "type": c.get("Type", "?"),
            "target": c.get("FullyQualifiedDomainName") or c.get("IPAddress") or "?",
            "path": c.get("ResourcePath", ""),
            "interval": c.get("RequestInterval"),
            "threshold": c.get("FailureThreshold"),
        })
    return out


def fetch_day(hc_id: str, day_start: datetime) -> list[tuple[datetime, float]]:
    """하루치 1분 데이터. GetMetricStatistics 1440점 한도에 맞춘 단위다."""
    d = aws(
        "cloudwatch", "get-metric-statistics",
        "--region", "us-east-1",            # Route53 지표는 us-east-1 에만 올라간다
        "--namespace", "AWS/Route53",
        "--metric-name", "HealthCheckStatus",
        "--dimensions", f"Name=HealthCheckId,Value={hc_id}",
        "--start-time", day_start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "--end-time", (day_start + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "--period", "60",
        "--statistics", "Minimum",
    )
    pts = [(datetime.fromisoformat(p["Timestamp"].replace("Z", "+00:00")), float(p["Minimum"]))
           for p in d.get("Datapoints", [])]
    return sorted(pts)


def main() -> int:
    ap = argparse.ArgumentParser(description="판정 창 #1 구간 기록 — 읽기 전용")
    ap.add_argument("--since", help="구간 시작(UTC, 예: 2026-10-22T00:00:00Z)")
    ap.add_argument("--until", help="구간 끝(UTC, 배타적)")
    ap.add_argument("--week", type=int, help="창 N주차를 자동 계산(1부터). --since/--until 대신")
    ap.add_argument("--out", help="결과 폴더(기본 ./edge-availability-<시작>_<끝>)")
    ap.add_argument("--health-check-id", action="append", help="좁힐 헬스체크 ID(여러 번 가능)")
    a = ap.parse_args()

    # ── 구간 정하기
    if a.week:
        s = WINDOW_START + timedelta(days=7 * (a.week - 1))
        e = min(s + timedelta(days=7), WINDOW_END)
        if s >= WINDOW_END:
            raise SystemExit(f"창({WINDOW_START:%m/%d}~{WINDOW_END:%m/%d})에 {a.week}주차가 없다")
    elif a.since and a.until:
        s = datetime.fromisoformat(a.since.replace("Z", "+00:00"))
        e = datetime.fromisoformat(a.until.replace("Z", "+00:00"))
    else:
        raise SystemExit("--week N 또는 --since/--until 중 하나는 있어야 한다")

    now = datetime.now(timezone.utc)
    if e > now:
        e = now.replace(second=0, microsecond=0)
        print(f"  ⚠️ 끝 시각이 미래라 지금({e:%Y-%m-%d %H:%M}Z)까지만 뜬다")

    # 🔴 만료 경고 — 이 스크립트의 존재 이유다. 늦으면 뜰 것이 없다.
    expire = now - timedelta(days=RETENTION_DAYS_1MIN)
    if s < expire:
        lost = (expire - s).days
        print(f"  🔴 경고: 구간 시작({s:%Y-%m-%d})이 1분 보존 한계({expire:%Y-%m-%d})보다 "
              f"{lost}일 이르다. 그만큼은 이미 만료됐을 수 있다.")

    out = a.out or f"./edge-availability-{s:%Y%m%d}_{e:%Y%m%d}"
    os.makedirs(out, exist_ok=True)

    checks = health_checks(a.health_check_id)
    if not checks:
        raise SystemExit("헬스체크를 찾지 못했다 — 계정/권한 확인")

    print(f"  구간 {s:%Y-%m-%d %H:%M}Z ~ {e:%Y-%m-%d %H:%M}Z ({(e - s).days}일 "
          f"{(e - s).seconds // 3600}시간) · 헬스체크 {len(checks)}개")

    expected_total = int((e - s).total_seconds() // 60)
    summary = []

    for hc in checks:
        pts: list[tuple[datetime, float]] = []
        day = s
        while day < e:
            pts += [p for p in fetch_day(hc["id"], day) if s <= p[0] < e]
            day += timedelta(days=1)

        ok = sum(1 for _, v in pts if v >= 1)
        bad = len(pts) - ok
        gap = expected_total - len(pts)
        avail = ok / len(pts) if pts else 0.0

        csv_path = os.path.join(out, f"{hc['type'].lower()}_{hc['id'][:8]}.csv")
        with open(csv_path, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["timestamp_utc", "minimum"])
            for t, v in pts:
                w.writerow([t.strftime("%Y-%m-%dT%H:%M:%SZ"), int(v)])

        summary.append({**hc, "points": len(pts), "expected": expected_total, "gap": gap,
                        "ok": ok, "bad": bad, "availability": avail, "csv": os.path.basename(csv_path)})
        flag = "🔴" if gap > 0 else "  "
        print(f"  {flag} {hc['type']:<5} {hc['id'][:8]} {hc['target'][:34]:<34} "
              f"{len(pts):>5}/{expected_total} 점 · 정상 {ok} · 비정상 {bad} · {avail * 100:.3f}%")

    # ── 기록 파일 — 창 전체를 합칠 때 이 숫자들을 가중 평균한다
    md = os.path.join(out, "구간기록.md")
    with open(md, "w") as f:
        f.write(f"# 판정 창 #1 구간 기록 — {s:%Y-%m-%d} ~ {e:%Y-%m-%d}\n\n")
        f.write(f"- 뜬 시각: {now:%Y-%m-%d %H:%M:%S}Z\n")
        f.write(f"- 구간: `{s:%Y-%m-%dT%H:%M:%SZ}` ~ `{e:%Y-%m-%dT%H:%M:%SZ}` (배타적)\n")
        f.write(f"- 구간 길이: {int((e - s).total_seconds() // 60):,}분\n")
        f.write(f"- 목표: #1 외부 진입 성공률 ≥ {TARGET * 100}%\n\n")
        f.write("| 헬스체크 | 종류 | 대상 | 데이터점 | 기대 | 공백 | 정상 | 비정상 | 가용성 | CSV |\n")
        f.write("|---|---|---|---|---|---|---|---|---|---|\n")
        for r in summary:
            f.write(f"| `{r['id'][:8]}` | {r['type']} | `{r['target']}{r['path']}` | {r['points']:,} | "
                    f"{r['expected']:,} | {r['gap']:,} | {r['ok']:,} | {r['bad']:,} | "
                    f"**{r['availability'] * 100:.3f}%** | `{r['csv']}` |\n")
        f.write("\n## 창 전체로 합치는 법\n\n")
        f.write("구간마다 이 표의 **정상**과 **데이터점**을 더해서 `sum(정상) / sum(데이터점)` 으로 낸다.\n")
        f.write("구간 길이가 달라도(마지막 주 5일) 점 수가 가중치 역할을 하므로 따로 보정하지 않는다.\n\n")
        if any(r["gap"] > 0 for r in summary):
            f.write("## 🔴 공백이 있다\n\n")
            f.write("데이터점이 기대보다 적다. 둘 중 하나다 — ⑴ 1분 보존(15일)을 넘겨 만료됐다 ")
            f.write("⑵ 그 구간에 CloudWatch 가 지표를 받지 못했다. **공백은 \"정상\"도 \"장애\"도 아니다 — ")
            f.write("분모에서 빼고 그 사실을 판정 문서에 적는다.**\n\n")
        f.write("## 비고\n\n")
        f.write("- TCP 헬스체크는 ALB 주소의 443 포트만 본다. 파드가 막혀도 ALB 가 살아 있으면 정상으로 남는다 ")
        f.write("(SIM-11a 기대 기-4와 같은 성질). **#1 판정은 HTTPS `/readyz` 쪽으로 한다.**\n")
        f.write(f"- CloudWatch 1분 해상도는 {RETENTION_DAYS_1MIN}일만 보관한다. ")
        f.write("이 기록을 주 1회 거르지 않는 것이 유일한 보존 수단이다.\n")

    print(f"\n  → {out}/")
    print(f"     구간기록.md + CSV {len(summary)}개")
    return 0


if __name__ == "__main__":
    sys.exit(main())
