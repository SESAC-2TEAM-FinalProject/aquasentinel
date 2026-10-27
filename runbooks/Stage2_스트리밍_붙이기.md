# 런북 — Stage 2 직접 전송 붙이기 · 끊기 · 되돌리기

- 대상: 서울 운영 `aquasentinel-db/aquasentinel-pg` ↔ 도쿄 DR 같은 이름
- 작성 2026-10-27 · A(원주)
- 🔴 **훈련 단계**(계획서 3.2 · 부록 B): **2부 준비** · **2부 2단계(스트리밍 끊기)** · **뒷정리 6.3 #2·#3**
- **관련**: 계획서 **2.3** · **7장 #5 보충** · `AWS/terraform/tokyo/rebuild/5-peering` · gitops `manifests/cloudnativepg/cluster/pg-rw-internal-nlb.yaml`

> **한 줄** — Stage 0 은 서울이 WAL 을 S3 에 올리고 도쿄가 거기서 읽습니다(`archive_timeout` 5분 = **최대 5분치 밀림**). Stage 2 는 도쿄가 서울 Primary 에 **TCP 로 직접** 붙습니다. 길(피어링) · 창구(NLB) · 열쇠(인증서) · 설정(CNPG) **넷이 다 있어야** 붙습니다.

🔴 **비밀값은 화면 · 로그 · 문서 어디에도 찍지 않습니다.** 아래 복사 명령은 전부 **파이프**로만 넘깁니다.

---

## 0. 순서 한눈에

```
A. 서울 내부 NLB 켜기      (gitops 한 줄)      ← 창구
B. 인증서 2종 도쿄로 복사   (kubectl 파이프)    ← 열쇠
C. 피어링 apply            (5-peering)         ← 길
D. 도쿄 3-gitops apply     (스위치 on)         ← 설정
E. 붙었는지 확인
```

🔴 **A 가 C·D 보다 먼저입니다.** D 는 NLB 주소를 조회해서 쓰므로, NLB 가 없으면 **precondition 에서 멈춥니다**(일부러 그렇게 만들었습니다).
🔴 **B 는 D 전이면 언제든 됩니다.** 다만 빠뜨리면 CNPG 가 Ready 가 안 되고, 그게 유일한 신호입니다.

---

## 1. 기준값 — 2026-10-27 실측 `[사실]`

| 항목 | 값 |
|---|---|
| 서울 pg_hba | `hostssl replication streaming_replica all **cert** map=cnpg_streaming_replica` — **클라이언트 인증서 인증** |
| 서울 CA 시크릿 | `aquasentinel-pg-ca` · `Opaque` · 키 **`ca.crt`** · 🔴 **`ca.key` 도 들어 있음(복사하지 않습니다)** |
| 서울 복제 인증서 | `aquasentinel-pg-replication` · `kubernetes.io/tls` · 키 `tls.crt` · `tls.key` |
| 만료 | 셋 다 **2027-01-11** — 훈련 기간에 회전하지 않습니다 |
| 🔴 서버 인증서 SAN | `aquasentinel-pg-rw` · `…svc.cluster.local` 등 **클러스터 안 이름만**. **NLB 이름은 없습니다** → `sslmode` 는 `verify-ca` |

---

## 2. 단계

### A. 서울 내부 NLB 켜기 🔴 창 안 운영 변경

gitops `manifests/cloudnativepg/cluster/kustomization.yaml` 의 `resources` 에 한 줄을 더합니다.

```yaml
  - pg-rw-internal-nlb.yaml
```

확인:

```bash
kubectl get svc -n aquasentinel-db aquasentinel-pg-rw-internal \
  -o custom-columns=NAME:.metadata.name,EXTIP:.status.loadBalancer.ingress[0].hostname
aws elbv2 describe-load-balancers --region ap-northeast-2 \
  --names aquasentinel-dev-pg-rw-internal \
  --query 'LoadBalancers[].{Scheme:Scheme,State:State.Code}' --output table
```

**끝났다고 보는 것** — `Scheme=internal` · `State=active` · 타깃 그룹 **healthy 1개**(Primary 파드).

---

### B. 인증서 2종을 도쿄로 복사 🔴 값은 안 찍습니다

컨텍스트 이름을 먼저 잡습니다.

```bash
SEOUL=$(kubectl config get-contexts -o name | grep apne2 | head -1)
TOKYO=$(kubectl config get-contexts -o name | grep apne1 | head -1)
echo "서울=$SEOUL  도쿄=$TOKYO"     # 🔸 둘 다 비어 있지 않은지 눈으로 확인
```

🔴 **CA 는 `ca.crt` 만 가져갑니다.** `ca.key` 는 CA **개인키**라 도쿄에 있을 이유가 없습니다 — 도쿄는 서울 서버 인증서를 **검증만** 합니다.

