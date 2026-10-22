# 테스트필드 — 시험 계정 사전 준비

`prep-account.sh` 는 Terraform apply 전에 **시험 계정에 손으로 만들어야 하는 15개**를 한 번에 만든다.

| 묶음 | 개수 | 왜 손으로 만들어야 하나 |
|---|---|---|
| EC2 Spot 서비스 연결 역할 | 1 | 처음 스팟을 쓰는 계정에는 없다. 없으면 Karpenter 가 스팟 노드를 못 띄운다 |
| IAM 역할 | 2 | Terraform 이 **이름 문자열로만 참조**한다 — 레포가 만들지 않는다(아래) |
| Secrets Manager | 12 | `3-gitops` 가 **plan 단계에서** 읽는다. 없으면 plan 부터 실패 |

관련 문서: `AWS/docs/테스트필드_기동_필요조건_실측정리_2026-10-19.md` 3·4·6장

---

## 쓰는 법

```bash
./prep-account.sh --init                                  # 설정 파일 틀 생성
vi testfield-prep.conf                                    # 값 5개 채우기(공공 API 키는 이미 들어 있음)
./prep-account.sh --config testfield-prep.conf            # 계획만 보기 (기본)
./prep-account.sh --config testfield-prep.conf --apply    # 실제 생성
./prep-account.sh --verify                                # 빠진 것 없는지 확인
rm testfield-prep.conf                                    # 비밀값이 들어 있다 — 삭제
```

**시험 계정 자격증명으로 실행한다.** `aws sts get-caller-identity` 로 먼저 확인할 것.

### 직접 채울 값 — 필수 4개 + Healthchecks 1개

| 변수 | 값 |
|---|---|
| `GITOPS_TOKEN` | `aquasentinel-gitops` 레포 읽기 전용 GitLab 토큰(`read_repository`) |
| `DISCORD_CRITICAL` · `DISCORD_WARNING` · `DISCORD_ARGOCD` | 시험 전용 Discord 웹훅 |

공공 API 키 4개(`DTRECENT_KEY` · `NIFS_KEY_BULLETIN` · `NIFS_KEY_FISHERY_SEA` · `NIFS_KEY_LINE`)는 **스크립트에 박혀 있어 채우지 않아도 된다.**

> ⚠️ **그 값은 운영에서 쓰는 키와 같다.** 2026-10-06 모듈팀 flowtest 묶음으로 받은 키이고, 운영 Secrets Manager 의 값과 글자까지 같다. 하루 호출 한도가 키 단위라 **시험 구역 호출만큼 운영 수집 몫이 줄어든다.** 시험 계정 전용 키를 받으면 설정 파일에 넣을 것 — 그쪽이 이긴다. 실행하면 기본값을 쓰는 동안 매번 `[주의]` 가 뜬다.
>
> 그래서 **`prep-account.sh` 는 커밋하지 않는다** — 같은 디렉터리 `.gitignore` 가 막는다. 팀원에게는 파일을 직접 전달한다(메신저·이슈·MR 본문에 붙여넣지 않는다).

**Healthchecks 는 둘 중 하나만** 채우면 된다.

| 방식 | 변수 | |
|---|---|---|
| **(권장)** 스크립트가 체크를 만듦 | `HEALTHCHECKS_API_KEY` | 프로젝트 API 키(쓰기 가능). 체크 이름 `aquasentinel-testfield-<계정ID>`, 같은 이름이 있으면 재사용 |
| 직접 만든 것을 붙여넣기 | `HEALTHCHECKS_PING` | 콘솔에서 만든 체크의 핑 URL |

API 키 쪽을 권하는 이유 — **운영 핑 URL을 실수로 붙여넣는 사고를 구조적으로 막는다.** 그 실수가 나면 시험 구역 Watchdog 이 운영 체크를 계속 살려둬서 **운영 경보 경로가 끊겨도 데드맨이 울리지 않는다.**

나머지 5개(Keycloak·Grafana 비밀번호류)는 스크립트가 32자 영숫자로 만든다.

### 왜 나머지는 자동화하지 않나

| 값 | 이유 |
|---|---|
| 공공 API 키 4개 | 공공데이터포털·NIFS 에 **신청하고 승인을 기다려야** 한다(1~2일). 자동 발급 수단이 없어 **기존 키를 그대로 박아 넣었다** |
| Discord 웹훅 3개 | API 는 있지만 봇을 만들고 `Manage Webhooks` 권한을 주는 게 **손으로 3개 만드는 것보다 번거롭다** |
| GitLab 토큰 | 토큰을 만들려면 `api` 범위의 **더 강한 토큰**이 필요하다. 읽기 전용 토큰 하나를 위해 그걸 들고 다니는 건 손해 |

> **데드맨 핑 URL 은 운영 값을 쓰지 말 것.** 시험 구역 Watchdog 이 운영 체크를 계속 살려둬서, **운영 경보 경로가 끊겨도 데드맨이 울리지 않는다.** Healthchecks 는 API 키를 주고 스크립트가 새로 만들게 하는 쪽이 안전하다.

