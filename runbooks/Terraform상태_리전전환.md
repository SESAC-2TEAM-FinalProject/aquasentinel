# 런북 — Terraform 상태 버킷 리전 전환 (서울 ↔ 도쿄 복제본)

- 대상: `terraform/global/bootstrap` 이 만드는 state 버킷과 **전 컴포넌트의 `backend.hcl`**(2026-10-27 기준 **14개** — `tokyo/runner` 신설분 포함)
- 작성 2026-10-26 · A(원주)
- 근거: DR 시나리오(develop) 3.2 `[가정 예외]` · 8.3 「Terraform 상태 버킷 리전 이중화」 · 2026-10-26 실측
- 🔴 **훈련 단계**(계획서 3.1 · 부록 B): **1장은 1부 *전* 사전 조건 #4** — 복제 적용 + 1회 전량 동기화(✅ **2026-10-27 완료** · 31/31 ETag 대조) / **3장은 1부 0단계** — backend 를 복제본으로 바꿔 「서울이 없다」를 성립시킴
- **이 문서에서 운영을 바꾸는 곳은 1장과 3장뿐입니다.** 나머지는 읽기입니다

> **한 줄** — 「서울이 죽었다」는 가정과 코드가 어긋나 있습니다. `backend.hcl` 이 **전부** 서울 버킷을 가리켜서, 진짜 서울 장애면 도쿄를 세우려고 `terraform init` 하는 순간 서울 S3 를 때리고 막힙니다. 복제본을 만들고(**1장**), DR 때 backend 를 바꾸면(**3장**) 풀립니다. 🔴 **복제만 켜고 backend 를 안 바꾸면 아무 의미가 없습니다.**

---

## 0. 기준값 — 지금 상태 (2026-10-26 실측)

| 항목 | 값 | 확인 명령(읽기) |
|---|---|---|
| 원본 버킷 | `aquasentinel-tfstate-379937169195` · 리전 **ap-northeast-2** | `aws s3api get-bucket-location --bucket aquasentinel-tfstate-379937169195` |
| 버전 관리 | **Enabled** ← 복제의 전제조건이 이미 충족돼 있다 | `aws s3api get-bucket-versioning --bucket aquasentinel-tfstate-379937169195` |
| 복제 설정 | **없음**(`ReplicationConfigurationNotFoundError`) | `aws s3api get-bucket-replication --bucket aquasentinel-tfstate-379937169195` |
| `backend.hcl` | **14개 · 전부 원본(서울)** | `./scripts/dr-switch-tfstate-backend.sh` |
| 잠금 방식 | **S3 네이티브 락**(`use_lockfile = true`) — DynamoDB 테이블 없음 | `grep -rn use_lockfile terraform/*/main.tf` |
| 암호화 | **AES256**(SSE-S3). KMS 가 아니라 복제 역할에 키 권한이 따로 필요 없다 | `aws s3api get-bucket-encryption --bucket aquasentinel-tfstate-379937169195` |

🔴 **`global/bootstrap` 은 CI 범위 밖입니다**(`.gitlab-ci.yml` 머리말 — "CI가 쓸 것 자체를 만드는 닭과 달걀 컴포넌트, 최초 1회 수동 적용"). 1장은 **사람이 직접** 돌립니다.

---

## 1. 켜기 — 한 번만 (🔴 변경)

### 1.1 복제 만들기

```bash
cd terraform/global/bootstrap
terraform init -backend-config=backend.hcl -reconfigure
terraform plan            # 기대: 7 to add, 0 to change, 0 to destroy
terraform apply
```

**기대 결과 — 7개 추가, 기존 버킷은 건드리지 않음** (2026-10-26 `plan` 실측)

| 추가되는 것 | 어디 |
|---|---|
| `aws_s3_bucket.tfstate_replica` — `aquasentinel-tfstate-replica-379937169195` | 도쿄 |
| `aws_s3_bucket_versioning.tfstate_replica` — 받는 쪽도 버전 관리가 켜져야 복제가 동작 | 도쿄 |
| `aws_s3_bucket_server_side_encryption_configuration.tfstate_replica` — AES256 | 도쿄 |
| `aws_s3_bucket_public_access_block.tfstate_replica` | 도쿄 |
| `aws_iam_role.replication` + `aws_iam_role_policy.replication` | 전역 |
| `aws_s3_bucket_replication_configuration.tfstate` — 원본에 붙는다 | 서울 |

🔴 `0 to change, 0 to destroy` 가 아니면 **멈추고 왜인지 보십시오.** 이 컴포넌트는 state 버킷 자체를 관리하므로 예상 못 한 변경을 그냥 통과시키면 안 됩니다. 버킷에는 `prevent_destroy` 가 걸려 있어 삭제는 Terraform 이 거부합니다.

### 1.2 🔴 1회 전량 동기화 — 빠뜨리기 쉬운 단계

