# 런북 — DR 전환 훈련 당일 진행 (1부 · 2부 통합 순서)

- 작성 2026-10-28 · A(원주) · 🔴 **계획서 `DR테스트_계획서_도쿄리전전환훈련_최종본_2026-10-27.md` 3.1 · 3.2 를 레포에 옮긴 것**
- **왜 이 런북이 있나** — 단계 순서가 `AWS/docs/` 에만 있었는데 **`docs/` 는 `.gitignore` 대상**이라 레포에 따라가지 않습니다. 당일에 펼 것이 레포에 있어야 합니다.
- **이 런북의 역할** — 순서와 명령만 담습니다. 각 단계의 **자세한 절차는 아래 런북 5개**를 폅니다.

| 쓰는 자리 | 런북 |
|---|---|
| 1부 0단계 · 2부 0단계 | `도쿄러너_재해때_깨우기.md` · `Terraform상태_리전전환.md` |
| 1부 4단계 · 2부 0단계 | `WAL아카이빙.md` (CNPG 가 안 올라올 때) |
| 1부 7단계 · 2부 7단계 | `DB다시부트스트랩.md` |
| 1부 8단계 · 2부 8단계 · 뒷정리 #5 | `드릴레코드_전환.md` |
| 2부 준비 · 2부 1~4단계 · 뒷정리 #2·#3 | `Stage2_스트리밍_붙이기.md` |

---

## 🔴🔴 0. 시작 전 — 이게 안 되면 시작하지 않습니다

### 0.1 사람 · 결정 (A 혼자서는 못 합니다)

