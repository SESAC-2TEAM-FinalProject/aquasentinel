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
| **맞출 기준** | 시크릿(새 값) | 🔴 **`aquasentinel-db/aquasentinel-pg-app`** — 아래 0.1 |

🔸 **두 값이 이미 같으면 이 런북은 「확인만」 하고 지나갑니다.** 같은지 다른지는 **미리 알 수 없습니다**(비밀값 조회 금지). **2번에서 `/readyz` 와 PG 로그로 드러납니다** — 그래서 이 단계를 건너뛰면 안 됩니다.

### 0.1 🔴🔴 「맞출 기준」이 **6단계에서 바뀝니다** `[2026-10-28 리허설 실측]`

위 표의 「Secrets Manager 쪽」만 보고 **`web/aquasentinel-pg-app` 의 값**을 기준으로 삼으면 **1시간 안에 다시 깨집니다.** 10/28 실측입니다(값은 적지 않고 sha256 앞 12자로만):

| 값 | 어디 | 10/28 |
|---|---|---|
| **A** | 도쿄 `aquasentinel-db/aquasentinel-pg-app` — **CNPG 가 부트스트랩에서 새로 만든 것** | `ff194546c74d` |
| **B** | 도쿄 `web/aquasentinel-pg-app` — ExternalSecret 이 **옛날에** 읽어 둔 것 | `5436d5dfa712` |
| **S** | 서울 `aquasentinel-db/aquasentinel-pg-app` — 🔴 **복구된 DB 안에 실제로 들어 있는 값** | `427c4892e4c2` |
| **SM** | Secrets Manager `…-api-module-database-password` **현재** | **= A** |

**무슨 일이 일어나는가**

1. CNPG 는 recovery 부트스트랩에서 `app` **역할 비밀번호를 바꾸지 않습니다** → DB 안은 **S**(백업 뜬 쪽 값)
2. 그런데 CNPG 는 **새 시크릿 A** 를 만듭니다 → DB 와 불일치
3. 🔴 **6단계 깨우기가 PushSecret `aquasentinel-db/api-module-database` 를 되살리고, 그것이 Secrets Manager 를 A 로 덮어씁니다.** 10/28 엔 그 비밀의 `LastChangedDate` 가 **6단계 apply 시각과 초 단위로 같았습니다**
4. `web/` 쪽은 아직 **B**(낡은 값). ExternalSecret 갱신 주기가 **1시간**이라, 그냥 두면 최대 1시간 뒤 A 로 바뀝니다

→ 🔴 **기준은 A = `aquasentinel-db/aquasentinel-pg-app` 입니다.** PushSecret 이 그 값을 Secrets Manager 로 밀고, 모든 ExternalSecret 이 결국 그 값으로 수렴하기 때문입니다.

🔸 **값을 비교해야 할 때는 해시로 합니다** — 값 자체를 찍지 않습니다:

```bash
h() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }
A=$(kubectl --context "$TOKYO" -n aquasentinel-db get secret aquasentinel-pg-app -o jsonpath='{.data.password}' | base64 -d)
Bv=$(kubectl --context "$TOKYO" -n web get secret aquasentinel-pg-app -o jsonpath='{.data.password}' | base64 -d)
echo "A=$(h "$A")  B=$(h "$Bv")"   # 다르면 2~4번을 돌립니다
```

🔴 **Secrets Manager 는 `SecretBinary` 로 저장돼 있습니다** — `--query SecretString --output text` 로 읽으면 `None`(4글자)이 나와 **엉뚱한 비교를 하게 됩니다.** 10/28 에 제가 실제로 당했습니다. 읽어야 하면:

```bash
aws secretsmanager get-secret-value --region ap-northeast-1 \
  --secret-id aquasentinel-dr-tokyo-api-module-database-password --output json \
 | python3 -c 'import sys,json,base64; d=json.load(sys.stdin); b=d.get("SecretBinary"); print(len(base64.b64decode(b).decode()) if b else len(d.get("SecretString") or ""))'
# 길이만 찍습니다. 값은 찍지 않습니다.
```

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
| 2 | **`app` 역할 비밀번호를 시크릿 값으로** | 아래 2.1 (🔴 값은 **stdin** 으로만) | `psql "host=… user=app"` 접속 성공 | 🔴 **기준은 A** — 0.1 |
| 3 | **PushSecret 강제 동기화** | `kubectl annotate pushsecret -n aquasentinel-db api-module-database force-sync=$(date +%s) --overwrite` | Synced · 갱신 시각이 지금 | 🔸 **②③ 깨우기(1부 6단계) 뒤에만** 존재 — 1부 순서가 이미 그렇습니다 |
| 4 | **그 값을 읽는 ExternalSecret 전부 강제 동기화** | `kubectl get externalsecret -A` 에서 DB `app` 키를 읽는 것에 `force-sync` 주석 | 각 `status.refreshTime` 이 3번 뒤 | ✅ 방식 같음 — 읽는 키만 `dr-tokyo-*` |
| 5 | **`keycloak` · `grafana_ro` 역할 재적용** | `keycloak-db-password` · `grafana-db-ro-password` 시크릿에 **아무 주석이나** 달아 변경을 일으킴 | `kubectl get databaserole -n aquasentinel-db` → `applied=true` · `secretResourceVersion` 바뀜 | ✅ **그대로** — 역할·시크릿 이름이 양 리전 같습니다 |
| 6 | **DB 를 쓰는 파드 재시작** | 아래 3장 | 파드 Ready · `/readyz` **200** · PG 로그 `password authentication failed` **0** | 🔸 **Rollout 6개**(1장) |
| 7 | WAL 경로 · 첫 기준 백업 | `WAL아카이빙.md` (A-2) | WAL 아카이브 성공 · `CnpgBackupMissing` 해제 | 🔴 **새 serverName 불필요** — 아래 4장 |
| 8 | 처리 상태 확인 | 처리 누락 대조 · 큐 적체 | 누락 0 · 적체 0 | ✅ 그대로 |

