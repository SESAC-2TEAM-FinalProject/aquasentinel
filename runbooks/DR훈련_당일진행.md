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
| ② | ✅ ~~CNPG 승격 절차~~ — **2026-10-28 닫음**(`promote_tokyo_db` 변수 신설). 🟢 **리허설에서 2회 실제로 돌았습니다** — `pg_is_in_recovery()` **t→f 28초**(두 번 같음) · `transaction_read_only=off` · `CREATE TABLE`+`INSERT` 성공 · 🔴 **Argo `selfHeal` 되돌림 없음** `[2026-10-28 실측]`. 🔴 **그러니 지금 남은 위험은 「승격이 되는가」가 아닙니다 — `promote_tokyo_db` 가 끈적하지 않은 것입니다.** 5단계 **이후** `3-gitops` 를 건드리는 **모든** apply(6단계 · 2부 재적용 · destroy)에 `-var promote_tokyo_db=true` 를 붙이십시오 — 빠뜨리면 승격이 조용히 풀리고 **증상이 비밀번호 불일치 CrashLoop 과 구별되지 않습니다**(아래 ② · 3장) | A | — |
| ③ | **데드맨 체크 계정**(11-2 `up` 확인 · 뒷정리 #0 Pause) | C | 11-2 못 함 · 🔴 뒷정리 때 **오경보** |
| ④ | **화면 확인**(11-3) | B(창영) | 「사람이 쓸 수 있다」 증거 없음 |
| ⑤ | 🔴 **(가-2) 토큰** — 운영 주소 로그인 토큰 · **7단계 직전에** 받습니다(만료 30분) | B(창영) | **RTO 끝을 못 찍음** |
| ⑥ | ✅ ~~**`FARM_ID` 1개 고정**~~ — **2026-10-29 닫음**: `farm-510bd5e95cf2`(운영 DB 엔 유일한 양식장 · 축 9개). 0.4 에 박아 뒀음 · 토큰 없이 호출하면 **401** 실제 확인 | A | — |

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

# 🔴 (가-2) RTO 끝 호출용 — 2026-10-29 실측으로 고정(0.1 ⑥)
export FARM_ID=farm-510bd5e95cf2       # 운영 DB farm_readings 유일한 양식장 · 축 9개

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
| 2 | `1-network` apply | 아래 **①-가** | **4분** `[사실]` · 🔸 리허설 **2분 5초** | VPC·서브넷 · `0 to destroy` | ⟨ ⟩ |
| 3 | `2-cluster` apply · 🔴 **409 함정** | 아래 **①-가** | **19분** `[사실]` · 🔸 리허설 **19분 29초**(함정 대응 포함) | EKS Active · 노드 **3/3** · Redis available | ⟨ ⟩ |
| **4** | 🔴 **`3-gitops` apply — 1순위 측정 · 🔴 `plan` 불가** | 아래 **①-나** · 막히면 `WAL아카이빙` | 🔸 리허설 **16분 42초**(Terraform 4:46 + Argo 수렴 11분) · 상한 48분 | 🔴 **LBC CA 일치 확인**(아래 ①-나 함정) · 🔴 Argo **39/40**(`keycloak` 만 Degraded = standby 정상) · CNPG **3/3** | ⟨ ⟩ |
| **5** | 🔴 **① CNPG 승격** — **못 되돌림 · 사람 판단** | 🔴 **부록 A** | 🔸 리허설 **1분 27초**(`f` 전환은 **28초**) | `pg_is_in_recovery()` = **f** · `transaction_read_only=off` | ⟨ ⟩ |
| 6 | **②③ 깨우기** · 🔴🔴 **플래그 2개** | 아래 ② | 🔸 리허설 Terraform 18초 + Keycloak 기동 **약 2분** + 가공·판정 깨어남 **72초** | Keycloak `instances:1`·파드 Ready · 🔴 **Rollout 4개 `replicas>0` · ScaledObject 4개**(🟢 10/28 수정 후 72초에 자동 — 아래 ②) · 🔴 수집기는 멈춘 채 | ⟨ ⟩ |
| 7 | 🔴 **④ 비밀번호 맞추기** | **`DB다시부트스트랩`** + 🔴 **아래 ②-1** | 🔸 리허설 7분 44초 · 🔴 **10/28 실측 15분 31초** — 16분으로 잡기 | 파드 Ready · `/readyz` 200 · PG 로그 `password authentication failed` **0** | ⟨ ⟩ |
| 8 | 🔴 **⑤ `4-edge` apply** | `드릴레코드_전환` · 아래 ③ | 🔸 리허설 **35초**(도쿄 쪽만) | `dr-drill.` **SECONDARY 1줄** · 🔴 운영 도메인 SECONDARY **0** | ⟨ ⟩ |
| 9 | **Stage 0 RPO** — 복구 가능 시점 | CNPG 복구 로그 · 🔸 아래 ⑤ | 3분 | 🔴 분해능 = `archive_timeout` **5분** · 🔸 리허설 참고값 **약 12분** | ⟨ ⟩ |
| 10 | **데이터 공백** | `collector-completeness` 대조 | 5분 | 공백 구간 기록 | ⟨ ⟩ |
| 11 | 측정값 수집 | 4장 | 10분 | 단계별 시각 · 증거 파일 | ⟨ ⟩ |
| 11-1 | DNS 가 넘어갔나 | `dig dr-drill.aquasentinel.cloud` | 2분 | 응답이 **도쿄 ALB** | ⟨ ⟩ |
| 11-2 | 🔴 데드맨 `new → up` | Healthchecks.io 화면 | 2분 | **C(계정) · A(확인)** | ⟨ ⟩ |
| 11-3 | 🔴 **화면 눈으로** | 브라우저 | 5분 | **B** — `dr-drill.` 로그인 → 대시보드 본문까지 · 🔸 **프라이빗 창 권장**(아래 상자) | ⟨ ⟩ |
| 12 | 🔴 **뒷정리** — 🔴 **함정 2건** | 3장 | **34분** `[사실]` · 🔸 리허설 **49분**(함정 대응 포함) | 과금 자원 **0** · 🔴 **3장 3.1·3.2 까지** | ⟨ ⟩ |

### ①-가 Terraform apply — **2·3단계만** (`1-network` · `2-cluster`)

🔴 **4단계(`3-gitops`)는 이 묶음을 쓰지 않습니다.** 아래 ①-나 를 씁니다 — `plan` 이 구조적으로 성립하지 않습니다.

```bash
cd AWS/terraform/tokyo/rebuild/<1-network|2-cluster>
date -u +%FT%TZ | tee -a "$DRILL_DIR/times.txt"           # 시작
terraform init -backend-config=backend.hcl -input=false
terraform plan  -input=false -out=tfplan                  # 🔴 0 to destroy 확인
terraform apply -input=false tfplan 2>&1 | tee apply.log
date -u +%FT%TZ | tee -a "$DRILL_DIR/times.txt"           # 끝
```

🔴🔴 **함정 — `2-cluster` 가 로컬 apply 에서 409 로 죽습니다** `[2026-10-28 리허설 실측]`

```
Error: creating EKS Access Entry (...:user/sesac13): StatusCode: 409
  ResourceInUseException: The specified access entry resource is already in use
  with module.eks.aws_eks_access_entry.team["sesac13"]
```

| | |
|---|---|
| 왜 | `modules/aws-eks/main.tf:94` 의 `bootstrap_cluster_creator_admin_permissions = true` 가 **클러스터를 만든 주체**에게 access entry 를 **자동 생성**합니다. 그런데 `2-cluster/terraform.tfvars` 의 `team_members` 에도 `sesac13` 이 있어 Terraform 이 **같은 entry 를 또** 만듭니다 |
| 언제 터지나 | 🔴 **로컬에서 `sesac13` 으로 apply 할 때** — 위 ①-가 의 기본 경로입니다 |
| 언제 안 터지나 | **CI(`apply:tokyo-dr`)** — 생성자가 `role/aquasentinel-gitlab-terraform-apply` 라 겹치지 않습니다(10/25 실측) |
| 🔸 다른 팀원은? | `changyoung`·`jaehee` 는 생성자가 아니라 **정상 생성**됩니다 — 막히는 건 **apply 를 돌린 사람 하나뿐** |

**복구 — 2줄이면 됩니다** (apply 를 다시 돌리기 전에):

```bash
# 자동 생성된 entry 를 state 로 들입니다. <USER> 는 apply 를 돌린 주체(= aws sts get-caller-identity 의 Arn)
terraform import 'module.eks.aws_eks_access_entry.team["sesac13"]' \
  'aquasentinel-dr-apne1-eks:arn:aws:iam::379937169195:user/sesac13'
terraform plan -input=false -out=tfplan   # 🔴 `0 to destroy` · 바뀌는 건 기본 태그뿐이어야 합니다
terraform apply -input=false tfplan
```

🔸 10/28 리허설에서 이 2줄로 **36초**에 풀렸습니다(`3 to add, 1 to change, 0 to destroy`).

### ①-나 🔴 `3-gitops` apply — **4단계 전용 · 3토막**

🔴🔴 **`terraform plan` 을 먼저 돌리지 마십시오. 성립하지 않습니다** `[10/25 함정 ⑿ · 10/28 리허설 재확인]`

```
Error: API did not recognize GroupVersionKind from manifest (CRD may not be installed)
  no matches for kind "Application" in group "argoproj.io"
  → root_app · loki_app · grafana_app · kube_prometheus_stack_app …
```

`kubernetes_manifest` 는 **plan 시점에** CRD 가 클러스터에 있어야 하는데, Argo CD CRD 는 **같은 apply 안의 `helm_release.argocd`** 가 만듭니다. 닭과 달걀입니다. **CI 가 apply 를 3토막으로 쪼갠 이유가 정확히 이것입니다**(`.gitlab-ci.yml:320~324`).

```bash
cd AWS/terraform/tokyo/rebuild/3-gitops
date -u +%FT%TZ | tee -a "$DRILL_DIR/times.txt"           # 시작
terraform init -backend-config=backend.hcl -input=false

# ① Argo CD 설치 → CRD 생성
terraform apply -target=helm_release.argocd -input=false -auto-approve 2>&1 | tee apply-1.log
# ② 🔸 도쿄에는 wait_for_karpenter_crds 가 없어 **no-op** 입니다.
#    "Resource targeting is in effect" 경고만 뜨고 exit 0 — 정상입니다(10/25 확인).
terraform apply -target=null_resource.wait_for_karpenter_crds -input=false -auto-approve 2>&1 | tee apply-2.log
# ③ 전체
terraform apply -input=false -auto-approve 2>&1 | tee apply-3.log

date -u +%FT%TZ | tee -a "$DRILL_DIR/times.txt"           # 끝(Terraform)
```

🔴 **`-auto-approve` 를 쓰는 근거** — 이 컴포넌트는 `plan` 을 볼 수 없습니다. 대신 **apply 전에 state 가 비어 있는지**로 안전을 확인합니다:

```bash
terraform state list | wc -l    # 🔴 첫 구축이면 0 이어야 합니다. 0 이 아니면 멈추고 확인
```

🔸 **CI 수동 잡으로 돌려도 됩니다**(`apply:tokyo-dr`). CI 는 위 3토막을 이미 그대로 돌립니다. 그 경우 잡 시작·끝 시각을 GitLab 화면에서 읽어 적습니다. 🔸 **CI 로 돌리면 ①-가 의 409 함정도 피합니다.**

🔴 **Terraform 이 끝난 것 ≠ 서비스가 떴다** — Terraform 은 Argo Application 객체만 만들고 실제 설치는 Argo 가 비동기로 합니다. 4단계 끝 시각은 **아래 수렴 확인**으로 찍습니다:

```bash
# 1분 간격. 🔴 39/40 에서 멈추는 것이 정상입니다 — 아래 상자 참고
while true; do
  kubectl --context "$TOKYO" -n argocd get applications.argoproj.io \
    -o custom-columns='S:.status.sync.status,H:.status.health.status' --no-headers \
    | awk '{t++} $1=="Synced"&&$2=="Healthy"{ok++} END{print strftime("%FT%TZ",systime(),1), ok"/"t}' \
    | tee -a "$DRILL_DIR/argo.txt"
  sleep 60
done
```

🔴 **4단계 완료 기준은 `40/40` 이 아니라 `39/40` 입니다** `[2026-10-28 리허설 실측]`

| | 도쿄(standby) | 서울(active) |
|---|---|---|
| Keycloak CR `spec.instances` | **0** | 1 |
| StatefulSet | 0/0 | 1/1 |
| Argo Application `keycloak` | **Degraded** | Healthy |

`instances: 0` 은 `dr_mode=standby` 가 **일부러** 넣는 패치입니다(`variables.tf` 의 `dr_mode` 설명 — *"Replica Cluster 는 `transaction_read_only` 라 Keycloak 은 구조적으로 못 뜬다"*). **standby 에서 keycloak 이 Healthy 가 될 길이 없습니다.** 10/28 리허설에서 나머지 39개가 11분에 전부 수렴한 뒤 keycloak 만 계속 Degraded 였습니다.

→ **`39/40` + `keycloak` 만 Degraded + CNPG `3/3` 이면 4단계 끝입니다.** `40/40` 은 **6단계 깨우기 뒤**에 됩니다. 🔸 이걸 모르면 있지도 않은 문제를 상한 48분까지 기다립니다.

---

🔴🔴 **함정 — LBC 웹훅 CA 가 어긋나면 CNPG 가 **아예 안 생깁니다** `[2026-10-28 실측 · 코드로 고침]`

증상이 DB 와 아무 상관 없어 보입니다:

| 보이는 것 | 실제 |
|---|---|
| `aquasentinel-pg` 가 `Unable to create required cluster objects` | **Service 를 못 만든 것**입니다 |
| `aquasentinel-db` 에 **파드 0개 · PVC 0개** | 복원이 **시작조차** 안 됐습니다 |
| `keycloak`·`web-backend`·`api-module-db-secret` Degraded | DB 가 없어서입니다 |

`phaseReason` 에 범인이 그대로 적혀 있습니다:

```
Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
tls: failed to verify certificate: x509: certificate signed by unknown authority
```

`mservice.elbv2.k8s.aws` 는 **모든 Service 생성**을 거치는 mutating 웹훅이고 `failurePolicy: Fail` 입니다. 차트가 렌더마다 새 자가서명 CA 를 만드는데, Argo 는 **웹훅 설정은 reconcile 마다 다시 쓰고 Secret 은 안 다시 씁니다**(Secret 값을 가려서 diff 하므로 늘 `Synced` 로 봅니다). 둘이 어긋나면 **클러스터의 모든 Service 생성이 거부**됩니다.

🟢 `applications.tf` 의 `ignoreDifferences` + `RespectIgnoreDifferences=true` 로 고쳤습니다. 그래도 **4단계에서 한 번 확인**하십시오 — 30초면 됩니다:

```bash
MB=$(kubectl --context "$TOKYO" get mutatingwebhookconfiguration aws-load-balancer-webhook \
      -o jsonpath='{.webhooks[0].clientConfig.caBundle}')
SB=$(kubectl --context "$TOKYO" -n kube-system get secret aws-load-balancer-tls \
      -o jsonpath='{.data.ca\.crt}')
[ "$MB" = "$SB" ] && echo "🟢 CA 일치" || echo "🔴 CA 불일치 — 아래 대처"
```

🔴 **어긋났을 때** — `caBundle` 을 Secret 에 맞춥니다. 🔸 수정이 들어가 있으면 Argo 가 **안 되돌립니다**(수정 전에는 3초 만에 되돌렸습니다):

```bash
CA=$(kubectl --context "$TOKYO" -n kube-system get secret aws-load-balancer-tls \
      -o jsonpath='{.data.ca\.crt}')
for K in mutatingwebhookconfiguration validatingwebhookconfiguration; do
  N=$(kubectl --context "$TOKYO" get $K aws-load-balancer-webhook \
        -o jsonpath='{.webhooks}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
  P=$(python3 -c "import json,sys;print(json.dumps([{'op':'replace','path':'/webhooks/%d/clientConfig/caBundle'%i,'value':sys.argv[1]} for i in range(int(sys.argv[2]))]))" "$CA" "$N")
  kubectl --context "$TOKYO" patch $K aws-load-balancer-webhook --type=json -p "$P"
done
```

🔸 **2분 안에 CNPG 가 저절로 풀립니다.** 10/28 실측 — 패치 `19:25:07` → `aquasentinel-db` Service **3개** `19:26:59` → `Cluster in healthy state` **3/3** `19:33:28`. **복원 전체 8분 21초.**


### ② ②③ 깨우기 (6단계)

🔴🔴 **`-var promote_tokyo_db=true` 를 반드시 같이 줍니다. 빠뜨리면 5단계 승격이 풀립니다.**

```bash
cd AWS/terraform/tokyo/rebuild/3-gitops

# 🔴 먼저 plan — `enabled` 가 바뀌면 멈춥니다(아래 상자)
terraform plan -input=false -var dr_mode=active -var promote_tokyo_db=true \
  | tee "$DRILL_DIR/wake-plan.log"
grep -nE '~ *enabled' "$DRILL_DIR/wake-plan.log"   # 🔴 아무것도 안 나와야 합니다

terraform apply -input=false -var dr_mode=active -var promote_tokyo_db=true
# 🔴 suspend_collectors 는 건드리지 않습니다 — 기본 true(멈춤) 그대로.
#    서울이 살아 있는데 도쿄 collector 가 같이 돌면 같은 공공 API 키로
#    호출이 2배가 되고, 한도에 걸리면 운영 #6·#7 이 깨집니다.
```

🔴🔴 **왜 플래그를 또 주는가 — `promote_tokyo_db` 는 끈적하지 않습니다** `[2026-10-28 리허설 실측]`

`promote_tokyo_db` 의 기본값은 `false` 입니다. 그래서 5단계 뒤에 플래그를 **빼고** apply 하면:

```
$ terraform plan -var dr_mode=active          # ← 플래그 없이
Plan: 0 to add, 5 to change, 0 to destroy
  # kubernetes_manifest.patched_app["cloudnativepg-cluster"] will be updated in-place
                    ~ enabled = false -> true        🔴🔴 승격이 풀립니다
```

| | |
|---|---|
| 무슨 일이 되나 | 방금 승격한 Primary 가 **다시 복제본**이 되어 `transaction_read_only = on` 으로 돌아갑니다 |
| 🔴 그런데 | **같은 apply 가 Keycloak 을 `instances: 1` 로 깨웁니다** → 읽기 전용 DB 에 스키마를 쓰려다 **CrashLoop** |
| 🔴 왜 치명적인가 | 그 증상이 **이미 아는 다른 버그(「도쿄 반영 목록」 #21 비밀번호 불일치)와 구별되지 않습니다.** 10/25 에 Keycloak CrashLoop 18회·82분을 겪은 그 화면이 그대로 나오고, **진짜 원인(플래그 누락)은 어디에도 안 보입니다** |
| 복구 | `-var promote_tokyo_db=true` 로 다시 apply (승격 자체는 되돌아오지만, 그 사이 쓰기가 들어갔다면 **그 쓰기는 사라집니다**) |

🔴 **규칙 — 5단계 이후 `3-gitops` 를 건드리는 모든 apply 에 `-var promote_tokyo_db=true` 를 붙입니다.** 6단계 · 2부 재적용 · destroy 까지 전부입니다. `variables.tf` 의 🔴🔴 경고(「`terraform.tfvars` 에 적지 마라」)는 **5단계 전**의 사고만 막습니다 — 5단계 뒤의 반대 사고는 이 규칙으로 막습니다.

---

🟢 **고쳤습니다 — `dr_mode=active` 가 api-module 가공·판정을 못 깨우던 문제** `[2026-10-28]`

리허설에서 apply 는 `exit 0`, Argo 는 `Synced/Healthy` 인데 **실제로는 안 깨어났습니다.** 원인은 `apps-kustomize.tf` 가 active 모드에서 `patches` **키 자체를 없애던 것**이고, Argo 의 diff 는 「키 삭제」를 차이로 보지 않습니다(`argocd app diff root` 가 **0줄 · exit 0**). 지금은 active 에서도 `patches = []` 를 남겨 **값의 변화**로 만듭니다.

| | 2026-10-28 실측 (도쿄 재구축 클러스터) |
|---|---|
| 적용 | `10:01:13Z` `terraform apply -var dr_mode=active` → `0 added, 4 changed` |
| 자식 패치 | `10:02:07Z` 3건 → **0건** |
| 깨어남 | `10:02:25Z` Rollout `1·2·2·2`(= 서울) · ScaledObject **4개 Ready=True** |
| 걸린 시간 | **72초** · 🟢 **손 작업 없음** |
| 수집기 | `collector-*` 6개 `suspend=true` 유지 🟢 |

🔸 그래서 6단계는 **위 apply 한 줄**이면 끝납니다. 아래 두 상자는 **그래도 안 될 때만** 봅니다.

---

🔴🔴 **그래도 안 깨어나면 — 먼저 `root` 의 멈춘 작업을 봅니다** `[2026-10-28 실측 · 이것 때문에 16분 낭비]`

Argo CD 는 `status.operationState.phase == Running` 인 동안 **새 동기화를 시작하지 않습니다.** 조사 중 제가 `argocd app sync root --force` 로 만든 작업 하나가 `Retrying operation. Attempt #4` 로 멈춰 **16분간 모든 전파를 막았고**, 이미 고친 코드까지 「실패」로 보이게 했습니다. 작업을 끝낸 뒤 **22초**에 정상 동작했습니다.

```bash
kubectl --context "$TOKYO" -n argocd get application root \
  -o jsonpath='{.status.operationState.phase}{"  "}{.status.operationState.message}{"\n"}'
# 🔴 Running 이면 아래로 끝내고 다시 봅니다. Succeeded / Failed / 빈 값이면 정상입니다.

kubectl --context "$TOKYO" config set-context --current --namespace=argocd
# 🔴 `argocd --core` 는 이 네임스페이스 전환이 필요합니다 — ARGOCD_NAMESPACE 도 `-N` 도 안 먹습니다.
argocd --core app terminate-op root
```

🔴 **훈련 중에는 `--force` 동기화를 쓰지 마십시오.** 이 함정의 출처가 그것입니다(`--force` 는 `--server-side` 와 같이 쓸 수도 없습니다).

---

🔴 **멈춘 작업도 없는데 안 깨어나면 — 자식 Application 의 패치를 직접 지웁니다**(수정 뒤에는 한 번도 필요하지 않았던 경로입니다. 썼으면 결과를 10.4「발견」에 적으십시오):

```bash
for a in api-module-evaluation api-module-grading api-module-interpolation \
         api-module-processor api-module-completeness-check; do
  kubectl --context "$TOKYO" -n argocd patch application "$a" --type=json \
    -p '[{"op":"remove","path":"/spec/source/kustomize/patches"}]' 2>/dev/null \
    && echo "  patched $a"
done
# 🔸 root 가 Synced 로 보고 있어 selfHeal 이 되돌리지 않을 것으로 봅니다 [추론]
#    되돌려지면 root 의 automated 를 잠시 끄고(아래) 다시 시도합니다.
#    kubectl -n argocd patch application root --type=merge \
#      -p '{"spec":{"syncPolicy":{"automated":null}}}'
#    🔴 끈 뒤 **반드시 복구**합니다:
#    kubectl -n argocd patch application root --type=merge \
#      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

**깨어났는지 확인** — 이게 6단계의 진짜 완료 조건입니다:

```bash
kubectl --context "$TOKYO" -n api-module get rollout \
  -o custom-columns='NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas'
# 🔴 서울 기준값: evaluation=1 · grading=2 · interpolation=2 · processor=2
kubectl --context "$TOKYO" -n api-module get scaledobject    # 🔴 0개면 안 깨어난 것
```

🔸 **왜 중요한가** — 계획서가 정한 DR 복구 완료의 기준이 *「해양 데이터가 다시 신선해지는 것」* 이고 그걸 되살리는 주체가 이 4개 워크로드입니다. 안 깨어나면 **전환이 완료되지 않습니다.**

🔸 **수집기는 그대로 멈춰 있어야 정상입니다** — `suspend_collectors` 는 `dr_mode` 와 **다른 축**(`apps-kustomize.tf:45`)이라 `dr_mode=active` 여도 `collector-*` 6개는 `suspend=true` 를 유지합니다 `[10/28 실측 · terraform show -json 으로 확인]`. `dr_mode=active` 가 빼는 suspend 는 `evaluation-sweep`·`interpolation-error` 둘뿐이고, 이들은 공공 API 를 호출하지 않습니다.

### ②-1 🔴 7단계 뒤 — **시크릿이 파드까지 닿아야 끝납니다** `[2026-10-28 실측]`

`DB다시부트스트랩` 의 `ALTER ROLE` 은 **2초**면 끝나지만 그것만으로는 파드가 안 붙습니다. 비밀번호가 **네 단계**를 거칩니다:

```
CNPG Secret        aquasentinel-db/aquasentinel-pg-app
   │  PushSecret      → 도쿄 Secrets Manager 로 밀어 올림
   ▼
Secrets Manager    aquasentinel-dr-tokyo-api-module-database-*
   │  ExternalSecret  🔴 새로고침 주기 **1시간**
   ▼
K8s Secret         api-module/api-module-database · web/aquasentinel-pg-app
   │  env            🔴 파드가 **뜰 때** 읽습니다(마운트가 아닙니다)
   ▼
파드
```

🔴 **두 군데서 막힙니다**

1. ExternalSecret 이 **1시간 주기**라 PushSecret 이 올린 새 값을 바로 안 가져옵니다
2. 그 갱신 **시각보다 먼저 뜬 파드**는 옛 비밀번호를 **env** 로 들고 있어 자동으로 안 바뀝니다

**그래서 `ALTER ROLE` 뒤에 이 둘을 합니다**:

```bash
# ① ExternalSecret 전부 강제 새로고침
for NS in api-module web; do
  for E in $(kubectl --context "$TOKYO" -n $NS get externalsecret -o name); do
    kubectl --context "$TOKYO" -n $NS annotate "$E" force-sync="$(date +%s)" --overwrite
  done
done

# ② 갱신 시각보다 먼저 뜬 파드를 찾습니다 — 이 중 Ready 가 아닌 것을 이름으로 지웁니다
T=$(kubectl --context "$TOKYO" -n api-module get externalsecret api-module-database \
      -o jsonpath='{.status.refreshTime}')
echo "갱신 시각: $T"
kubectl --context "$TOKYO" get pods -A --no-headers \
  -o custom-columns='NS:.metadata.namespace,N:.metadata.name,S:.status.startTime' \
  | awk -v t="$T" '$3 < t' | grep -E 'api-module|web|keycloak'
```

🔸 **누가 실패하는지 1초에 찾는 법** — PG 로그의 출처 IP 를 파드로 되돌립니다:

```bash
kubectl --context "$TOKYO" -n aquasentinel-db logs aquasentinel-pg-1 -c postgres --since=90s \
  | grep 'password authentication failed' \
  | python3 -c 'import sys,json;from collections import Counter;c=Counter()
for l in sys.stdin:
    try: r=json.loads(l)["record"]
    except Exception: continue
    c[r.get("connection_from","").split(":")[0]]+=1
[print(k,v) for k,v in c.most_common()]' \
  | while read IP N; do
      echo "  $IP ${N}건 → $(kubectl --context "$TOKYO" get pods -A -o wide --no-headers | awk -v i=$IP '$7==i{print $1"/"$2; exit}')"
    done
```

**10/28 실측 (KST)**

| 시각 | 무엇 | 소요 |
|---|---|---|
| 20:04:12 | `ALTER ROLE app PASSWORD` | **2초** |
| 20:10:47 | ExternalSecret 강제 새로고침 · 비밀번호 일치 확인 | 4초 |
| ~20:11 | 🔸 `api-module` 4종은 CrashLoop 재시도로 **스스로** 붙음(재기동 불필요) | — |
| 20:17:25 | `web-backend` 2개 재기동 → **2/2** · Argo **40/40** | 34초 |
| 20:18:54 | 남은 옛 파드(`alert-worker` · `raw-coverage`) 정리 → **비정상 0** | 49초 |
| | **7단계 전체** | **15분 31초** |

🔴 리허설 **7분 44초**보다 두 배 깁니다 — 위 두 함정 때문입니다. **당일 예상은 16분으로 잡으십시오.**

🟢 **7단계 완료 기준(= 1부 완료 기준)**: Argo **40/40** · 비정상 파드 **0** · PG `password authentication failed` **0** · `/readyz` **200**. 10/28 에 네 가지 모두 확인했고, 같은 시각 서울은 **41/41 · 비정상 0** 으로 영향 없었습니다.


### ③ ⑤ 드릴 레코드 (8단계 — 도쿄 SECONDARY 만듦)

```bash
cd AWS/terraform/tokyo/rebuild/4-edge
terraform init -backend-config=backend.hcl -input=false
# 🔴🔴 훈련에서는 **반드시** failover_hostnames=[] 를 준다 (아래 상자 참고)
terraform apply -input=false -var 'failover_hostnames=[]'

# 전환은 서울 쪽 헬스체크를 뒤집어서 합니다
cd ../../../seoul/rebuild/4-edge
terraform apply -input=false -var drill_health_check_inverted=true
```

🔴🔴 **`-var 'failover_hostnames=[]'` 를 빠뜨리면 안 됩니다**(2026-10-28 신설)

| | |
|---|---|
| 빠뜨리면 | 운영 도메인 **apex · `auth.` · `grafana.`** 의 SECONDARY 가 **같이 생깁니다** |
| 왜 나쁜가 | 훈련은 `dr-drill.` 만 넘깁니다(계획서 8.1 (나)안). 그 셋은 **한 번도 안 쓰이는데**, 떠 있는 동안 서울 운영 헬스체크(`f9f9a297`)가 잠깐 흔들리면 🔴 **진짜 사용자가 도쿄로 갑니다** |
| 🔸 `dr-drill` 은? | **영향 없습니다** — 모듈이 `drill_hostnames` 로 따로 만듭니다 |
| 🔸 실제 DR 때는 | 기본값(`["", "auth", "grafana"]`)을 그대로 씁니다 — 그때는 운영 도메인도 넘어가야 합니다 |

**확인** — apply 뒤 SECONDARY 가 **`dr-drill.` 하나뿐**인지 봅니다:

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z04047191I2SWBLU7U7D \
  --query 'ResourceRecordSets[?Failover==`SECONDARY`].[Name,Type]' --output text
# 🔴 dr-drill.aquasentinel.cloud. A  한 줄만 나와야 합니다
```

🔸 **11-3 보충 — 로그인은 되고, 로그아웃만 막힙니다** `[2026-10-28 실측]`

서울 Keycloak 에 **드릴 주소가 제대로 등록돼 있습니다.** 도쿄를 띄워 놓고 직접 물어본 결과:

| 물어본 것 | 서울 Keycloak 응답 |
|---|---|
| `https://dr-drill.aquasentinel.cloud/auth/callback` | **200 · 로그인 화면** 🟢 |
| 운영 apex `/auth/callback` (대조군) | 200 🟢 |
| 등록 안 된 가짜 주소 (대조군) | 400 🔴 |
| 🔸 **로그아웃** `post_logout_redirect_uri=https://dr-drill.…/` | **400** — 등록 목록에 없습니다 |

🔸 도쿄 프론트 번들이 쓰는 콜백 경로도 **`/auth/callback`** 으로 등록값과 같습니다. 그래서 **11-3(로그인 → 대시보드)은 막히지 않습니다.**

🔴 다만 **드릴 주소에서 로그아웃하면 400** 이고, Keycloak 은 주소 검증을 세션 종료보다 먼저 해서 **SSO 세션이 안 끊깁니다**(운영 도메인은 10/27 `7763a2f` 로 고쳐졌지만 드릴 주소에는 안 넣었습니다). 🔸 **B 는 프라이빗 창으로 열고 로그아웃 대신 창을 닫으십시오.** 고치려면 서울 `3-gitops` 에 `redirectUris` 한 줄을 더해야 하는데 **창 안 운영 변경**이라 훈련용으로는 권하지 않습니다.

---


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

🟢 **이 명령을 2026-10-28 리허설에서 실제로 돌렸습니다 — 전부 통합니다** `[사실]`

| 호출 | 결과 |
|---|---|
| `/readyz` | **200** · TLS 0.19s · total 0.26s |
| `/healthz` · `/metrics` | **200** · **200** |
| `/` (프론트) | **200** |
| `/api/farms/$FARM_ID/status` — **토큰 없이** | **401** ← 인증이 제대로 걸려 있다는 뜻 |

🔸 즉 **`$TOKEN` 이 비어 있으면 `status=401` 로 영원히 돌게 됩니다.** 0.1 ⑤ 의 (가-2) 토큰을 **7단계 직전에** 받는 이유입니다. 폴링을 걸기 전에 `[ -n "$TOKEN" ]` 를 확인하십시오.

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
| **0** | 🔴🔴 **데드맨 체크 Pause — C 에게 먼저 연락** | **destroy 보다 먼저.** 도쿄를 내리면 핑이 끊겨 **유예 5분 뒤 오경보** · 🔴 **Pause 단독으로는 안 됩니다 — 아래 3.0** |
| 1 | 도쿄 `rebuild/*` **전량 destroy** | EKS·ALB·NAT·EC2·EBS·EIP·Redis·VPC **전부 0**. 🔴 `4-edge` 도 여기 포함 |
| 2 | 피어링 + 양쪽 라우트 — `5-peering` **destroy 한 번** | 양 리전 피어링 **0** · 라우트에 상대 CIDR 없음 *(1부 뒤엔 해당 없음)* |
| 3 | 서울 내부 NLB — gitops `kustomization.yaml` **한 줄 삭제** | 서울 NLB **0**. LBC 가 SG 까지 같이 지웁니다 *(1부 뒤엔 해당 없음)* |
| 5 | 드릴 헬스체크 | `-var drill_health_check_inverted=false` 로 원복 |
| **6** | 🔴 **도쿄 러너 다시 Paused** | GitLab Runners 화면 |
| **6-1** | 🔴🔴 **S3 잔재 — `cloudnativepg-tokyo/` · 도쿄 Thanos 블록** | 🔴 **안 지우면 다음 구축이 `Expected empty archive` 로 멈춥니다**(10/25 실제) |
| 7 | 과금 자원 **0** | 아래 **3.3** 명령 |
| 8 | 남기는 것 | `tokyo/persistent`(S3 3 · ACM 1) · Secrets · ECR · 🔸 러너 EC2(Paused) |
| 9 | 기본 컨텍스트 | `kubectl config use-context $SEOUL` · 🔸 `dr-tokyo` 컨텍스트 항목도 삭제 |

🔴 **6-1 지울 때 접두사를 눈으로 확인하십시오** — `cloudnativepg/`(끝에 `-tokyo` 없음)는 **서울 백업의 복제본이자 DR 자산**(지금 4,413개)이라 지우면 **리전 장애 때 복구가 불가능**해집니다. 🔸 판별은 **접두사 이름이 아니라 `ReplicationStatus`** 로 합니다 — 아래 3.2.

### 3.0 🔴🔴 #0 — Pause 만 걸면 1분 안에 저절로 풀립니다 `[scripts/alerting/README.md:12 · 20 · 63]`

도쿄 체크는 「Ignore pings while paused」가 **꺼져** 있어, **일시정지된 체크가 핑을 받으면 바로 다시 감시로 돌아갑니다.** destroy 직전에는 Alertmanager 가 아직 살아서 Watchdog 을 **1분마다** 보냅니다. 그래서 순서가 이렇게 흐릅니다.

> Pause → **다음 핑에 해제** → destroy 로 Alertmanager 소멸 → **유예 5분 뒤 `#regiondr-tokyo` 에 down 알림**

즉 #0 이 막으려던 오경보가 그대로 납니다. README 가 적은 순서는 **⑴ Silence 를 먼저(Watchdog 까지 포함) → ⑵ Watchdog 이 Silence 된 것 확인 → ⑶ 그다음 Pause** 이고, `scripts/alerting/maintenance.sh start` 가 이 순서를 보장합니다.

- 🔸 Silence 기간은 **teardown 전체**(`2-cluster` destroy 끝까지)를 덮어야 합니다 — 그 전에 만료되면 Alertmanager 가 살아 있는 채로 핑이 재개돼 체크가 풀리고, 곧이어 같은 오경보가 납니다. 10/28 리허설 뒷정리는 **49분**이었습니다.
- 🔸 **수단은 C 와 맞추십시오** — 알람 파이프라인은 C 영역이고 `maintenance.sh` 는 `HC_API_KEY`(읽기·쓰기)와 Alertmanager exec 가 필요합니다.
- 🔴 **1부 뒤 · 2부 뒤 각각** 해당합니다.

🟢 **거꾸로, 2부 0단계 뒤에는 되살리는 조작이 필요 없습니다** — 도쿄를 다시 세우면 새 Alertmanager 의 첫 Watchdog 핑으로 체크가 **자동 재개**됩니다. 확인만 합니다: `3-gitops` apply 후 **15분이 지나도 `paused`** 면 `maintenance.sh stop` `[README:72]`.

### 3.1 🔴🔴 `3-gitops` destroy 가 네임스페이스에서 멈춥니다 `[2026-10-28 리허설 실측]`

```
Error: Kubernetes delete error
  timeout while waiting for resource to be gone (last state: 'Terminating', timeout: 5m0s)
```

`monitoring` 네임스페이스가 **영구히** `Terminating` 입니다. 원인이 **둘**이고 **둘 다** 고쳐야 합니다.

| | 무엇이 막나 | 왜 |
|---|---|---|
| **(a)** | 고아 **webhook** 이 삭제 **요청**을 거부 | destroy 가 `external-secrets` 네임스페이스를 **먼저** 지웠는데, 클러스터 범위인 `externalsecret-validate`·`secretstore-validate`(둘 다 `failurePolicy: Fail`)가 남아 **모든 ExternalSecret 삭제를 거부**합니다 |
| **(b)** | 고아 **finalizer** 가 삭제 **완료**를 막음 | `externalsecrets.external-secrets.io/externalsecret-cleanup` 를 떼어 줄 **컨트롤러가 이미 사라졌습니다** |

확인하는 법 — 네임스페이스 조건에 그대로 적혀 있습니다:

```bash
kubectl --context "$TOKYO" get ns monitoring \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
# (a) NamespaceDeletionContentFailure=True ... service "external-secrets-webhook" not found
# (b) NamespaceFinalizersRemaining=True ... externalsecret-cleanup in N resource instances
```

**복구 — 순서대로**:

```bash
# (a) 고아 webhook 제거
kubectl --context "$TOKYO" delete validatingwebhookconfiguration \
  externalsecret-validate secretstore-validate

# (b) 남은 ExternalSecret 의 finalizer 를 직접 비움 (네임스페이스 전수)
for ns in $(kubectl --context "$TOKYO" get ns --no-headers | awk '$2=="Terminating"{print $1}'); do
  for n in $(kubectl --context "$TOKYO" -n "$ns" get externalsecrets.external-secrets.io \
             -o name --ignore-not-found 2>/dev/null); do
    kubectl --context "$TOKYO" -n "$ns" patch "$n" --type=merge \
      -p '{"metadata":{"finalizers":[]}}'
  done
done

# destroy 를 다시 돌립니다 (🔴 플래그 2개 유지)
cd AWS/terraform/tokyo/rebuild/3-gitops
terraform destroy -input=false -auto-approve -var dr_mode=active -var promote_tokyo_db=true
terraform state list | wc -l    # 🔴 0 이어야 합니다
```

🔸 10/28 리허설에서 1회차 `exit 1`(58분 묶임) → 위 2줄 → 2회차 `exit 0` · state 0개. **10/25 뒷정리 34분의 원인일 가능성이 큽니다.**

### 3.2 🔴🔴 Terraform 뒤에 **손으로 걷어낼 3종** `[2026-10-28 리허설 실측]`

`terraform destroy` 는 **자기 state 에 있는 것만** 지웁니다. 아래 셋은 **컨트롤러가 만든 것**이라 state 에 없고, 둘은 **계속 과금**되며 둘은 **VPC 삭제를 막습니다.**

| 조각 | 만든 주체 | 과금 | VPC 차단 |
|---|---|---|---|
| **ALB** `k8s-ingress-aquasent-*` + 대상 그룹 | **LBC**(Gateway 보고) | 🔴 **예** | 🔴 예(서브넷 ENI) |
| **EBS** `*-dynamic-pvc-*` (리허설 때 **6개 · 60 GiB**) | **EBS CSI**(PVC 보고) | 🔴 **예** | 아니오 |
| **SG** `k8s-ingress-aquasent-*` · `k8s-traffic-*` | **LBC** | 아니오 | 🔴 **예** |

🔴🔴 **증상은 `1-network` destroy 가 VPC 에서 끝나지 않는 것입니다 — 기다려도 안 끝납니다.** 10/28 2회차 실측: `Still destroying... [13m30s elapsed]` 까지 **계속 재시도만** 했고, ENI 도 서브넷도 이미 0이었습니다. 남아 있던 것은 **SG 2개**(`k8s-ingress-aquasent-*` · `k8s-traffic-*`)뿐이었고, **그 둘을 지우자 4초 만에 끝났습니다.** 🔸 1회차에는 7분 31초로 끝나 「느릴 뿐」로 보였는데, 2회차에서 **끝나지 않는다**는 것이 드러났습니다. 🔴 **VPC 가 5분 넘게 `Still destroying` 이면 기다리지 말고 아래 ④(SG)부터 돌리십시오.**

```bash
export AWS_PAGER=""
R=ap-northeast-1

# ① ALB 먼저 (ENI 를 놓아 줍니다)
for arn in $(aws elbv2 describe-load-balancers --region $R \
             --query 'LoadBalancers[].LoadBalancerArn' --output text); do
  aws elbv2 delete-load-balancer --region $R --load-balancer-arn "$arn"
done
# ② ALB 가 완전히 사라진 뒤 대상 그룹
until [ "$(aws elbv2 describe-load-balancers --region $R --query 'length(LoadBalancers)' --output text)" = 0 ]; do sleep 10; done
for tg in $(aws elbv2 describe-target-groups --region $R --query 'TargetGroups[].TargetGroupArn' --output text); do
  aws elbv2 delete-target-group --region $R --target-group-arn "$tg"
done
# ③ 고아 EBS — 🔴 **이름표까지 보고 좁힙니다**
#    `available` 만으로 거르면 **러너가 꺼져 있을 때 그 루트 볼륨까지 지웁니다.**
#    지울 것은 EBS CSI 가 PVC 보고 만든 `aquasentinel-dr-apne1-eks-dynamic-pvc-*` 뿐입니다.
aws ec2 describe-volumes --region $R --filters Name=status,Values=available \
  --query "Volumes[?Tags[?Key=='Name' && starts_with(Value,'aquasentinel-dr-apne1-eks')]].VolumeId" \
  --output text | tr '\t' '\n' | while read -r v; do
    [ -z "$v" ] && continue
    aws ec2 delete-volume --region $R --volume-id "$v" && echo "  deleted $v"
  done
# 🔸 `--output text` 는 **탭 한 줄**로 내려옵니다. `V=$(...)` 에 담아 `for v in $V` 로 돌리면
#    zsh(맥 기본 셸)는 **단어를 안 쪼개** ID 하나로 넘겨 `is malformed` 로 실패합니다(10/28 실제).
#    위처럼 `tr '\t' '\n' | while read` 를 쓰면 셸에 상관없이 됩니다.
# ④ LBC 고아 SG — 서로 참조하므로 규칙을 먼저 비웁니다
for sg in $(aws ec2 describe-security-groups --region $R \
            --query "SecurityGroups[?starts_with(GroupName,'k8s-')].GroupId" --output text); do
  for d in ingress egress; do
    K=IpPermissions; [ $d = egress ] && K=IpPermissionsEgress
    P=$(aws ec2 describe-security-groups --region $R --group-ids "$sg" --query "SecurityGroups[0].$K" --output json)
    [ "$P" != "[]" ] && aws ec2 revoke-security-group-$d --region $R --group-id "$sg" --ip-permissions "$P" >/dev/null
  done
  aws ec2 delete-security-group --region $R --group-id "$sg"
done
```

**S3 잔재는 `ReplicationStatus` 로 가릅니다** — 🔴 **접두사 이름으로 판단하지 마십시오.**

```bash
# RS=None  → 도쿄가 직접 쓴 것 = 지움
# RS=REPLICA → 서울에서 CRR 로 온 DR 복구 원본 = 🔴 남김
for B3 in aquasentinel-dr-tokyo-observability-379937169195 \
          aquasentinel-dr-tokyo-loki-379937169195 \
          aquasentinel-dr-tokyo-raw-store-379937169195; do
  echo "[$B3]"
  aws s3 ls "s3://$B3/" --recursive | awk -v d="$(date -u +%F)" '$1==d{print $4}' \
   | awk -F/ '{print $1}' | sort -u | while read -r pre; do
      K=$(aws s3 ls "s3://$B3/$pre/" --recursive | head -1 | awk '{print $4}')
      RS=$(aws s3api head-object --bucket "$B3" --key "$K" --query ReplicationStatus --output text)
      echo "   $pre/  RS=$RS"
    done
done
# 10/28 실측: cloudnativepg-tokyo/ 168개 RS=None(삭제) · loki fake/·index/ 32개 RS=None(삭제)
#             cloudnativepg/·thanos/·raw/ 는 전부 RS=REPLICA(남김)
```

🔸 **도쿄 Thanos 블록은 2시간 블록 주기 때문에 1부(약 1시간)에는 안 생길 수 있습니다** — 10/28 엔 `thanos/` 의 당일 객체 27개가 **전부 `RS=REPLICA`** 였습니다. 10/25 의 「도쿄 블록 3」과는 다른 상황이니 **세지 말고 `RS` 로 판별**하십시오.

### 3.3 과금 자원 0 — 최종 확인 명령

```bash
export AWS_PAGER=""; R=ap-northeast-1
printf "EKS %s · Redis %s · NAT %s · ALB %s · TG %s · VPC %s · EBSavail %s · EIP %s\n" \
  "$(aws eks list-clusters --region $R --query 'length(clusters)' --output text)" \
  "$(aws elasticache describe-replication-groups --region $R --query 'length(ReplicationGroups)' --output text)" \
  "$(aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available --query 'length(NatGateways)' --output text)" \
  "$(aws elbv2 describe-load-balancers --region $R --query 'length(LoadBalancers)' --output text)" \
  "$(aws elbv2 describe-target-groups --region $R --query 'length(TargetGroups)' --output text)" \
  "$(aws ec2 describe-vpcs --region $R --filters Name=isDefault,Values=false --query 'length(Vpcs)' --output text)" \
  "$(aws ec2 describe-volumes --region $R --filters Name=status,Values=available --query 'length(Volumes)' --output text)" \
  "$(aws ec2 describe-addresses --region $R --query 'length(Addresses)' --output text)"
# 🔴 전부 0 이어야 합니다. Terraform state 도 함께:
for c in 1-network 2-cluster 3-gitops 4-edge; do
  printf "  %-12s %s\n" "$c" "$(cd AWS/terraform/tokyo/rebuild/$c && terraform state list | wc -l)"
done
```

**2026-10-28 리허설 뒷정리 실측** `[사실]` — 위 전부 **0** · state `1~4` 전부 **0**.
의도적 상주: EC2 러너 `aquasentinel-dev-gitlab-runner-tokyo`(t3.medium · GitLab **Paused**) + 루트 볼륨 50 GiB `in-use` · CRR 복제본(`cloudnativepg/` 4,413 · `thanos/` 621 · `raw/` 23,477).

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

## 부록 A — 🔴 CNPG 승격 (1부 5단계 · 2부 5단계)

🔴 **못 되돌리는 단계입니다.** 명령을 치기 전에 아래 순서를 끝까지 읽으십시오.

### A.1 무엇을 하는 것인가

도쿄 DB 는 **복제본**(Replica Cluster)입니다 — 읽기만 되고 서울을 계속 따라갑니다. 승격은 그 DB 를 **주인(Primary)** 으로 바꿔 쓰기가 되게 하는 것입니다. 바뀌는 값은 하나 — `spec.replica.enabled` 가 `true → false` 입니다.

### A.2 🔴 `kubectl` 로 하지 않습니다

| | |
|---|---|
| 왜 | 그 값을 **Argo CD 가 쥐고 있습니다.** `applications.tf` 의 kustomize 패치가 `enabled` 를 박아 넣고, 그 Application 의 동기화 정책이 **`automated.selfHeal = true`** 입니다 `[실측]` |
| 그래서 | `kubectl patch` 로 바꾼 값은 Argo 가 **원하는 상태로 되돌립니다** `[추론 — 강한 근거]`. 승격이 풀립니다 |
| 대신 | 🔸 **원하는 상태 자체를 바꿉니다** — `promote_tokyo_db` 변수(2026-10-28 신설) |

### A.3 절차

**① 먼저 지금 상태를 찍습니다** — 승격 전이 맞는지 확인합니다.

```bash
date -u +%FT%TZ | tee -a "$DRILL_DIR/times.txt"       # T_promote_start
kubectl --context "$TOKYO" exec -n aquasentinel-db aquasentinel-pg-1 -c postgres -- \
  psql -U postgres -tAc "SELECT pg_is_in_recovery();"     # 🔴 t 여야 합니다
kubectl --context "$TOKYO" get cluster -n aquasentinel-db aquasentinel-pg \
  -o jsonpath='{.spec.replica}{"\n"}'                     # enabled:true 확인
```

🔴 **여기서 `f` 가 나오면 멈추십시오.** 이미 주인이라는 뜻이고, 4단계에서 승격 스위치가 잘못 켜졌을 가능성이 큽니다(A.5).

**② plan 을 먼저 봅니다** — 🔴 **건너뛰지 마십시오. 아직 실제로 돌려 본 적이 없는 경로입니다.**

```bash
cd AWS/terraform/tokyo/rebuild/3-gitops
terraform plan -input=false -var promote_tokyo_db=true | tee "$DRILL_DIR/promote-plan.log"
```

| 보이는 것 | 판단 |
|---|---|
| `1 to change` 이고 바뀌는 것이 **Cluster 패치 하나** | ✅ 진행 |
| 다른 것이 같이 바뀜 · `to destroy` 가 0 이 아님 | 🔴 **멈추고 확인** |

**③ apply**

```bash
terraform apply -input=false -var promote_tokyo_db=true 2>&1 | tee "$DRILL_DIR/promote-apply.log"
```

**④ 승격됐는지 확인** — Argo 가 반영할 때까지 기다립니다.

```bash
while true; do
  printf '%s  ' "$(date -u +%H:%M:%SZ)"
  kubectl --context "$TOKYO" exec -n aquasentinel-db aquasentinel-pg-1 -c postgres -- \
    psql -U postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null || echo "(조회 실패)"
  sleep 10
done | tee -a "$DRILL_DIR/promote.txt"
```

| 기록할 것 | 기대 | 실측 |
|---|---|---|
| `pg_is_in_recovery()` 가 **f** 로 바뀐 시각 | — | ⟨ ⟩ |
| 승격에 걸린 시간 = 그 시각 − `T_promote_start` | 🔸 리허설 **28초**(안정화까지 1분 27초) | ⟨ ⟩ |
| CNPG Cluster 상태 | Ready 3/3 | ⟨ ⟩ |

🔸 **2분이 지나도 `t` 면** Argo 동기화 상태를 봅니다 — `kubectl --context "$TOKYO" -n argocd get application cloudnativepg-cluster -o jsonpath='{.status.sync.status}'`. `OutOfSync` 면 Argo 가 아직 안 돈 것이고, `Synced` 인데 `t` 면 🔴 **이 경로가 안 먹는다는 뜻**이라 그대로 적고 A.4 로 갑니다.

🟢 **2026-10-28 리허설에서 이 경로를 실제로 돌렸습니다 — 먹습니다** `[사실]`

| 확인 | 승격 전 | 승격 후 |
|---|---|---|
| `terraform plan` | — | **`0 to add, 1 to change, 0 to destroy`** · 바뀐 것은 `patched_app["cloudnativepg-cluster"]` **하나** · diff 는 `enabled = true -> false` 하나 · `source="seoul"`·`barmanObjectName` 유지 |
| `pg_is_in_recovery()` | `t` | **`f`** (apply 뒤 **28초**) |
| `SHOW transaction_read_only` | on | **off** |
| 실제 쓰기 | — | `CREATE TABLE` · `INSERT 0 1` 성공 |
| CNPG Cluster | 3/3 replica | **`Cluster in healthy state` · 3/3 · `replica.enabled=false`** (1분 27초) |
| 🔴 `selfHeal` 되돌림 | — | **없음** — 원하는 상태를 바꿨으니 되돌릴 것이 없습니다 |

🔸 그래서 **A.4 대비책은 쓰지 않아도 될 것으로 봅니다.** 다만 당일에도 ② plan 확인은 그대로 합니다.

🔴 **승격 뒤 바로 다음 단계로 가기 전에** — 6단계 명령에 `-var promote_tokyo_db=true` 가 들어 있는지 확인하십시오(1장 ②). 빠지면 **지금 한 승격이 풀립니다.**

### A.4 🔴 안 되면 — 그 자리에서 쓸 대비책

```bash
# Argo 자동 동기화를 잠시 끄고 손으로 바꿉니다
argocd app set <cnpg앱> --sync-policy none
kubectl --context "$TOKYO" patch cluster -n aquasentinel-db aquasentinel-pg \
  --type=merge -p '{"spec":{"replica":{"enabled":false}}}'
# 🔴 훈련이 끝나면 **반드시** 되돌립니다 — 빠뜨리면 도쿄 Argo 가 멍한 채 남습니다
argocd app set <cnpg앱> --sync-policy automated --auto-prune --self-heal
```

🔴 **이 경로를 쓰게 되면 그 사실과 걸린 시간을 10.4「발견」에 적습니다** — 변수 방식이 안 먹었다는 것이 결과입니다.

### A.5 🔴🔴 하지 말 것

| | 무엇 | 왜 |
|---|---|---|
| 1 | **4단계에 `-var promote_tokyo_db=true` 를 붙이는 것** | 처음부터 복제본이 아니게 떠서 **서울을 따라가지 않습니다.** 5단계에 잴 것이 없고 2부 스트리밍도 성립하지 않습니다 |
| 2 | 🔴 **`terraform.tfvars` 에 적는 것** | **모든 apply 에 자동으로 붙어** 위 사고가 납니다. 명령줄에서만 씁니다 |
| 3 | 승격 전에 되돌리기(2부 3단계)를 건너뛰는 것 | 승격하면 **#6 을 영영 못 잽니다**(`Stage2…` 3장) |

🔸 1번이 일어나도 **데이터는 안 날아갑니다** — 서울은 멀쩡하고 도쿄는 백업 복구본입니다. 잃는 것은 **시간**(도쿄 destroy + S3 잔재 삭제 + 재구축 ≈ 1시간)입니다.

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