| | 무엇 | 누구 | 없으면 |
|---|---|---|---|
| ① | **1부 날짜 확정** | C(재희) | 시작 못 함 |
| ② | 🔴 **CNPG 승격 절차** — 아래 **부록 A** 참고 | **A 가 먼저 닫아야 함** | **5단계에서 멈춤** |
| ③ | **데드맨 체크 계정**(11-2 `up` 확인 · 뒷정리 #0 Pause) | C | 11-2 못 함 · 🔴 뒷정리 때 **오경보** |
| ④ | **화면 확인**(11-3) | B(창영) | 「사람이 쓸 수 있다」 증거 없음 |
| ⑤ | 🔴 **(가-2) 토큰** — 운영 주소 로그인 토큰 · **7단계 직전에** 받습니다(만료 30분) | B(창영) | **RTO 끝을 못 찍음** |
| ⑥ | **`FARM_ID` 1개 고정** | A(미리) | (가-2) 호출 불가 |

🔴 **셋이 약 6시간(5시간 29분 ~ 6시간 35분) 붙어 있어야 합니다.** 09:00 시작 권고.

### 0.2 날짜가 피해야 하는 것

| | |
|---|---|
| 🔴 **판정 창 기록일 우선** | **10/29 · 11/05 · 11/10** — 겹치면 기록일이 먼저입니다(건너뛰면 복구 불가) |
| 🔴 **11/01 회피** | 적조 정규 전환(`SIM-12a`)과 겹칩니다 |
| 창 종료 | 11/10 |

### 0.3 자원 상태 — 명령으로 확인

```bash
# 도쿄가 깨끗한가 (전부 0 이어야 함)
aws eks list-clusters --region ap-northeast-1 --query 'length(clusters)' --output text
aws ec2 describe-vpcs --region ap-northeast-1 --query 'length(Vpcs[?IsDefault==`false`])' --output text
aws ec2 describe-vpc-peering-connections --region ap-northeast-1 --query 'length(VpcPeeringConnections)' --output text
aws ec2 describe-vpc-peering-connections --region ap-northeast-2 --query 'length(VpcPeeringConnections)' --output text

# 도쿄 상시 자원이 있는가 (S3 3 · ACM 1 · 시크릿 18)
aws acm list-certificates --region ap-northeast-1 --query 'length(CertificateSummaryList)' --output text
aws secretsmanager list-secrets --region ap-northeast-1 --query 'SecretList[].Name' --output text | tr '\t' '\n' | wc -l

# 🔴 S3 잔재 — cloudnativepg-tokyo/ 가 0 이어야 4단계가 안 막힘
for b in aquasentinel-dev-observability-379937169195 aquasentinel-dr-tokyo-observability-379937169195; do
  echo -n "$b : "; aws s3 ls "s3://$b/cloudnativepg-tokyo/" --recursive 2>/dev/null | wc -l
done

# 서울이 멀쩡한가 (훈련 내내 비교 기준)
kubectl -n argocd get applications --no-headers | awk '{print $2"/"$3}' | sort | uniq -c
kubectl get pods -A --no-headers | grep -vE "Completed|Succeeded" \
  | awk '{split($3,a,"/"); if ($4!="Running" || a[1]!=a[2]) print $1,$2,$3,$4}'
```

**2026-10-28 13:11 KST 실측 — 시작 가능 상태** `[사실]`

| 확인 | 값 |
|---|---|
| 도쿄 EKS · 비기본 VPC · 피어링(양 리전) | **0 · 0 · 0 · 0** ✅ |
| 도쿄 S3 3 · ACM 1 · 시크릿 18(`dr-tokyo` 12) | ✅ |
| `cloudnativepg-tokyo/` | **0 · 0** ✅ |
| 🔴 `cloudnativepg/`(서울 백업 복제본 — **지우면 안 됨**) | **4,367 · 4,367** ✅ |
| 서울 Argo | **41/41** Synced/Healthy ✅ |
| 서울 비정상 파드 | **0**(살아 있는 82개 중) ✅ |
| 🔴 도쿄 러너 EC2 `i-0a6ffc9fe8534f93c` | **running** — GitLab 쪽 **Paused** 인지 화면 확인 필요 |

### 0.4 셸 준비

```bash
export SEOUL=aquasentinel-dev          # 서울 컨텍스트
export TOKYO=<도쿄 컨텍스트>            # 2단계 뒤 생깁니다
export AWS_PAGER=""                    # aws 출력이 페이저로 멈추지 않게

# 🔴 증거 디렉터리 — 글롭이 아니라 **변수**로 잡습니다(디렉터리가 둘이면 glob 이 깨집니다)
export DRILL_DIR=~/dr-drill-$(date +%Y%m%d)
mkdir -p "$DRILL_DIR" && cd "$DRILL_DIR" && echo "$DRILL_DIR"
```

🔴 **모든 단계 앞뒤에 `date -u +%FT%TZ` 를 찍습니다.** 시각은 추정하지 않습니다.

---

## 1. 1부 — Stage 0 (도쿄 전량 세우기)

> 🔴 **1순위 측정은 4단계(`3-gitops`) 단일 시도 시간**입니다. 시작·끝을 초 단위로 남깁니다.

| # | 무엇 | 명령 / 펼 런북 | 예상 | 끝났다고 보는 것 | 실측 |
|---|---|---|---|---|---|
| 0 | 사전 점검 · 🔴 도쿄 러너 깨우기 · tfstate 복제본 전환 | `도쿄러너_재해때_깨우기` 2장 · `Terraform상태_리전전환` 3장 | 10분 | 위 0.3 전부 ✅ | ⟨ ⟩ |
| 0-1 | 🔴 **가정 장애 `T_f` · 선언 `T_d` 기록**(탁상) | — | 2분 | 두 시각이 적힘 · `T_d` 부터 복구 구간 | ⟨ ⟩ |
| 1 | `tokyo/persistent` 확인 | 0.3 (상시 운영) | 0분 | S3 3 · ACM 1 | ✅ |
| 2 | `1-network` apply | 아래 ① | **4분** `[사실]` | VPC·서브넷 · `0 to destroy` | ⟨ ⟩ |
| 3 | `2-cluster` apply | 아래 ① | **19분** `[사실]` | EKS Active · 노드 **3/3** · Redis available | ⟨ ⟩ |
| **4** | 🔴 **`3-gitops` apply — 1순위 측정** | 아래 ① · 막히면 `WAL아카이빙` | **미실측**(상한 48분) | Argo **40개** Synced/Healthy · CNPG **3/3** | ⟨ ⟩ |
| **5** | 🔴 **① CNPG 승격** — **못 되돌림 · 사람 판단** | 🔴 **부록 A** | 미실측 | `pg_is_in_recovery()` = **f** | ⟨ ⟩ |
| 6 | **②③ 깨우기** | 아래 ② | 미실측 | Keycloak·web-backend·api-module 기동 (🔴 수집기는 멈춘 채) | ⟨ ⟩ |
| 7 | 🔴 **④ 비밀번호 맞추기** | **`DB다시부트스트랩`** | 미실측 | 파드 Ready · `/readyz` 200 · PG 로그 `password authentication failed` **0** | ⟨ ⟩ |
| 8 | 🔴 **⑤ `4-edge` apply — 첫 실행** | `드릴레코드_전환` · 아래 ③ | 미실측 | `dr-drill.` **SECONDARY 레코드** 생성 | ⟨ ⟩ |
| 9 | **Stage 0 RPO** — 복구 가능 시점 | CNPG 복구 로그 | 3분 | 🔴 분해능 = `archive_timeout` **5분** | ⟨ ⟩ |
| 10 | **데이터 공백** | `collector-completeness` 대조 | 5분 | 공백 구간 기록 | ⟨ ⟩ |
| 11 | 측정값 수집 | 4장 | 10분 | 단계별 시각 · 증거 파일 | ⟨ ⟩ |
| 11-1 | DNS 가 넘어갔나 | `dig dr-drill.aquasentinel.cloud` | 2분 | 응답이 **도쿄 ALB** | ⟨ ⟩ |
| 11-2 | 🔴 데드맨 `new → up` | Healthchecks.io 화면 | 2분 | **C(계정) · A(확인)** | ⟨ ⟩ |
| 11-3 | 🔴 **화면 눈으로** | 브라우저 | 5분 | **B** — `dr-drill.` 로그인 → 대시보드 본문까지 | ⟨ ⟩ |
| 12 | 🔴 **뒷정리** | 3장 | **34분** `[사실]` | 과금 자원 **0** | ⟨ ⟩ |

### ① Terraform apply (2·3·4단계 공통)

```bash
cd AWS/terraform/tokyo/rebuild/<1-network|2-cluster|3-gitops>
date -u +%FT%TZ | tee -a "$DRILL_DIR/times.txt"           # 시작
terraform init -backend-config=backend.hcl -input=false
terraform plan  -input=false -out=tfplan                  # 🔴 0 to destroy 확인
terraform apply -input=false tfplan 2>&1 | tee apply.log
date -u +%FT%TZ | tee -a "$DRILL_DIR/times.txt"           # 끝
```

🔸 **CI 수동 잡으로 돌려도 됩니다**(`apply:tokyo-dr`). 그 경우 잡 시작·끝 시각을 GitLab 화면에서 읽어 적습니다.

### ② ②③ 깨우기 (6단계)

```bash
cd AWS/terraform/tokyo/rebuild/3-gitops
terraform apply -input=false -var dr_mode=active
# 🔴 suspend_collectors 는 건드리지 않습니다 — 기본 true(멈춤) 그대로.
#    서울이 살아 있는데 도쿄 collector 가 같이 돌면 같은 공공 API 키로
#    호출이 2배가 되고, 한도에 걸리면 운영 #6·#7 이 깨집니다.
```

### ③ ⑤ 드릴 레코드 (8단계 — 도쿄 SECONDARY 만듦)

```bash
cd AWS/terraform/tokyo/rebuild/4-edge
terraform init -backend-config=backend.hcl -input=false
terraform apply -input=false            # dr-drill. SECONDARY (헬스체크 없음)

# 전환은 서울 쪽 헬스체크를 뒤집어서 합니다
cd ../../../seoul/rebuild/4-edge
terraform apply -input=false -var drill_health_check_inverted=true
```

### ④ 🔴 RTO 끝 재기 — **7단계 직후부터** 30초 간격

```bash
TOKYO_ALB=$(kubectl --context "$TOKYO" -n ingress get gateway aquasentinel-gw \
  -o jsonpath='{.status.addresses[0].value}')
ALB_IP=$(dig +short "$TOKYO_ALB" | head -1)
RES="dr-drill.aquasentinel.cloud:443:$ALB_IP"

while true; do
  T=$(date -u +%FT%TZ)
  A=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$RES" \
        https://dr-drill.aquasentinel.cloud/readyz)
  B=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$RES" \
        -H "Authorization: Bearer $TOKEN" \
        https://dr-drill.aquasentinel.cloud/api/farms/$FARM_ID/status)
  echo "$T readyz=$A status=$B" | tee -a "$DRILL_DIR/rto.txt"
  [ "$A" = 200 ] && [ "$B" = 200 ] && break      # ← (가-2) = RTO 끝
  sleep 30
done
```

🔴 **도쿄 ALB 에 직접 부릅니다.** `dr-drill.` 로 부르면 DNS 전환(헬스체크 90초 + ALIAS 캐시 60초)이 끝 시각에 섞입니다. 🔸 도쿄 ACM 이 `*.aquasentinel.cloud` 라 Host/SNI 만 맞추면 인증서는 통과합니다 `[10/28 실측]`.

🔸 **8단계 뒤 `dr-drill.` 로 한 번 더 200 을 확인**해 「경로가 실제로 열린 시각」을 **별도 행**으로 남깁니다.

---

## 2. 1부 종료 판정 — 🔴 분기점

```
1부 뒷정리 ✅ → 종료 판정(A·C) ─┬─ 13:00 전 → 같은 날 2부
                                └─ 13:00 넘김 / 판정 안 남 → 2부는 다른 날
```

| | |
|---|---|
| 기준 | 계획서 **5.1** · 6.3 체크리스트 **전부 ✅** |
| 누가 | **A · C 가 그 자리에서** |
| 🔴 A 권고 | **13:00** 을 넘으면 2부는 다른 날 — 2부가 밤까지 밀려 뒷정리를 못 하는 쪽을 막습니다 |

---

## 3. 뒷정리 체크리스트 — 🔴 **1부 뒤 · 2부 뒤 각각 한 번**

| # | 지울 것 | 확인 |
|---|---|---|
| **0** | 🔴🔴 **데드맨 체크 Pause — C 에게 먼저 연락** | **destroy 보다 먼저.** 도쿄를 내리면 핑이 끊겨 **유예 5분 뒤 오경보** |
| 1 | 도쿄 `rebuild/*` **전량 destroy** | EKS·ALB·NAT·EC2·EBS·EIP·Redis·VPC **전부 0**. 🔴 `4-edge` 도 여기 포함 |
| 2 | 피어링 + 양쪽 라우트 — `5-peering` **destroy 한 번** | 양 리전 피어링 **0** · 라우트에 상대 CIDR 없음 *(1부 뒤엔 해당 없음)* |
| 3 | 서울 내부 NLB — gitops `kustomization.yaml` **한 줄 삭제** | 서울 NLB **0**. LBC 가 SG 까지 같이 지웁니다 *(1부 뒤엔 해당 없음)* |
| 5 | 드릴 헬스체크 | `-var drill_health_check_inverted=false` 로 원복 |
| **6** | 🔴 **도쿄 러너 다시 Paused** | GitLab Runners 화면 |
| **6-1** | 🔴🔴 **S3 잔재 — `cloudnativepg-tokyo/` · 도쿄 Thanos 블록** | 🔴 **안 지우면 다음 구축이 `Expected empty archive` 로 멈춥니다**(10/25 실제) |
| 7 | 과금 자원 **0** | 0.3 명령 재실행 |
| 8 | 남기는 것 | `tokyo/persistent`(S3 3 · ACM 1) · Secrets · ECR |
| 9 | 기본 컨텍스트 | `kubectl config use-context $SEOUL` |

🔴 **6-1 지울 때 접두사를 눈으로 확인하십시오** — `cloudnativepg/`(끝에 `-tokyo` 없음)는 **서울 백업의 복제본이자 DR 자산**(지금 4,367개)이라 지우면 **리전 장애 때 복구가 불가능**해집니다.

---

## 4. 2부 — Stage 2 (서울을 살려 둔 채)

### 4.1 준비 — 🔴 **A 가 C·D 보다 먼저**

| 순 | 무엇 | 런북 | 예상 |
|---|---|---|---|
| 0 | 🔴 도쿄 재구축 `1-network → 2-cluster → 3-gitops` | 위 1장 2·3·4단계 | 23분 + `3-gitops` 실측 |
| 0-1 | 사전 점검 | 0.3 | 10분 |
| 0-2 | 🔴 **WAL 생성률 `R` 측정**(60초 간격 2회) | `Stage2…` **3.0-1** | 2분 |
| **A** | 서울 내부 NLB 켜기 (gitops 한 줄) 🔴 창 안 운영 변경 | `Stage2…` 2-A | 5분 |
| **B** | 인증서 2종 복사 (🔴 `ca.key` 는 빼고) | `Stage2…` 2-B | 5분 |
| **C** | `5-peering` apply 🔴 창 안 운영 변경 | `Stage2…` 2-C | 5분 |
| **D** | `3-gitops` 에 `-var enable_stage2_streaming=true` | `Stage2…` 2-D | 10분 |
| **E** | 붙었는지 확인 (양쪽) · 🔸 **슬롯 수가 2인지** | `Stage2…` 2-E · 5장 | 5분 |

### 4.2 본편

| # | 무엇 | 런북 | 비고 |
|---|---|---|---|
| 1 | 끊기 + 🔴 **끊기 직전 서울 ⓐ** | 3.1·3.2 | 🔴 빠뜨리면 RPO 하한을 영영 못 잼 |
| 2 | 🔴 **끊김 확인 직후 — 도쿄 ⓑ · 서울 ⓐ′** | 3.2 | ⓑ 가 10초 뒤에도 같은 값인지 |
| 2-1 | S3 폴백이 도는가 | 3.3 | 🔴 돌면 RPO 의 뜻이 둘로 갈림 |
| **3** | 🔴 **되돌리기 → 사람 손 안 대고 2분 관찰 → 따라잡기** | 3.4·3.5 | 🔴 **#6 의 답** |
| **4** | 🔴 **다시 끊기** — `T_cut2`·ⓐ₂·ⓑ₂ | 3.6 | 「전환 시점 실제 손실」 |
| 5 | ① CNPG 승격 | 🔴 **부록 A** | 못 되돌림 |
| 6 | ②③ 깨우기 | 위 ② | |
| 7 | ④ 비밀번호 | `DB다시부트스트랩` | 🔴 토큰은 이 직전에 받기 |
| **7-1** | 🔴 **`4-edge` 다시 apply** | 위 ③ | 🔴 1부 뒷정리에서 지워졌습니다 |
| 8 | ⑤ `dr-drill.` 전환 | 위 ③ | **2~3분** `[사실]` |
| 9 | 뒷정리 | 3장 | **34분** `[사실]` |

---

## 5. 🔴 즉시 중단 — 하나라도 보이면 그 자리에서 멈춥니다

| 신호 | 확인 |
|---|---|
| 서울 파드 비정상 발생 | `kubectl get pods -A` (Running 이어도 ready 미충족 포함) |
| 서울 Argo **41 미만** Synced+Healthy | `kubectl -n argocd get applications` |
| 운영 도메인 3개 중 하나라도 이상 | `dig` + `curl` — apex · `auth.` · `grafana.` |
| 판정 창 #1 이 떨어짐 | Route53 헬스체크 `46d0a291`(건드리면 안 되는 것) |
| 서울 CNPG 가 Primary 를 잃음 | `pg_is_in_recovery()` |

🔸 **2부는 서울이 살아 있는 훈련입니다** — 「서울 무영향」이 5.2 성공 기준의 핵심이라, 훈련 **전·후 두 번** 서울 #2·#3 스냅샷을 찍어 10.5 에 붙입니다.

---

## 부록 A — 🔴🔴 **CNPG 승격: 절차가 아직 없습니다** (10/28 발견)

**1부 5단계 · 2부 5단계가 여기서 막힙니다.** 훈련 전에 닫아야 합니다.

### 무엇이 문제인가 `[코드 실측]`

| | |
|---|---|
| 승격이란 | 도쿄 Cluster 의 `spec.replica.enabled` 를 `true → false` 로 바꾸는 것 |
| 그런데 그 값을 누가 쥐고 있나 | 🔴 `tokyo/rebuild/3-gitops/applications.tf` 의 kustomize 패치가 **`{enabled = true, source = "seoul"}` 를 박아 넣습니다**(77~79행). 🔴 **`dr_mode` 와 무관하게 늘 들어갑니다** — `dr_mode=active` 는 ②③(Keycloak·web-backend·PushSecret)만 깨웁니다 |
| 왜 `kubectl patch` 로는 안 되나 | 🔴 그 Application 의 동기화 정책이 **`automated.selfHeal = true`** 입니다(실측). 손으로 바꾼 값은 Argo 가 **원하는 상태(=true)로 되돌립니다** `[추론 — 강한 근거]` |
| 지금 문서 상태 | 계획서 5단계는 **「① CNPG 승격」이라고만** 적혀 있고 **명령이 없습니다.** 런북 6개에도 없습니다 |

🔴 **이것은 되돌릴 수 없는 단계입니다.** 장애 한가운데서 즉흥으로 하면 안 됩니다.

### 세 가지 길

| | 방법 | 장점 | 단점 |
|---|---|---|---|
| **(가)** | 승격 전에 Argo 자동 동기화를 끄고(`argocd app set <app> --sync-policy none`) `kubectl patch` | 코드 변경 **0** | 🔴 끈 동안 다른 것도 안 고쳐집니다 · **다시 켜는 것을 잊으면** 뒷정리에 남습니다 · RTO 에 사람 손 단계가 **둘** 늡니다 |
| **(나)** 🔸 **A 권고** | `3-gitops` 에 **`promote_tokyo_db`**(기본 `false`) 변수를 신설해 `/spec/replica` 의 `enabled` 를 그 변수로. 승격은 `terraform apply -var promote_tokyo_db=true` 한 줄 | Argo 와 싸우지 않습니다(원하는 상태가 바뀌므로) · **코드로 남아 재현**됩니다 · 🔸 **「승격은 사람이 따로 한다」 설계 의도 유지** — `dr_mode` 와 섞지 않습니다 | 코드 변경 1건 + MR · `3-gitops` 증분 apply 시간이 RTO 에 들어갑니다(몇 분) |
| **(다)** | CNPG 1.30 분산 토폴로지(`replica.primary`/`self`/`promotionToken`)로 바꾸기 | 공식 승격 경로 | 🔴 구성 변경이 큽니다 — 훈련 전에 할 일이 아닙니다 |

🔴 **(나)를 권고합니다.** 다만 **시험해 본 적이 없습니다** — 도쿄가 없어 지금은 못 돌립니다. 1부 4단계 뒤, **5단계 직전에 `terraform plan` 으로 「Cluster 패치만 바뀐다」를 먼저 확인**하고 apply 하십시오.

---

## 부록 B — 기록 양식 (증거는 로컬)

```
$DRILL_DIR/   (= ~/dr-drill-YYYYMMDD/)
  times.txt      단계별 시작·끝 (date -u +%FT%TZ)
  rto.txt        30초 폴링 로그 (readyz / status)
  apply.log      각 terraform apply 출력 꼬리
  argo.txt       각 단계 끝의 Argo Application 전수
  pods.txt       CNPG · 워크로드 파드 상태
  lsn.txt        2부 ⓐ ⓐ′ ⓑ ⓐ₂ ⓑ₂ 와 T_cut · T_cut_confirmed · T_restore · T_caught
  seoul-before.txt / seoul-after.txt   🔴 서울 #2·#3 스냅샷 (2부)
```

🔴 **파일에 「뜬 시각」과 「도구 판(커밋)」을 적습니다.** 레포·S3 에 올리지 않습니다 — raw 대장에 첨부해 C 사본으로 갑니다.