```bash
# ① CA — ca.crt 만, ownerReferences 제거, 이름 바꿔서
kubectl --context "$SEOUL" get secret aquasentinel-pg-ca -n aquasentinel-db -o json \
| python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {
  "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
  "metadata": {"name": "aquasentinel-pg-seoul-ca", "namespace": "aquasentinel-db",
               "labels": {"aquasentinel.io/purpose": "dr-stage2"}},
  "data": {"ca.crt": d["data"]["ca.crt"]},      # ca.key 는 일부러 뺀다
}
json.dump(out, sys.stdout)
' \
| kubectl --context "$TOKYO" apply -f -

# ② 복제 클라이언트 인증서 — tls.crt · tls.key
kubectl --context "$SEOUL" get secret aquasentinel-pg-replication -n aquasentinel-db -o json \
| python3 -c '
import json, sys
d = json.load(sys.stdin)
out = {
  "apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
  "metadata": {"name": "aquasentinel-pg-seoul-replication", "namespace": "aquasentinel-db",
               "labels": {"aquasentinel.io/purpose": "dr-stage2"}},
  "data": {"tls.crt": d["data"]["tls.crt"], "tls.key": d["data"]["tls.key"]},
}
json.dump(out, sys.stdout)
' \
| kubectl --context "$TOKYO" apply -f -
```

확인 — **키 이름과 개수만** 봅니다:

```bash
kubectl --context "$TOKYO" get secret -n aquasentinel-db \
  aquasentinel-pg-seoul-ca aquasentinel-pg-seoul-replication \
  -o custom-columns=NAME:.metadata.name,TYPE:.type,KEYS:.data
```

🔴 **왜 이름에 `-seoul-` 을 끼우나** — 도쿄 CNPG 도 **자기 클러스터용으로** `aquasentinel-pg-ca` · `aquasentinel-pg-replication` 을 **스스로 만듭니다.** 같은 이름으로 넣으면 충돌합니다.

🔴 **`ownerReferences` 를 반드시 뺍니다** — 서울 Cluster 의 UID 를 가리키는데 도쿄엔 그 객체가 없어, 남겨 두면 **도쿄 가비지 컬렉터가 시크릿을 지워 버립니다.** 위 명령은 필요한 필드만 새로 만들어 보내므로 자동으로 빠집니다.

---

### C. 피어링 apply

```bash
cd AWS/terraform/tokyo/rebuild/5-peering
terraform init -backend-config=backend.hcl -input=false
terraform plan -input=false      # 🔸 도쿄 1-network 가 먼저 서 있어야 합니다
terraform apply -input=false
```

확인:

```bash
terraform output peering_status        # active 여야 합니다
terraform output tokyo_route_table_ids
```

---

### D. 도쿄 3-gitops 에서 스위치 켜기

```bash
cd AWS/terraform/tokyo/rebuild/3-gitops
terraform init -backend-config=backend.hcl -input=false
terraform plan  -input=false -var enable_stage2_streaming=true
terraform apply -input=false -var enable_stage2_streaming=true
```

🔸 **plan 에 뜨는 것은 Cluster 패치 한 곳**이어야 합니다. 다른 앱까지 바뀌면 멈추고 원인을 봅니다.

🔴 **A 를 건너뛰었으면 여기서 멈춥니다**:

```
Error: Resource precondition failed
  enable_stage2_streaming = true 인데 서울 Postgres 호스트를 못 구했다 — …
```

---

### E. 붙었는지 확인 — 양쪽에서 봅니다

**서울 Primary 쪽** — 도쿄가 붙으면 walsender 가 하나 더 생깁니다:

```bash
kubectl --context "$SEOUL" exec -n aquasentinel-db aquasentinel-pg-1 -c postgres -- \
  psql -U postgres -c "SELECT application_name, client_addr, state, sync_state,
                              pg_wal_lsn_diff(sent_lsn, replay_lsn) AS behind_bytes
                       FROM pg_stat_replication ORDER BY application_name;"
```

→ 서울 안 복제본 2개 말고 **도쿄 것이 한 줄 더** 보여야 하고, `client_addr` 가 **`10.1.x.x`**(도쿄 대역)여야 합니다.

**도쿄 쪽** — 받는 쪽 상태:

```bash
kubectl --context "$TOKYO" exec -n aquasentinel-db aquasentinel-pg-1 -c postgres -- \
  psql -U postgres -c "SELECT status, sender_host, sender_port,
                              latest_end_lsn, latest_end_time
                       FROM pg_stat_wal_receiver;"
```

→ `status = streaming` · `sender_host` 가 **NLB 주소**여야 합니다.

