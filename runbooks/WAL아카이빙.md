# 런북 — CNPG WAL 아카이빙 「Expected empty archive」 대응

- 대상: 서울 운영 `aquasentinel-db/aquasentinel-pg`(CNPG 1.30.0 · barman-cloud 플러그인) · 도쿄 DR · 시험 구역
- 작성 2026-10-23 · C(재희) — 라이브 조회 반영(10/23 02:45 UTC 전후, 읽기만) · 검수 A(원주)
- 근거: 10/12 구 Primary 복귀 실패(DR 계획서 2.3 · 리스크 R5) · 10/13 재구축 뒤 아카이빙 실패(종합정리 A-26 · R-14) · 원주 회신 「WAL 재발 방지(B안) 진행 여부」(10/23) 2 · 6장
- **이 문서는 운영을 바꾸지 않습니다.** 명령은 표시한 곳(🔴 변경)만 운영 변경이고 나머지는 읽기입니다

> **한 줄** — 같은 오류가 두 경우에 납니다. **(A) 서울 DB를 새로 만들 때** 경로에 다른 클러스터의 백업이 남아 있으면, **(B) 전환(switchover · failover) 뒤 구 Primary가 레플리카로 돌아올 때** 상태가 갈라져 있으면. (A)는 만들기 **전에** 경로를 확인해 막고, (B)는 **뒤에** 그 인스턴스를 새로 받아(풀 재동기화) 풉니다.

---

## 0. 기준값 — 지금 정상 모습 (서울 운영 10/23)

| 항목 | 값 | 확인 명령(읽기) |
|---|---|---|
| 클러스터 | `aquasentinel-pg` · 인스턴스 3 · Primary `aquasentinel-pg-1` · 타임라인 6 · `Cluster in healthy state` | `kubectl -n aquasentinel-db get cluster aquasentinel-pg -o jsonpath='{.status.currentPrimary} {.status.readyInstances}/{.status.instances} tl={.status.timelineID} {.status.phase}{"\n"}'` |
| 조건 | `ContinuousArchiving=True`(ContinuousArchivingSuccess) · `LastBackupSucceeded=True` · `ConsistentSystemID=True` | `kubectl -n aquasentinel-db get cluster aquasentinel-pg -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'` |
| 아카이버(Primary) | 성공 2,617 · 마지막 성공 `000000060000000B00000054` 02:45:23 · **실패 누적 2 · 마지막 실패 `00000006.history` 10/14 06:28:43** | `kubectl -n aquasentinel-db exec <Primary> -c postgres -- psql -At -c "select archived_count,last_archived_wal,last_archived_time,failed_count,last_failed_wal,last_failed_time from pg_stat_archiver"` |
| 복제 | `aquasentinel-pg-2` · `-3` streaming(async) | `… psql -At -c "select application_name,state,sync_state from pg_stat_replication"` |
| 아카이브 경로 | ObjectStore `aquasentinel-backup-store` → `s3://aquasentinel-dev-observability-379937169195/cloudnativepg/` · serverName 없음 = 클러스터 이름 → 실제 경로 `…/cloudnativepg/aquasentinel-pg/`(`base/` · `wals/`) | `kubectl -n aquasentinel-db get objectstores.barmancloud.cnpg.io -o custom-columns=N:.metadata.name,DEST:.spec.configuration.destinationPath,SN:.spec.configuration.serverName` |
| PVC | 인스턴스마다 데이터 PVC 1개(`aquasentinel-pg-1` ~ `-3` · 10Gi · gp2) — WAL 전용 PVC 없음 | `kubectl -n aquasentinel-db get pvc` |
| 정기 백업 | 매일 18:00 UTC(`aquasentinel-pg-backup-YYYYMMDD180000`) | `kubectl -n aquasentinel-db get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp` |

- Primary 찾기: `.status.currentPrimary` 또는 파드 라벨 `cnpg.io/instanceRole=primary`(`role=primary`도 붙음)
- `kubectl cnpg` 플러그인 없이 쓰는 명령만 적었습니다
- 🔴 **이 표에서 「같아야 하는 값」은 실패 쪽뿐입니다** — 성공 수(`archived_count`)와 `last_archived_wal`은 **계속 늘어나는 게 정상**이라 이 표와 달라도 이상이 아닙니다(작성 시점 2,617 → 10/23 04:1x 2,632). 볼 것은 **`failed_count`가 2에서 늘었는지**와 **`last_failed_wal`이 `00000006.history`(10/14 06:28:43)에서 바뀌었는지** 둘입니다. 늘었거나 바뀌었으면 1장으로