---

## 안전장치

| | |
|---|---|
| **운영 계정 차단** | `379937169195` 이 감지되면 아무것도 하지 않고 중단한다 |
| **기본이 dry-run** | `--apply` 를 주기 전에는 계획만 출력한다 |
| **덮어쓰지 않음** | 이미 있는 역할·시크릿은 건너뛴다. 기존 클러스터가 쓰는 값을 바꾸지 않는다 |
| **값을 찍지 않음** | 비밀값은 화면·로그에 나오지 않는다. 임시 파일은 700 디렉터리에 두고 종료 시 지운다 |
| 확인 질문 | `--apply` 는 계정 번호를 보여주고 `yes` 를 받는다(`--yes` 로 생략) |

---

## IAM 역할 3개가 필요한 이유

`2-cluster` 가 **레포가 소유하지 않는 역할**을 네 군데서 참조한다. 운영 계정에는 다른 경로로 이미 있어서 드러나지 않지만, 시험 계정에는 없어 apply 가 `NoSuchEntity` 로 멈춘다.

| 참조하는 곳 | 가리키는 역할 | 운영에서는 누가 만드나 |
|---|---|---|
| `main.tf:127` readonly Access Entry | **`aquasentinel-gitlab-terraform-plan`** | `global/cicd` (묶음에 없는 컴포넌트) |
| `main.tf:135` group Access Entry | `aquasentinel-gitlab-alert-maintenance` | 〃 |
| `cross-account-members.tf:79` | `aquasentinel-member-changyoung` | 콘솔 수동 생성(레포 소유 아님) |
| `cross-account-members.tf:122` | 〃 | 〃 |

셋 다 **권한 정책 없이 껍데기만** 만든다. 클러스터 권한은 Access Entry 와 RBAC 그룹이 정하고, 나머지 정책은 Terraform 이 붙인다.

> **2026-10-19 정정** — 처음에는 `gitlab-terraform-plan` 을 빠뜨려 2개로 적었다. 시험 구역 1 실측에서 드러나 추가했다.
>
> **`--description` 은 ASCII 로만 적는다.** 한글·em대시를 넣으면 `create-role` 이 거부되는 경우가 있다(같은 날 확인). 그리고 생성 실패 시 **AWS 원문 오류를 그대로 출력**하도록 고쳤다 — 전에는 `2>&1` 로 묻어서 원인을 알 수 없었다.

> 대안으로 `cross-account-members.tf` 를 변수로 끄는 방법이 있다. 그 파일은 **운영 클러스터에 팀원이 kubectl 로 붙기 위한 것**이라 시험 계정에선 쓸모가 없다. 그 변수가 들어오면 이 스크립트의 역할 목록에서 `member-changyoung` 을 빼면 된다.

---

## `2-cluster.tfvars` 의 `team_members` 는 빈 목록으로

```hcl
team_members = []
```

기동 묶음 값(`jaehee` …)을 그대로 쓰면 두 가지로 실패한다(2026-10-19 시험 구역 1 실측).

| 증상 | 원인 |
|---|---|
| plan 이 `Duplicate object key` | `cross-account-members.tf` 가 만드는 역할 이름과 겹친다. `main.tf:118` 이 둘을 합치고 모듈이 `name` 으로 키를 만든다 |
| Access Entry 409 | 시험 계정에서 apply 하는 사용자가 **이미 클러스터 생성자**라 관리자 권한을 자동으로 갖는다 |

겹침은 `2-cluster/main.tf` 쪽에서도 걸러 두었지만, **409 는 코드가 못 막으니** 빈 목록이 맞다.

---

## 자주 걸리는 것

| 증상 | 원인 · 대응 |
|---|---|
| `삭제 대기 중(restore-secret 필요)` | 전에 지운 시크릿이 복구 대기 기간(7~30일)에 있다. 같은 이름으로 못 만든다 → `aws secretsmanager restore-secret --secret-id <이름> --region ap-northeast-2` |
| `3-gitops` plan 이 시크릿을 못 읽음 | `argocd-gitops-token` 누락. `--verify` 로 확인 |
| Karpenter 가 스팟을 안 띄움 | Spot 서비스 연결 역할 누락 |
| 두 번째 시험 구역을 준비 | 같은 스크립트를 그 계정 자격증명으로 다시 돌린다. **Healthchecks 체크와 Discord 웹훅은 구역마다 다른 값**을 쓸 것(경보 본문에 클러스터 구분이 없다) |

---

## 이 스크립트가 하지 않는 것

Terraform apply 전 준비 중에서도 **AWS CLI 로 할 수 없는 것**은 빠져 있다.

- Route53 Hosted Zone 생성과 **상위 도메인 NS 위임** — 위임은 등록처에서 해야 한다
- gitops `test-field` 브랜치 재생성 — 재희님 지시 후
- 운영 계정 쪽 권한(ECR pull 허용 · 버킷 읽기) — **인프라(원주) 요청**
- 묶음의 `<TEST_ACCOUNT_ID>` 치환 — 문서 2장
