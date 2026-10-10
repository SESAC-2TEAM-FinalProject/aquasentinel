# Terraform 구조

경로 구조 개편(2026-10-10, D1~D6 확정)에 따라 컴포넌트를 **수명주기** 기준으로
나눈다 — "언제 지워지는가"가 디렉토리 경계다.

```
terraform/
├── modules/                   공용 모듈 (8개)
├── global/                    계정 전체, 리전 무관, 절대 재구축 안 함
│   ├── bootstrap/             tfstate 저장용 S3 버킷 자체 (로컬 state — 아래 참고)
│   └── cicd/                  GitLab.com → AWS OIDC 연동 (Terraform 레포 CI가 쓰는 Role)
├── seoul/
│   ├── persistent/            재구축해도 안 지워짐: S3 버킷(raw-store/observability/loki), ECR, ACM 인증서
│   └── rebuild/
│       ├── 1-network/         VPC/서브넷
│       ├── 2-cluster/         EKS + Access Entry + Redis + 전체 워크로드 IRSA
│       ├── 3-gitops/          Argo CD 부트스트랩 + Terraform 소유 Application들
│       └── 4-edge/            Route53 Failover 레코드
└── tokyo/                     서울과 동일 구조 (persistent + rebuild/1~4)
    ├── persistent/            D4(2026-10-10) — 클러스터 유무와 무관하게 상시 운영
    └── rebuild/                도쿄 DR 클러스터. 평소엔 안 띄워도 됨(destroy 가능)
```

구 `environments/aws-seoul-dev/*`는 마이그레이션 완료 후 삭제 예정(Phase G,
아직 미완료) — 현재는 registry/observability-storage/api-raw-store 세
컴포넌트만 실제 리소스를 갖고 있었고, 전부 `seoul/persistent`로 이관되어
빈 상태(`data.aws_caller_identity`만 남은 깡통 state)다.

## 모듈(8개)

| 모듈 | 용도 |
| ---- | ---- |
| `aws-network` | VPC/서브넷/NAT |
| `aws-eks` | EKS 클러스터 + 노드그룹 + OIDC Provider + Access Entry |
| `aws-data` | ElastiCache Redis |
| `aws-dns` | Route53 레코드 + ACM 인증서(`create_certificate`로 분리 가능) |
| `aws-storage` | S3 버킷(수명주기/복제) — IRSA는 포함하지 않음 |
| `aws-irsa` | 워크로드 IRSA Role (community submodule 래퍼, D5) |
| `aws-registry` | ECR 레포 + 크로스리전 복제 |
| `aws-cicd` | GitLab.com 직접 OIDC → AWS Role (Terraform 레포 CI 전용) |

`modules/aws-eso`는 구 `environments/aws-seoul-dev/gitops`만 참조하는
레거시 모듈이다 — 새 구조(`{seoul,tokyo}/rebuild/2-cluster`의 `aws-irsa`
호출)는 쓰지 않는다. 구 `environments/` 삭제(Phase G) 때 같이 지운다.

각 모듈 `README.md`는 `terraform-docs`로 생성 — 인터페이스가 바뀌면 다시
생성할 것:
```
terraform-docs markdown table --output-file README.md --output-mode inject terraform/modules/<모듈명>
```

## 적용 순서

처음부터 전체를 세우는 경우 **반드시 이 순서**를 지킨다 — 뒤 단계가 앞
단계의 `terraform_remote_state`를 읽기 때문에, 역순으로 적용하면 "no state
file" 에러로 바로 드러난다.

```
1. global/bootstrap          (최초 1회, 수동) — tfstate 버킷 자체를 만듦
2. global/cicd                (최초 1회, 수동) — 이 저장소 CI가 쓸 IAM Role
3. tokyo/persistent            ← seoul/persistent가 이 state의 버킷 ARN을
                                 복제 대상으로 참조하므로 반드시 서울보다 먼저
4. seoul/persistent
5. seoul/rebuild/1-network → 2-cluster → 3-gitops → 4-edge
6. tokyo/rebuild/1-network → 2-cluster → 3-gitops → 4-edge   (DR, 평소엔 생략 가능)
```

`bootstrap`은 이 모든 state를 저장할 S3 버킷 자체를 만들기 때문에
S3 백엔드를 쓸 수 없다 — 로컬 state(`terraform/global/bootstrap/terraform.tfstate`)로
관리하고, 적용 후 `tfstate_bucket_name` output을 나머지 모든 컴포넌트의
`backend.hcl`/`terraform.tfvars`에 수동으로 채워 넣는다. 이 로컬 state 파일은
유실되면 복구가 어려우므로 별도로 백업해둘 것(git에는 올리지 않음).

## 파괴(destroy) 순서

재구축 드릴이나 비용 절감을 위해 `rebuild/*`를 내릴 때는 적용 순서의
정확히 역순으로 destroy한다 — `persistent`와 `global/bootstrap`은 대상에서
제외(D1/D3, 버킷 리소스에 `prevent_destroy = true`가 하드코딩돼 있어 실수로
포함시켜도 Terraform이 막는다). `global/cicd`는 하드코딩된 보호는 없지만
이 저장소 CI 인증 자체가 끊기므로 마찬가지로 destroy 대상이 아니다.

```
seoul/rebuild/4-edge → 3-gitops → 2-cluster → 1-network
tokyo/rebuild/4-edge → 3-gitops → 2-cluster → 1-network   (평소 운영 시 도쿄는 이 상태)
```

## 컴포넌트 공통 규칙

- 모든 컴포넌트는 `backend.hcl.example`/`terraform.tfvars.example`을
  `backend.hcl`/`terraform.tfvars`로 복사해 값을 채운 뒤 사용한다(둘 다
  git에 커밋하지 않음 — `terraform/.gitignore` 참고).
- `terraform init -backend-config=backend.hcl`로 초기화한다.
- CI(`.gitlab-ci.yml`)는 GitLab.com 공유 러너에서 돈다 — EKS 자체 러너가
  아니다(Terraform이 그 클러스터를 destroy/수정할 수 있어, 러너가 클러스터
  안에 있으면 순환 의존이 생기기 때문).
