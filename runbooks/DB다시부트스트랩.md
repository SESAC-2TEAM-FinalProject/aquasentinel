# 런북 — 복구한 DB 비밀번호 맞추기(DB 다시 부트스트랩)

- 대상: 도쿄 DR `aquasentinel-db/aquasentinel-pg` · 서울 운영 · 시험 구역 (이름은 **양 리전 같습니다** `[사실]`)
- 초안 2026-10-27 · **C(재희)** — 10/26 시험 구역 2 를 골든 G0R4 백업으로 다시 부트스트랩할 때의 실제 손 작업(약 18분)
- **도쿄 적용분 2026-10-27 · A(원주)** — 아래 🔸🔴 표시가 도쿄에서 달라지는 곳입니다
- 🔴 **훈련 단계**(계획서 3.1 · 부록 B): **1부 7단계(④ 비밀번호)** · **2부 5단계**. ⑤ 드릴 레코드 **전에** 끝나야 화면이 뜹니다
- **관련**: `DR테스트_계획서_도쿄리전전환훈련_최종본_2026-10-27.md` **7장 #8 보충** · 런북 `WAL아카이빙.md` · `드릴레코드_전환.md`

> **한 줄** — 백업에서 복구한 DB 안에는 **백업을 뜬 쪽의 비밀번호**가 그대로 있습니다. 바깥(시크릿)과 어긋나면 DB 를 쓰는 파드가 **전부 인증 실패**합니다. 그 둘을 맞추고, 맞춘 값을 **읽는 쪽까지 밀어 넣은 뒤**, 파드를 재시작합니다.

🔴 **비밀값은 화면 · 로그 · 문서 · MR 어디에도 적지 않습니다.** 변수로만 옮깁니다(`scripts/alerting/README.md:26` · 재희님 10/27 지시).

---

## 0. 왜 필요한가 — 그리고 도쿄는 왜 다른가

CNPG 는 recovery 부트스트랩 때 `app` 역할 비밀번호를 **바꾸지 않습니다**(관리 역할이 아님). 그래서 DB 안 값과 바깥 시크릿이 어긋납니다. 10/26 에 `web-backend` 가 옛 비밀번호로 떠서 `/readyz` 가 실패했습니다.

🔴 **어긋나는 방향이 리전마다 반대입니다** — 맞출 **기준**이 달라집니다.

| | 서울 · 시험 구역 | 🔴 도쿄 |
|---|---|---|
| `aquasentinel-pg-app`(`web` ns) 의 출처 | CNPG 가 만든 값 → **PushSecret** → ExternalSecret | 🔴 PushSecret 이 **standby 에서 제거**돼 있고, ExternalSecret 이 **Secrets Manager 의 `aquasentinel-dr-tokyo-api-module-database-*` 를 바로** 읽습니다 |
| 어긋나는 방향 | DB 는 옛 값 · 시크릿은 **새 값** | 🔴 DB 는 **백업 뜬 시점의 서울 값** · 시크릿은 **Secrets Manager 에 고정된 값** |
| **맞출 기준** | 시크릿(새 값) | 🔴 **Secrets Manager 쪽** |

🔸 **두 값이 이미 같으면 이 런북은 「확인만」 하고 지나갑니다.** 같은지 다른지는 **미리 알 수 없습니다**(비밀값 조회 금지). **2번에서 `/readyz` 와 PG 로그로 드러납니다** — 그래서 이 단계를 건너뛰면 안 됩니다.

---

## 1. 기준값 — 지금 정상 모습 (2026-10-27 서울 실측 `[사실]`)

| 무엇 | 수 | 이름 |
|---|---|---|
| **Rollout** | **6** | `api-module/{evaluation, grading, interpolation, processor}` · `web/{web-backend, web-frontend}` |
| **Deployment**(DB 사용) | **2** | `api-module/completeness-check` · `web/alert-worker` |
| **PushSecret** | **1** | `aquasentinel-db/api-module-database` 🔴 **도쿄 standby 에는 없습니다** |
| **DatabaseRole** | **2** | `aquasentinel-db/aquasentinel-pg-keycloak` · `aquasentinel-pg-grafana-ro` |

🔴 **부록 A 초안은 `web-backend` 만 적었습니다.** `web-frontend` 도 **Rollout** 이라 일괄 재시작할 때 같이 `restartAt` 이어야 합니다(DB 를 안 쓰므로 필수는 아니고, **Deployment 방식으로 재시작하면 안 되는 것**이 요점입니다).

---

## 2. 순서