## 1. 경보가 왔을 때 — 어느 쪽인지 가르기

| 경보(운영 반영) | 뜻 |
|---|---|
| `CnpgWalArchivingFailing`(10분) | 마지막 실패가 마지막 성공보다 나중 — 아카이빙이 지금 실패 중 |
| `CnpgWalArchivingStale`(5분) | 마지막 아카이빙이 30분 넘게 없음 |
| `CnpgReplicaNotStreaming`(5분) | 레플리카가 스트리밍하지 않음 — (B)에서 같이 뜰 수 있음 |
| `CnpgMetricsAbsent`(10분) | 해당 인스턴스의 지표가 아예 안 올라옴 — **(B)에서 파드가 Ready로 못 돌아오면 같이 뜬다.** 이 경보만 단독이면 아카이빙이 아니라 수집 쪽을 먼저 본다 |
| (참고) `CnpgReplicationLagHigh`(10분) · `CnpgBackupFailed` · `CnpgBackupMissing` | 같은 묶음 경보 |

> 운영에 반영된 CNPG 경보는 **7개 전부** 위 표에 있습니다(10/23 `kubectl get prometheusrules -A` 전수 확인).

**판별 순서**

1. 아카이버 확인(0장 명령) — `last_failed_wal` · `last_failed_time`
2. 오류 문구 확인 — `kubectl -n aquasentinel-db logs <해당 인스턴스> -c postgres --since=1h | grep -i -E "expected empty archive|barman-cloud-check-wal-archive|archive_command|WAL archive"`
3. 가르기

| 상황 | 판단 | 갈 곳 |
|---|---|---|
| 실패가 **`.history` 파일 1건**이고 그 뒤 성공이 이어짐 · `ContinuousArchiving=True` | **타임라인 전환 때 한 번 나는 실패** — 지금 정상. 운영 10/14 06:28(`00000006.history`) · 시험 구역 2 10/19 10:37(`00000007.history`, 복구 직후) 둘 다 이 모양이었고 그 뒤 실패 0 | 조치 없음 · 시각만 기록 |
| 클러스터를 **새로 만든 직후**(재구축 · 다른 계정 · 같은 이름) 아카이빙이 계속 실패 · `Expected empty archive` | **(A)** | 2장 — 원래는 만들기 **전에** 2.1로 막아야 함 |
| **전환(switchover · failover · 노드 교체) 뒤** 구 Primary가 레플리카로 안 올라옴 · `ContinuousArchiving=False` 또는 해당 인스턴스 Ready 아님 · `Expected empty archive` | **(B)** | 3장 |

## 2. (A) 재구축 전 — 서울 DB를 새로 만들기 전에

언제: 서울 클러스터를 지우고 같은 이름(`aquasentinel-pg`)으로 다시 만들 때 — 재구축 · 페일백(범위 밖이지만 시도할 때) · 시험 구역이 운영 버킷에 **쓰게** 바뀔 때

### 2.1 사전 점검 (만들기 전 — 읽기)

```bash
aws s3 ls s3://aquasentinel-dev-observability-379937169195/cloudnativepg/
aws s3 ls s3://aquasentinel-dev-observability-379937169195/cloudnativepg/aquasentinel-pg/base/
# 비어 있으면 그대로 진행 / 있으면 2.2
```

- 🔸 운영 버킷 목록 권한이 있는 계정으로(재희 계정 `aquasentinel-member-jaehee`는 `s3:ListBucket` 거부)
- ✅ **두 줄 다 실행 확인**(원주 10/23 04:1x UTC) — `cloudnativepg/` 아래는 `aquasentinel-pg/` **하나뿐**, `base/` 목록도 정상(`20261013T011007` 외). 10/23 기준 2,873 객체 · 약 3.00 GB

### 2.2 있으면 — 둘 중 하나

