# 알람 점검 모드 — `maintenance.sh`

teardown·점검처럼 **계획된 작업** 동안 알림이 나가지 않게 한다. 한 번의 명령으로 Alertmanager에 Silence를 걸고 데드맨스위치(Healthchecks.io 체크)를 일시정지한다. 로컬과 CI 수동 잡이 같은 스크립트를 쓴다.

- 재구축 **직후** 억제는 이 스크립트가 아니라 억제 규칙 `ClusterBootstrapping`(gitops `manifests/alerting/routing/rules-platform.yaml`)이 맡는다. 새로 뜬 Alertmanager에는 Silence가 없기 때문이다.
- ArgoCD Notifications(`#argocd`)와 트랙 B(CloudWatch → SNS 메일)는 Alertmanager를 거치지 않으므로 Silence 대상이 아니다.

## 왜 이 순서인가

1. **Silence를 먼저 건다 — Watchdog까지 포함해서.** 데드맨은 Alertmanager가 Watchdog 알림을 1분마다 Healthchecks.io로 보내는 핑이다.
2. **Watchdog이 Silence된 것을 확인한다.** 핑이 멈췄다는 뜻이다.
3. **그다음 체크를 일시정지한다.** Healthchecks.io는 일시정지된 체크가 핑을 받으면 바로 다시 감시한다. 핑이 멈추기 전에 일시정지하면 다음 핑에 풀린다.

해제는 자동으로 복구된다. Silence가 끝나면(만료·`stop`·재구축) 핑이 다시 가고 체크가 재개된다. `stop`을 잊어도 Silence 만료 시각에 감시가 돌아온다. Alertmanager는 Silence를 PVC에 보관하므로 파드 재시작·재배치로는 풀리지 않는다 — 재구축은 새 PVC로 시작해 Silence가 없다.

## 준비

| 항목 | 값 |
|---|---|
| Healthchecks.io 체크 설정 | "Ignore pings while paused"는 **끈 채로**(기본값). 켜져 있으면 재구축 뒤 자동 재개가 안 된다 |
| `HC_API_KEY` | Healthchecks.io **읽기·쓰기** API 키(프로젝트 설정 → API Access). 읽기 전용 키로는 일시정지할 수 없다 |
| `HC_CHECK_UUID` | 데드맨 체크 UUID(서울·도쿄가 다르다) |
| 클러스터 권한 | 로컬: 관리자 Access Entry에 등록된 사람. CI: 그룹 `aquasentinel:alert-maintenance`(아래 "권한") |
| 도구 | `bash`, `kubectl`, `curl` |

키와 UUID는 git·채팅·로그에 남기지 않는다. 스크립트도 출력하지 않는다.

선택 환경변수: `KUBE_CONTEXT`(비우면 현재 컨텍스트), `AM_NAMESPACE`(기본 `monitoring`), `AM_POD`(기본 `alertmanager-kube-prometheus-stack-alertmanager-0`).

## 사용법

```bash
export HC_API_KEY=… HC_CHECK_UUID=…
scripts/alerting/maintenance.sh start "<사유>" [기간]   # 기간 기본 2h, 형식 30m·3h, 최대 12h
scripts/alerting/maintenance.sh status
scripts/alerting/maintenance.sh stop
```

`start`는 Watchdog 확인과 일시정지 확인 때문에 2~3분 걸린다. 끝에 Silence ID, 만료 시각, 체크 상태를 출력한다.

| 종료 코드 | 의미 | 할 일 |
|---|---|---|
| 0 | 성공 | — |
| 1 | 사용법·환경변수 오류 — 아무것도 하지 않았다 | 인자·환경변수 확인 |
| 2 | Alertmanager 단계 실패(exec·Silence) — 일시정지는 하지 않았다 | 클러스터 권한·파드 이름 확인 |
| 3 | Healthchecks.io 단계 실패 — Silence는 걸려 있다 | 키·UUID 확인. 그대로 두면 데드맨이 5분 유예 뒤 울린다 |
| 4 | Watchdog이 시간 안에 Silence되지 않음 — 일시정지는 하지 않았다 | `amtool alert query alertname=Watchdog`으로 Watchdog 발화 확인 |

어떤 단계가 실패해도 "알림이 울리는 쪽"으로 끝난다. Silence 없이 일시정지만 걸린 상태는 만들지 않는다.

## 런북에 넣을 단계

### teardown (`rebuild/4-edge → 3-gitops → 2-cluster → 1-network`)

```
0. maintenance.sh start "teardown <날짜>" <기간>   ← 맨 먼저. 기존 수동 단계(ArgoCD 자동 동기화 끄기 등)보다도 먼저
   maintenance.sh status                            ← Silence 1건, 체크 paused 확인
   (기존 수동 단계)
1~4. destroy (기존 순서)
```

- **기간은 teardown 전체를 덮는다** — `2-cluster` destroy가 끝날 때까지. 그 전에 만료되면 Alertmanager가 살아 있는 채로 핑이 재개돼 체크가 풀리고, 곧이어 Alertmanager가 사라지며 데드맨이 울린다. 직전 teardown 소요 시간에 여유를 더해 잡는다.
- Alertmanager는 destroy 도중 사라진다. 그 뒤 Silence는 의미가 없고 체크는 paused로 남는다(재구축 때 자동 재개).

### 재구축 (`1-network → … → 4-edge`)

```
1~4. apply (기존 순서)
5. 재구축 직후 60분은 ClusterBootstrapping 이 Watchdog 을 뺀 알림을 억제한다
6. 새 Alertmanager 의 첫 Watchdog 핑으로 체크가 자동 재개된다
   maintenance.sh status → 체크 up 확인
   3-gitops apply 후 15분이 지나도 paused 면 maintenance.sh stop
```

### 점검 (클러스터를 유지한 채 하는 작업)

`start` → 작업 → `stop` → `status`로 체크 up 확인. 기간은 작업 예상 시간보다 약간 길게만 잡는다.

## 권한 (CI 잡)

CI 잡과 아래 권한은 러너 이전 담당과 합의한 뒤 따로 반영한다. 반영 전에는 로컬 실행만 쓴다.

| 층 | 위치 |
|---|---|
| IAM 역할 `aquasentinel-gitlab-alert-maintenance`(GitLab OIDC, main만, `eks:DescribeCluster`만) | `terraform/modules/aws-cicd`, `terraform/global/cicd` |
| EKS Access Entry → 그룹 `aquasentinel:alert-maintenance`(정책 없음) | `terraform/modules/aws-eks`, `terraform/*/rebuild/2-cluster` |
| RBAC — Alertmanager 파드 하나의 조회·exec만 | gitops `manifests/alerting/routing/rbac-maintenance.yaml` |

**바뀌면 함께 고칠 곳**: Alertmanager 파드 이름은 이 스크립트의 `AM_POD` 기본값과 RBAC의 `resourceNames` 두 곳에 있다. 그룹 이름은 `2-cluster`(서울·도쿄)와 RBAC의 RoleBinding에 있다.