🔴 **2 → 3 → 4 를 이어서 합니다.** ExternalSecret 갱신 주기가 **1시간**이라 강제 동기화를 빼면 최대 1시간 동안 옛 값입니다. **6번은 4번이 끝난 뒤**입니다.

### 2.1 2번 명령 — 🔴 값이 `ps` 에 안 보이게

```bash
# 기준값 A 를 변수로만 읽고, SQL 은 stdin 으로 넘깁니다(argv 는 ps 에 보입니다)
A=$(kubectl --context "$TOKYO" -n aquasentinel-db get secret aquasentinel-pg-app \
      -o jsonpath='{.data.password}' | base64 -d)
ESC=$(printf '%s' "$A" | sed "s/'/''/g")        # SQL 리터럴 이스케이프
printf "ALTER ROLE app PASSWORD '%s';\n" "$ESC" \
 | kubectl --context "$TOKYO" -n aquasentinel-db exec -i aquasentinel-pg-1 -c postgres -- \
   psql -U postgres -q -v ON_ERROR_STOP=1

# 바로 검증 — 값은 stdin 으로만 넘깁니다
printf '%s' "$A" | kubectl --context "$TOKYO" -n aquasentinel-db exec -i aquasentinel-pg-1 -c postgres -- \
  sh -c 'read -r P; PGPASSWORD="$P" psql -h 127.0.0.1 -U app -d app -tAc "SELECT current_user, pg_is_in_recovery();"'
# 🔴 기대: app|f   (f = 승격된 Primary)
```

🔸 10/28 리허설에서 이 두 명령으로 통과했습니다 `[사실]`. 🔴 **`ALTER ROLE` 은 Primary 에서만 됩니다** — 5단계 승격이 끝난 뒤여야 합니다.

---

### 2.2 🔴🔴 ALTER 만으로는 안 붙습니다 — **시크릿 전파가 남아 있습니다** `[2026-10-28 실측]`

`ALTER ROLE` 은 **2초**면 끝나는데, 10/28 에는 그 뒤로도 파드가 **7분 넘게** 계속
`password authentication failed` 였습니다. 비밀번호가 파드까지 가는 길이 **두 군데**에서 막힙니다.

| 막히는 곳 | 왜 |
|---|---|
| **ExternalSecret** | 새로고침 주기가 **1시간**입니다. PushSecret 이 Secrets Manager 에 올린 새 값을 바로 안 가져옵니다 |
| **파드의 env** | 비밀번호를 **마운트가 아니라 env** 로 받습니다. 파드가 **뜰 때** 한 번 읽으므로, 시크릿이 바뀌어도 그 파드는 옛 값 그대로입니다 |

**그래서 ALTER 바로 뒤에 이 둘을 합니다** — 자세한 명령과 실측 표는
`DR훈련_당일진행.md` **1장 ②-1** 에 있습니다.

```bash
# ① ExternalSecret 전부 강제 새로고침
for NS in api-module web; do
  for E in $(kubectl --context "$TOKYO" -n $NS get externalsecret -o name); do
    kubectl --context "$TOKYO" -n $NS annotate "$E" force-sync="$(date +%s)" --overwrite
  done
done

# ② 갱신 시각보다 먼저 뜬 파드 중 Ready 가 아닌 것을 **이름으로** 지웁니다(3장 참고)
```

🔸 10/28 에 `api-module` 4종은 CrashLoop 재시도로 **스스로** 붙었고, `web-backend`·`alert-worker`
처럼 **재시도 간격이 길거나 죽지 않는** 파드만 재기동이 필요했습니다.


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

🔴🔴 **함정 — Rollout 이 Degraded 면 `restartAt` 이 파드를 바꾸지 않습니다** `[2026-10-28 리허설 실측]`

```
$ kubectl -n web get rollout web-backend -o jsonpath='{.spec.restartAt} {.status.phase} {.status.message}'
2026-10-28T07:00:04Z  Degraded  ProgressDeadlineExceeded: ReplicaSet "web-backend-7fc4694c74" has timed out progressing.
```

`restartAt` 은 **걸려 있는데** 파드가 21분째 그대로였습니다. 같은 명령으로 `web-frontend`·`alert-worker` 는 정상 재시작됐습니다 — **Degraded 인 Rollout 만** 안 바뀝니다. 비밀번호가 안 맞아 `/readyz` 가 실패하면 Rollout 이 바로 그 Degraded 상태이므로, **이 단계에서 거의 항상 걸립니다.**

**대처 — 파드를 직접 지웁니다**(ReplicaSet 이 새 시크릿으로 다시 만듭니다):

```bash
# 🔴 라벨이 아니라 이름으로 지웁니다 — app.kubernetes.io/name 라벨이 없습니다(10/28 확인)
kubectl --context "$TOKYO" -n web get pods --no-headers | awk '/^web-backend/{print $1}' \
 | xargs -r kubectl --context "$TOKYO" -n web delete pod
```

🔸 10/28 엔 삭제 **53초** 뒤 `web-backend` 2파드가 `1/1` 이 되고 PG 인증 실패가 **30건/분 → 0** 이 됐습니다.

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