**(A-1) 비우기** — 경로를 비워서 새 클러스터가 쓸 수 있게 한다

> 🔴 **「옛 것만 골라 지운다」가 아닙니다.** `base/` 는 systemID로 골라 지우지만 **`wals/` 는 통째로** 지웁니다(3번). 그래서 **새 클러스터를 만들기 전에만** 할 수 있습니다.

1. 새로 만들 클러스터가 아직 없을 때만 한다(지금 클러스터의 백업을 지우면 시점 복구를 잃음)
2. `base/<backupID>/backup.info`의 **`systemid`로 가른다** — 🔴 **날짜 기준으로 지우지 않는다**(10/13 창영님 조건)
   ```bash
   aws s3 cp s3://…/cloudnativepg/aquasentinel-pg/base/<backupID>/backup.info - | grep -i systemid
   ```
3. 🔴 변경 — **삭제 대상은 세 가지입니다**(10/13에 실제로 지운 범위 · 원주 검수 10/23)

   | # | 지울 것 | 왜 |
   |---|---|---|
   | 1 | 옛 systemID의 `base/<backupID>/` — **10/13에는 3개** | 2번에서 가른 것 |
   | 2 | 🔴 **미완료 systemID의 `base/<backupID>/` — 10/13에는 2개** | 백업이 중간에 끊긴 것. `backup.info`가 없거나 불완전해 2번으로 안 갈리는데, **남아 있으면 안전검사에 그대로 걸립니다** |
   | 3 | 🔴 **`wals/` 전체** | 아래 |

   🔴 **`wals/`는 골라 지우지 않고 통째로 지웁니다.** 10/13에 그렇게 했습니다(개선안 v1 「옛 systemID 백업 3개 + 미완료 systemID 2개 + `wals/` 전체 삭제, 그날 성공 백업만 보존」).
   - **왜 통째로인가**(🔸 이 설명은 해석입니다 — 실측은 「전체를 지웠다」까지) — WAL 파일 이름에는 systemID가 없어서 **목록만 보고는 어느 DB 것인지 못 가릅니다.** 골라 지우려다 몇 개 남기면 **안전검사에 똑같이 다시 걸립니다**
   - **잃는 것** — 그 시점까지의 **시점 복구(PITR)**. 그래서 **1번 조건**(새 클러스터가 아직 없을 때만)이 반드시 먼저입니다
   - **되찾는 것** — 새 클러스터를 만든 직후 **기준 백업 1회**(A-2 3번 명령)를 하면 그때부터 다시 쌓입니다. **이 백업을 빼먹으면 복구 지점이 없는 상태로 운영됩니다**

4. 도쿄 복제(`replicate-to-tokyo`)로 **도쿄에서도 같이 지워질 수 있습니다** — 지우기 전에 알고 합니다
   - 🔸 **미확인** — 재희님 초안의 `DeleteMarkerReplication: Enabled` 는 **Terraform 소스에서 근거를 못 찾았습니다**(10/23 원주 확인 · 프로바이더 바이너리만 매치). 10/13에 「도쿄 복제 반영까지 확인」한 기록은 있으나 설정값 자체는 미확인입니다
   - 실제로 지우기 전에 한 번 확인하세요
     ```bash
     aws s3api get-bucket-replication --bucket aquasentinel-dev-observability-379937169195 \
       --query 'ReplicationConfiguration.Rules[].{ID:ID,DeleteMarker:DeleteMarkerReplication.Status}'
     ```

**(A-2) 새 serverName** — 지우지 않고 새 경로로

1. 🔴 변경 — 새 클러스터의 ObjectStore(`aquasentinel-backup-store`) `spec.configuration.serverName: aquasentinel-pg-<환경>-<YYYYMMDD>`
2. **같이 맞출 곳**(serverName이 박혀 있는 곳 — 10/23 코드 확인)

   | 곳 | 파일 · 위치 | 지금 값 |
   |---|---|---|
   | 도쿄 Replica Cluster | `terraform/tokyo/rebuild/3-gitops/applications.tf` — `cloudnativepg-cluster` 패치 `/spec/externalClusters` `seoul` → `serverName` | `"aquasentinel-pg"` |
   | 시험 구역 복구 | gitops `test-field` `manifests/cloudnativepg/cluster/cluster.yaml` — `externalClusters` `seoul-prod` → `serverName` | `aquasentinel-pg` |
   | (바꿀 필요 없음) | `object-store-seoul-source.yaml`(서울 버킷 접두사만) · `cnpg_restore_source_prefix`(IAM 접두사 `cloudnativepg/`) · IRSA · S3 수명 규칙 | 접두사는 그대로라 영향 없음 |