**복제는 설정한 뒤에 쓰인 객체만 옮깁니다. 소급 적용이 없습니다.**

state 는 `apply` 할 때만 쓰이므로, 한동안 apply 하지 않은 컴포넌트는 복제본이 **비어 있습니다.** 그리고 그런 컴포넌트가 바로 DR 에서 필요한 쪽입니다 — `global/bootstrap`, `seoul/persistent` 처럼 거의 바뀌지 않는 것들입니다.

```bash
# 읽기 → 쓰기(도쿄). 상태 파일 전체가 수 MB 규모라 금방 끝난다.
aws s3 sync \
    "s3://aquasentinel-tfstate-379937169195/" \
    "s3://aquasentinel-tfstate-replica-379937169195/" \
    --source-region ap-northeast-2 --region ap-northeast-1
```

> `sync` 로 넣은 객체는 **복제가 아니라 복사**라 복제 상태(`ReplicationStatus`)가 비어 있습니다. 정상입니다 — 내용은 같고, 이후 변경분은 복제가 따라갑니다.

🔴 **복제본에 반드시 있어야 하는 것 — `seoul/persistent/terraform.tfstate`** (2026-10-27 실측)

도쿄 `rebuild/2-cluster` 가 **서울** state 를 읽습니다(`irsa.tf` 의
`data "terraform_remote_state" "seoul_persistent"`). 도쿄 CNPG 가 서울
`observability` 버킷의 WAL 을 S3 API 로 읽어야 해서, 그 **버킷 ARN 과
`cloudnativepg_prefix`** 를 거기서 가져옵니다.

→ 「서울이 없다」 가정에서 **1부 3단계(`2-cluster` apply)가 이 파일에 걸립니다.**
`sync` 가 이것까지 넣어 주므로 1.2 를 빠뜨리면 안 됩니다.

🔸 복제본의 `seoul/persistent` 는 **스냅숏**입니다. 서울 `persistent` 를 고치면
그 뒤 변경분은 복제가 따라가지만, 복제를 켜기 전 상태는 `sync` 시점으로
멈춰 있습니다. `persistent` 는 거의 바뀌지 않아 실무상 문제가 없지만,
서울 `persistent` 를 apply 한 날에는 복제가 도착했는지 1.3 으로 확인하십시오.

### 1.3 확인

```bash
aws s3api get-bucket-replication --bucket aquasentinel-tfstate-379937169195 \
  --query 'ReplicationConfiguration.Rules[].{id:ID,status:Status,dest:Destination.Bucket,delmark:DeleteMarkerReplication.Status}'

# 양쪽 객체 수가 같은지
for b in aquasentinel-tfstate-379937169195 aquasentinel-tfstate-replica-379937169195; do
  echo "$b: $(aws s3 ls "s3://$b/" --recursive | grep -c tfstate)"
done
```

---

## 2. 평소 확인 — 읽기만

| 무엇 | 명령 |
|---|---|
| backend 가 어느 쪽을 보는지 | `./scripts/dr-switch-tfstate-backend.sh` |
| 복제가 실제로 붙는지 — 아무 state 하나의 복제 상태 | `aws s3api head-object --bucket aquasentinel-tfstate-379937169195 --key seoul/rebuild/3-gitops/terraform.tfstate --query ReplicationStatus` |

`ReplicationStatus` 가 `COMPLETED` 면 정상입니다. `PENDING` 이 오래 남거나 `FAILED` 면 IAM 역할을 보십시오.

---

## 3. DR 때 — 도쿄 복제본으로 전환 (🔴 변경)

> 들어가는 자리: DR 런북에서 **도쿄 재구축(`1-network`)을 시작하기 전**입니다. `terraform init` 보다 먼저여야 합니다.

### 3.1 바꾸기

```bash
./scripts/dr-switch-tfstate-backend.sh --to-replica
```

`backend.hcl` **전부**의 `bucket` 과 `region` 을 바꿉니다(스크립트가 `find` 로 세므로 컴포넌트가 늘면 자동으로 따라갑니다). 🔴 **`key` 는 건드리지 않습니다**(컴포넌트 경로라 그대로 써야 합니다).

🔴 **bucket 이름까지 바뀝니다.** S3 버킷 이름은 전역 유일이라 복제본은 `-replica` 가 붙습니다 — `region` 만 바꾸면 안 됩니다. 스크립트가 둘 다 바꾸는 이유입니다.

가려는 버킷이 없으면 스크립트가 **아무것도 바꾸지 않고 중단**합니다(1장을 안 했을 때).

### 3.2 각 컴포넌트에서 backend 다시 읽기

```bash
terraform -chdir=terraform/tokyo/rebuild/1-network init -backend-config=backend.hcl -reconfigure
```

🔴 **`-migrate-state` 를 쓰면 안 됩니다.** 그건 "지금 상태를 저쪽으로 옮긴다"는 뜻인데, 복제본에는 **이미 복제된 상태가 있습니다.** 서울이 죽어 있으면 옮길 원본을 읽지도 못합니다. `-reconfigure` 가 "그냥 저쪽을 쓴다"입니다.