| # | 무엇 | 명령(예) | 끝났다고 보는 확인 | 도쿄 |
|---|---|---|---|---|
| 1 | 복구 끝 확인 | `kubectl get cluster -n aquasentinel-db aquasentinel-pg` | Ready 3/3 · 승격했으면 `pg_is_in_recovery()=f` | ✅ 그대로 |
| 2 | **`app` 역할 비밀번호를 시크릿 값으로** | 시크릿에서 값을 **변수로** 읽어 Primary 에서 `ALTER ROLE app PASSWORD …` | `psql "host=… user=app"` 접속 성공 | 🔴 **기준이 Secrets Manager** — 0장 표 |
| 3 | **PushSecret 강제 동기화** | `kubectl annotate pushsecret -n aquasentinel-db api-module-database force-sync=$(date +%s) --overwrite` | Synced · 갱신 시각이 지금 | 🔸 **②③ 깨우기(1부 6단계) 뒤에만** 존재 — 1부 순서가 이미 그렇습니다 |
| 4 | **그 값을 읽는 ExternalSecret 전부 강제 동기화** | `kubectl get externalsecret -A` 에서 DB `app` 키를 읽는 것에 `force-sync` 주석 | 각 `status.refreshTime` 이 3번 뒤 | ✅ 방식 같음 — 읽는 키만 `dr-tokyo-*` |
| 5 | **`keycloak` · `grafana_ro` 역할 재적용** | `keycloak-db-password` · `grafana-db-ro-password` 시크릿에 **아무 주석이나** 달아 변경을 일으킴 | `kubectl get databaserole -n aquasentinel-db` → `applied=true` · `secretResourceVersion` 바뀜 | ✅ **그대로** — 역할·시크릿 이름이 양 리전 같습니다 |
| 6 | **DB 를 쓰는 파드 재시작** | 아래 3장 | 파드 Ready · `/readyz` **200** · PG 로그 `password authentication failed` **0** | 🔸 **Rollout 6개**(1장) |
| 7 | WAL 경로 · 첫 기준 백업 | `WAL아카이빙.md` (A-2) | WAL 아카이브 성공 · `CnpgBackupMissing` 해제 | 🔴 **새 serverName 불필요** — 아래 4장 |
| 8 | 처리 상태 확인 | 처리 누락 대조 · 큐 적체 | 누락 0 · 적체 0 | ✅ 그대로 |

🔴 **2 → 3 → 4 를 이어서 합니다.** ExternalSecret 갱신 주기가 **1시간**이라 강제 동기화를 빼면 최대 1시간 동안 옛 값입니다. **6번은 4번이 끝난 뒤**입니다.

---

## 3. 6번 — 재시작 방식 (여기서 10/26 에 사고가 났습니다)

🔴 **Rollout 을 Deployment 쪽에서 재시작하면 안 됩니다.** api-module Rollout 은 Deployment 를 `workloadRef` 로 참조해서, Deployment 재시작이 **Rollout 새 판 카나리**가 됩니다. 10/26 에 `processor` 카나리가 fail-rate 로 중단돼 손으로 되돌렸습니다.

```bash
# Rollout 6개 — restartAt (또는 kubectl argo rollouts restart)
TS=$(date -u +%FT%TZ)
for r in evaluation grading interpolation processor; do
  kubectl patch rollout "$r" -n api-module --type merge -p "{\"spec\":{\"restartAt\":\"$TS\"}}"
done
for r in web-backend web-frontend; do
  kubectl patch rollout "$r" -n web --type merge -p "{\"spec\":{\"restartAt\":\"$TS\"}}"
done

# Deployment 2개
kubectl rollout restart deploy/completeness-check -n api-module
kubectl rollout restart deploy/alert-worker -n web
```

🔸 **Keycloak 은 인증 실패가 실제로 보일 때만** 재시작합니다.

🔴 **한꺼번에 하지 않습니다** — 파드가 몰리면 온디맨드 자리 계산이 밀려 카펜터 `general` 노드가 1대 뜹니다. **api-module → web → 나머지** 묶음으로 나눕니다.

---

## 4. 7번 — 도쿄는 「새 serverName」이 필요 없습니다

도쿄는 **쓰는 경로가 이미 갈려 있습니다** `[사실]` — 자기 백업은 `cloudnativepg-tokyo/` 로 가고, 서울 백업 복제본 `cloudnativepg/` 와 섞이지 않습니다. 그래서 serverName 을 바꿀 이유가 없습니다.

🔴 **대신 훈련이 끝날 때마다 `cloudnativepg-tokyo/` 를 비워야 합니다** — 계획서 **6.3 #6-1**. 안 비우면 다음 구축이 `Expected empty archive` 로 막힙니다. **결정 ①(나눠서)로 도쿄를 두 번 세우므로 이번에 반드시 걸립니다.**

🔴 **`cloudnativepg/`(서울 백업 복제본)는 지우면 안 됩니다** — 그게 DR 로 복구할 원본입니다.

---

## 5. 함정 모음 (10/26 실제)

| 함정 | 무슨 일 | 피하는 법 |
|---|---|---|
| Rollout 을 Deployment 쪽에서 재시작 | 새 판 카나리가 떠서 fail-rate 중단 | 3장 — `restartAt` |
| 2 · 3 · 4 순서를 바꿈 | 최대 1시간 옛 값 | 이어서 · 6은 4 뒤 |
| 재시작을 한꺼번에 | 카펜터 `general` 노드 1대 뜸 | 묶음별로 |
| 같은 WAL 경로에 이어 쓰기 | 타임라인이 겹쳐 `Expected empty archive` | 서울·시험구역은 새 serverName · **도쿄는 4장(뒷정리)** |
| 🔴 값을 명령줄·로그에 남김 | `ps` 와 셸 이력에 남음 | 변수로만 · `--secret-string file://` 경유 |

---

## 6. 나중에 자동화할 후보 (C 제안)

- **2번**: `cluster.yaml` 의 `managed.roles` 로 `app` 비밀번호를 CNPG 가 관리하게 → 손 작업 없어짐
- **5번**: 시크릿 변경 감지 대신, 복구 직후 DatabaseRole 재적용을 코드에