3. 바꾼 직후 **기준 백업 1회** — 새 경로에는 베이스 백업이 없어 그 전까지 시점 복구가 안 됨
   ```bash
   kubectl -n aquasentinel-db create -f - <<'EOF'   # 🔴 변경(백업 1회)
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata: {generateName: aquasentinel-pg-base-, namespace: aquasentinel-db}
   spec: {cluster: {name: aquasentinel-pg}, method: plugin, pluginConfiguration: {name: barman-cloud.cloudnative-pg.io}}
   EOF
   ```

### 2.3 끝 확인 (어느 쪽이든)

- `ContinuousArchiving=True` · 아카이버 `last_archived_time`이 몇 분 안 · 실패가 늘지 않음(0장 명령)
- 베이스 백업 1회 `completed`(`kubectl get backups.postgresql.cnpg.io`)
- 도쿄를 쓰는 중이면 도쿄 Replica Cluster가 새 경로를 따라오는지(도쿄 쪽 `pg_stat_wal_receiver` 대신 복구 로그 · `status.conditions`)

## 3. (B) 전환 뒤 — 구 Primary가 레플리카로 안 올라올 때

언제: switchover · failover · 노드 교체 · drain 뒤 「인스턴스 하나가 Ready로 안 돌아옴」 + 1장 판별이 (B)

1. 상태 — 누가 Primary인지 · 누가 안 올라왔는지
   ```bash
   kubectl -n aquasentinel-db get cluster aquasentinel-pg -o jsonpath='primary={.status.currentPrimary} ready={.status.readyInstances}/{.status.instances}{"\n"}'
   kubectl -n aquasentinel-db get pods -l cnpg.io/cluster=aquasentinel-pg -L cnpg.io/instanceRole
   ```
2. 🔴 **지우려는 인스턴스가 Primary가 아닌지 다시 확인** — `currentPrimary`와 이름이 같으면 **멈춤**(Primary PVC를 지우면 데이터를 잃음). 남은 두 인스턴스 중 하나가 Primary이고 Ready여야 진행
3. 남는 쪽이 정상인지 — Primary 아카이빙 `ContinuousArchiving=True` · 나머지 레플리카 1개 streaming(0장 명령). 둘 다 아니면 이 절차를 멈추고 원인부터
4. 🔴 변경 — 복귀 못 하는 인스턴스의 PVC와 파드 삭제 → 오퍼레이터가 Primary에서 새로 받아 만듦(풀 재동기화)
   ```bash
   X=aquasentinel-pg-<n>        # 2에서 Primary가 아님을 확인한 인스턴스
   kubectl -n aquasentinel-db delete pvc $X --wait=false
   kubectl -n aquasentinel-db delete pod $X
   ```
   - 🔸 **어디까지가 10/12 실측인지**(원주 검수 10/23) — 10/12 기록(DR 계획서 2.3 · R5)에 남은 것은 **「PVC를 통째로 지우고 풀 재동기화」까지**입니다. **`delete pod` 는 그 기록에 없습니다** — PVC에 파드가 붙어 있으면 삭제가 `Terminating` 에서 멈추기 때문에 넣은 **보강 한 줄**이고, 10/12에 실제로 쳤는지는 확인되지 않았습니다. 순서대로 치면 어느 쪽이든 결과는 같습니다
   - CNPG는 새 인스턴스를 **다음 번호**로 만듭니다(예: `aquasentinel-pg-4`) — 이름이 바뀌는 것이 정상
     - 🔸 **미확인** — CNPG 동작에 대한 서술이고 10/12 기록에는 새 인스턴스 이름이 안 남아 있습니다. 다음에 (B)를 실제로 겪으면 **이름을 기록해 이 줄을 확정**해 주세요
   - 그동안 인스턴스는 2개 — 쓰기는 계속됨(async 복제)