🔴 **`pg_stat_wal_receiver` 가 비어 있으면 아직 S3 로만 받고 있는 것입니다.** 그때 볼 곳:

| 증상 | 원인 | 고치는 곳 |
|---|---|---|
| `could not connect` · 타임아웃 | 길 또는 창구 | C 의 `peering_status` · A 의 타깃 healthy · NLB SG 가 `10.1.0.0/16` 을 열었는지 |
| `certificate verify failed` | 열쇠 | B 의 `ca.crt` 가 **서울 CA** 가 맞는지 |
| `connection requires a valid client certificate` | 열쇠 | B 의 `aquasentinel-pg-seoul-replication` 이 있는지 · `sslKey`/`sslCert` 이름이 맞는지 |
| `server certificate for "..." does not match host name` | `sslmode` | `verify-full` 로 바뀌었는지 확인 — **`verify-ca` 여야 합니다**(1장) |
| CNPG Cluster 가 `Ready=False: could not get source secret` | 열쇠 | B 를 안 했습니다 |

---

## 3. 2부 2단계 — 끊기와 되돌리기

**끊기** — 🔴 **도쿄 라우트만** 지웁니다. 서울은 안 건드립니다(계획서 2.3).

```bash
cd AWS/terraform/tokyo/rebuild/5-peering
terraform apply -input=false -var enable_tokyo_route=false
```

🔸 훈련 중에는 apply 를 기다리기보다 AWS CLI 로 라우트만 지우는 쪽이 빠를 수 있습니다. 그 경우 **되돌린 뒤 반드시 `terraform plan` 으로 `No changes` 를 확인**합니다 — 안 그러면 코드와 실물이 어긋난 채 남습니다.

**끊긴 것 확인** — 서울 `pg_stat_replication` 에서 도쿄 줄이 사라지고, 도쿄 `pg_stat_wal_receiver` 가 비웁니다.

**되돌리기**:

```bash
terraform apply -input=false -var enable_tokyo_route=true
```

🔴 **되돌린 뒤 스트리밍이 저절로 재개되는지가 사전 조건 #6 입니다 — 아직 실측 안 됐습니다.** 재개가 안 되면 도쿄 인스턴스 파드를 재시작해 봅니다:

```bash
kubectl --context "$TOKYO" delete pod -n aquasentinel-db aquasentinel-pg-1
```

🔸 `plugin`(S3 아카이브)을 **일부러 남겨 뒀기 때문에**, 스트리밍이 끊긴 동안에도 도쿄는 **S3 로 계속 따라갑니다** — 복제가 완전히 멈추지는 않습니다. 끊긴 동안 벌어지는 차이가 **2부에서 재려는 RPO** 입니다.

---

## 4. 뒷정리 (6.3 #2·#3)

| 순 | 무엇 | 명령 |
|---|---|---|
| 1 | 도쿄 3-gitops 스위치 끄기 | `terraform apply -var enable_stage2_streaming=false` (도쿄 전량 destroy 하면 생략) |
| 2 | 피어링 + 라우트 | `cd 5-peering && terraform destroy` |
| 3 | 서울 내부 NLB | gitops `kustomization.yaml` 에서 `pg-rw-internal-nlb.yaml` **한 줄 삭제** |
| 4 | 🔴 복사한 인증서 | 도쿄를 destroy 하면 같이 사라집니다. **도쿄를 남기는 경우에만** 지웁니다 |

```bash
# 4번 — 도쿄를 남길 때만
kubectl --context "$TOKYO" delete secret -n aquasentinel-db \
  aquasentinel-pg-seoul-ca aquasentinel-pg-seoul-replication
```

🔴 **3번을 하면 LBC 가 NLB 와 앞단 보안그룹까지 같이 지웁니다** — 따로 지울 것이 없습니다.

---

## 5. 함정

| 함정 | 무슨 일 | 피하는 법 |
|---|---|---|
| 🔴 `ca.key` 까지 복사 | CA **개인키**가 다른 리전에 남습니다 | B — `ca.crt` 만 |
| 🔴 `ownerReferences` 를 안 뺌 | 도쿄 GC 가 시크릿을 지웁니다 | B 의 명령은 필요한 필드만 새로 만듭니다 |
| 🔴 서울과 같은 시크릿 이름 | 도쿄 CNPG 가 만드는 것과 충돌 | `-seoul-` 을 끼웁니다 |
| `verify-full` 로 바꿈 | SAN 에 NLB 이름이 없어 실패 | 1장 — `verify-ca` |
| A 없이 D 먼저 | precondition 에서 멈춤 | 순서대로 |
| `plugin` 을 지움 | 스트리밍이 끊기면 **복제가 완전히 멈춥니다** | 🔴 남겨 둡니다 — 폴백입니다 |