### 3.3 락이 남아 있으면

복제는 삭제 표식도 복제하도록(`delete_marker_replication = Enabled`) 설정돼 있어 `.tflock` 이 정상적으로 정리됩니다. 그래도 전환 순간에 서울이 락을 쥔 채 죽었으면 복제본에 락이 남을 수 있습니다.

```bash
# 어느 컴포넌트가 잠겼는지
aws s3 ls "s3://aquasentinel-tfstate-replica-379937169195/" --recursive | grep tflock

# 풀기 — 🔴 ID 는 Terraform 오류 메시지가 알려준다
terraform -chdir=terraform/<컴포넌트> force-unlock <LOCK_ID>
```

🔴 **`force-unlock` 은 「그 락을 쥔 쪽이 정말 죽었다」가 확실할 때만** 씁니다. 서울이 살아 있는 훈련에서는 서울 쪽 apply 가 돌고 있지 않은지 먼저 보십시오.

---

## 4. 되돌리기 — 🔴 상태가 갈라졌을 수 있습니다

```bash
./scripts/dr-switch-tfstate-backend.sh --to-primary
```

🔴 **DR 중 도쿄에서 `apply` 했다면 그냥 되돌리면 안 됩니다.** 복제는 **서울 → 도쿄 한 방향**입니다. 도쿄에서 만든 상태는 자동으로 서울로 돌아오지 않고, 그대로 되돌리면 그 작업이 상태에서 사라집니다(실제 AWS 자원은 남고 Terraform 만 모르는 상태 = 고아 자원).

**순서**

1. 서울 버킷이 다시 읽히는지 확인 — `aws s3 ls s3://aquasentinel-tfstate-379937169195/`
2. 🔴 **도쿄에서 바뀐 state 를 서울로 올린다** — 바뀐 key 만 골라서

   ```bash
   aws s3 cp \
       "s3://aquasentinel-tfstate-replica-379937169195/tokyo/rebuild/1-network/terraform.tfstate" \
       "s3://aquasentinel-tfstate-379937169195/tokyo/rebuild/1-network/terraform.tfstate" \
       --source-region ap-northeast-1 --region ap-northeast-2
   ```

   서울 버킷은 버전 관리가 켜져 있어 덮어써도 이전 버전이 남습니다.
3. `--to-primary` 로 backend 를 되돌린다
4. 각 컴포넌트에서 `init -backend-config=backend.hcl -reconfigure`
5. `terraform plan` 으로 **`0 to change` 를 확인**한다 — 여기서 뜻밖의 변경이 보이면 2번에서 빠뜨린 key 가 있다

> 이 비대칭(갈 때는 스크립트 한 줄, 돌아올 때는 손으로 골라 올리기)은 DB 쪽과 같은 성질입니다 — DR 시나리오 6장의 「넘어가기보다 복귀가 위험한 이유」와 같은 이유로, 복귀는 급하지 않을 때 합니다.

---

## 5. 하지 않는 것 · 나중에 할 것

| 무엇 | 왜 |
|---|---|
| 양방향 복제 | 두 버킷이 서로를 덮어써 어느 쪽이 최신인지 알 수 없게 됩니다. 8주 범위 밖 |
| `.tflock` 만 복제 제외 | S3 복제 필터는 **접두사·태그**만 되고 `.tflock` 은 접미사라 걸러낼 수 없습니다 |
| 복제본에서 평소에 apply | 복제가 한 방향이라 즉시 갈라집니다. 복제본은 **DR 때만** 씁니다 |
| 훈련(1부)에서 이 전환을 실제로 하기 | DR 시나리오 3.2 가 `[가정 예외]` 로 두기로 했습니다 — 훈련 범위를 넓히지 않습니다. 이 런북은 **진짜 장애**와 **발표 뒤 과제**용입니다 |

---

### 이력

| 날짜 | 내용 |
|---|---|
| 2026-10-26 | 신규. `global/bootstrap/replication.tf` + `scripts/dr-switch-tfstate-backend.sh` 와 같이 작성. 🔴 스크립트 작성 중 결함 2건을 잡았습니다 — ⑴ `mapfile`(macOS 기본 bash 3.2 에 없음 · `bash -n` 은 통과) ⑵ `\s`(BSD sed·grep 이 모름 → 전부 "알 수 없음" 으로 잡혔다). 둘 다 **실행해 봐야 드러나는** 부류였습니다 |
| 2026-10-27 | `tokyo/runner` 신설로 컴포넌트가 **13 → 14** 개가 되었습니다. 스크립트는 `find` 로 세므로 코드 변경 없이 14개를 잡습니다(`--status` 로 **원본 14 · 알 수 없음 0** 확인). 본문의 「13개」 서술만 고쳤습니다 |