5. 끝 확인 — `readyInstances` 3 · 새 인스턴스 streaming · `ContinuousArchiving=True` · 아카이버 실패 늘지 않음 · `CnpgReplicaNotStreaming` 해소
6. 기록 — 전환 시각 · 지운 인스턴스 · 새 인스턴스 이름 · 재동기화 걸린 시간 · 판정 창이면 대장 2-4장(창 안 운영 변경)

- 🔸 (B)의 원인 설명(「복귀하는 쪽 상태가 갈라져서」)은 10/12 PVC 재생성으로 풀린 것에서 거꾸로 읽은 해석입니다(원주 회신 2장). 확실한 것은 「경로 변경(B안)으로는 (B)가 안 막히고, PVC 재생성으로 풀렸다」입니다
- (선택) 시험 구역 2에서 switchover → 구 Primary 복귀를 한 번 해 보고 결과를 이 절에 넣을 수 있습니다(사전등록 · 원복 · 사전 공지 후)

## 4. 공통 — 재구축 · DR 훈련 전 사전 점검

- 2.1의 S3 목록 두 줄 — 비어 있으면 진행, 있으면 2.2
- 0장 기준값과 비교 — 실패 누적이 기준(운영 2)보다 늘었으면 1장으로
- DR 훈련 체크리스트에 같은 두 줄을 넣는다

## 5. 하지 않는 것 · 나중에 할 것

| | |
|---|---|
| 판정 창 안에 serverName 바꾸기 | 하지 않음 — 바꾸는 순간부터 기준 백업까지 시점 복구가 끊김(INF-03). **창 뒤(11/10~) MR**로(원주) |
| 날짜로 백업 지우기 | 하지 않음 — systemID로만 |
| 기존 PDF 런북(`AquaSentinel_DR_페일오버_런북_팀공유용.pdf`, 10/01) | 이 두 절차가 없음 — 런북 갱신 때 이 문서를 합침(원주) |

## 6. 검수 결과 (A · 2026-10-23 04:1x UTC)

| # | 재희님이 봐 달라고 한 것 | 결과 |
|---|---|---|
| 1 | 2.1 · 2.2 S3 명령 — 실행 확인 | ✅ **됩니다.** 2.1에 결과 반영 |
| 2 | 2.2 (A-1) 3번 삭제 범위 | 🔴 **고쳤습니다** — 실제 10/13은 **미완료 systemID 2개 + `wals/` 전체**도 지웠습니다. 둘이 빠져 있었습니다 |
| 3 | 3장 4번 — 10/12 실제 명령 | ⚠️ **PVC는 맞고 `delete pod` 는 기록에 없습니다.** 지우지 않고 **「보강 한 줄」로 표기 분리**했습니다 |
| 4 | 2.2 (A-2) 기준 백업 방식 | ✅ **맞습니다.** ScheduledBackup `aquasentinel-pg-backup` = `method: plugin` · `barman-cloud.cloudnative-pg.io` — 매니페스트와 같은 방식 |

**검수에서 추가로 고친 것 2건**

| 무엇 | 내용 |
|---|---|
| 1장 경보표 | `CnpgMetricsAbsent`(10분) **누락** → 추가. 운영 CNPG 경보 **7개 전수** 반영 |
| 0장 기준값 | 성공 수는 늘어나는 게 정상인데 고정값으로 읽혀 **오해 소지** → 「볼 것은 실패 쪽」 주석 추가 |

**남은 미확인 2건**(둘 다 머지를 막지 않음 · 해당 절에 🔸로 표기)

- `DeleteMarkerReplication: Enabled` — Terraform 소스에 근거 없음. 실제 삭제 전 조회 명령을 2.2 4번에 넣어 둠
- (B) 뒤 새 인스턴스가 **다음 번호**로 생기는지 — 다음에 실제로 겪으면 이름을 기록해 확정

---

### 이력

| 언제 | 누가 | 무엇 |
|---|---|---|
| 2026-10-23 | C(재희) | 초안 작성 · 라이브 조회 반영 |
| 2026-10-23 | A(원주) | 검수 — 위 4건 답 + 2건 추가 수정 |
