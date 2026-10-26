# 카펜터 NodePool/EC2NodeClass — 가용성/DR 재구축 개선안(2026-10-13) 2단계,
# applications.tf의 karpenter_app(컨트롤러 Helm) 다음 순서. IAM/SQS/디스커버리
# 태그는 2-cluster/karpenter.tf, 컨트롤러 설치는 applications.tf 참고.
#
# NodePool/EC2NodeClass는 Helm 차트가 아니라 카펜터 자신이 등록하는 CRD라,
# 컨트롤러가 CRD를 실제로 설치할 때까지 기다려야 한다 — LBC+Gateway API CRD
# 경쟁 조건(applications.tf restart_lbc_for_gateway_api 주석 참고)과 같은
# 계열의 문제라 같은 폴링 패턴(wait_for_api_module_namespace)을 재사용한다.

resource "null_resource" "wait_for_karpenter_crds" {
  # kube_prometheus_stack_app 에도 의존해야 한다 — karpenter_app 의 두 번째 소스
  # (gitops manifests/karpenter)에 ServiceMonitor 가 들어 있고(2026-10-16 관측
  # 보강분), 그 CRD(monitoring.coreos.com/v1)는 kube-prometheus-stack 이 설치한다.
  # 새 클러스터엔 아직 없으니 Argo CD 가 karpenter 앱을 **통째로**
  # `failed to discover server resources for group version monitoring.coreos.com/v1`
  # (ComparisonError)로 거부하고, 그러면 OCI 차트 쪽 Karpenter CRD 도 같이 안 생겨
  # 아래 폴링이 반드시 타임아웃한다. 특히 CI 2단계처럼 -target 으로 좁히면
  # kube_prometheus_stack_app 이 그래프에 아예 없어 CRD 가 영원히 안 생긴다 —
  # 확정적 실패다(2026-10-19 시험 구역 1 실측, SIM-08a 발견 항목). 기존 클러스터는
  # 두 CRD 가 이미 있어 no-op.
  depends_on = [
    kubernetes_manifest.karpenter_app,
    kubernetes_manifest.kube_prometheus_stack_app,
  ]

  # (2026-10-14) wait_for_api_module_namespace에서 발견된 것과 같은 마스킹 버그를
  # 피하기 위해, 마지막 조회 결과를 STATUS로 받아 타임아웃 시 exit 1 하도록 작성한다
  # — rm -f가 마지막 줄이면 polling이 전부 실패해도 항상 exit 0으로 끝난다.
  provisioner "local-exec" {
    # 스크립트가 bash 문법(mktemp·$(…)·seq)이라 셸을 고정한다. 지정하지 않으면
    # Windows 빌더에서 cmd.exe 로 실행돼 깨진다(2026-10-19 시험 구역 1 확인).
    # 리눅스 CI 는 원래 bash 라 동작이 바뀌지 않는다.
    interpreter = ["bash", "-c"]

    # 기다리는 단계를 둘로 나눈 이유는 타임아웃 메시지가 "무엇을 기다리다 죽었나"를
    # 가리키게 하려는 것이다 — 시험 구역 1에서는 같은 `karpenter CRDs not found`
    # 한 줄이 서로 다른 원인(레포 자격증명 레이스 / Prometheus CRD 부재) 두 개를
    # 가려서, 원인 찾기를 두 번 반복해야 했다.
    command = <<-EOT
      CA_FILE=$(mktemp)
      echo "${data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data}" | base64 -d > "$CA_FILE"
      KUBECTL="kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority=$CA_FILE --token=${data.aws_eks_cluster_auth.this.token}"

      # 1단계 — Prometheus Operator CRD. 이게 없으면 karpenter 앱이 동기화 자체를
      # 거부당해 2단계로 넘어갈 수가 없다(위 depends_on 주석 참고).
      for i in $(seq 1 60); do
        $KUBECTL get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1 && break
        sleep 5
      done
      if ! $KUBECTL get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
        rm -f "$CA_FILE"
        echo "TIMEOUT: ServiceMonitor CRD (kube-prometheus-stack) not found after 5m" >&2
        exit 1
      fi

      # CRD 가 늦게 생기면 karpenter 앱은 이미 ComparisonError 로 백오프에 들어가
      # 있다. Argo CD 의 다음 조정 주기(기본 3분)를 그대로 기다리지 않도록 하드
      # 리프레시를 걸어 즉시 다시 비교하게 한다. 이미 Synced 면 아무 일도 하지 않고,
      # 실패해도 2단계 폴링이 어차피 기다리므로 판정에 영향을 주지 않는다.
      $KUBECTL -n argocd annotate applications.argoproj.io karpenter argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

      # 2단계 — Karpenter 자신이 등록하는 CRD
      for i in $(seq 1 60); do
        $KUBECTL get crd nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1 && break
        sleep 5
      done
      $KUBECTL get crd nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws
      STATUS=$?
      rm -f "$CA_FILE"
      if [ "$STATUS" -ne 0 ]; then
        echo "TIMEOUT: karpenter CRDs not found after 5m" >&2
        exit 1
      fi
    EOT
  }
}

# ---------------------------------------------------------------------------
# EC2NodeClass — "role"로 지정(= 카펜터가 자기 인스턴스 프로필을 직접
# 만들고 관리)한다. 2-cluster/karpenter.tf의 IAMIntegrationPolicy가
# iam:CreateInstanceProfile 등을 ec2nodeclass 태그 조건으로 부여해둔 게
# 바로 이 방식을 전제로 한 것이다("instanceProfile" 고정값 방식이었다면
# 이 권한 자체가 필요 없다). 노드 역할(aws_iam_role.node)은 기존 관리형
# 노드그룹과 동일한 걸 재사용 — 같은 워크로드를 수용하므로 권한 분리 불필요
# (2-cluster/karpenter.tf 상단 주석 참고).
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "karpenter_ec2nodeclass_default" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      amiFamily = "AL2023"
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]

      role = data.terraform_remote_state.cluster.outputs.karpenter_node_role_name

      # 디스커버리 태그는 2-cluster/karpenter.tf가 3 AZ(2a/2b/2c) 서브넷 전체와
      # 클러스터 보안그룹에 이미 붙여뒀다 — 여기서 AZ를 직접 나열하지 않는 이유는
      # 네트워크 쪽에 AZ가 추가/변경돼도 이 파일을 다시 고칠 필요가 없게 하기 위함.
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = data.terraform_remote_state.cluster.outputs.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = data.terraform_remote_state.cluster.outputs.cluster_name } }
      ]

      # 기존 관리형 노드그룹 루트 볼륨(20GiB)이 10/13 디스크 압박 사고의
      # 배경 중 하나였다(근본 원인은 아니지만 여유분 부족) — 팀결정요청
      # 문서에 적은 대로 노드그룹 desired=3 경로가 없어졌으므로 그 증설 건을
      # 여기로 흡수한다(개선안 2.2절).
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]

      # 기존 관리형 노드그룹은 AL2023 bootstrap.sh 부재 문제 때문에 커스텀
      # launch template + nodeadm NodeConfig로 max-pods를 병합했다
      # (modules/aws-eks/main.tf 주석 참고). EC2NodeClass는 kubelet.maxPods
      # 필드로 같은 값을 직접 지정할 수 있어 그 우회가 필요 없다.
      kubelet = {
        maxPods = data.terraform_remote_state.cluster.outputs.max_pods_per_node
      }

      tags = {
        project     = var.project_name
        owner       = var.owner
        environment = var.environment
        managed_by  = "terraform"
        component   = "3-gitops-karpenter"
      }
    }
  }

  depends_on = [null_resource.wait_for_karpenter_crds]
}

# ---------------------------------------------------------------------------
# NodePool "general" — 부하 증설 전용. 평소 0대다(SIM-14 결론 — 상시 파드는
# 관리형 노드그룹 온디맨드 3대, 카펜터는 넘칠 때만. 2026-10-23 운영 확인).
# 인스턴스 유형은 2vCPU/8GiB 급 5종(2026-10-15, 서비스 배치 최종 제안 1장 ②·
# 6장 ③ — 한 유형이 통째로 회수돼도 나머지가 살아남는다).
#
# SIM-14 단계 ⑤(카펜터 수정 방안 3.1, 2026-10-26):
#   - 용량 유형 스팟 + 온디맨드 — 스팟을 못 받으면 증설이 Pending 으로 멈춘다.
#     카펜터는 스팟을 먼저 고르고, 없을 때만 온디맨드로 띄운다.
#   - 수명 24h — 부하 노드가 하루를 넘기면 이상 신호다. 카펜터 v1 의 수명 만료는
#     disruption 예산을 따지지 않으므로 이보다 짧게 잡지 않는다.
#   - weight 는 넣지 않는다. 예비 풀(stateful-spare)을 부하가 먹지 못하게 막는
#     것은 워크로드 쪽 `aquasentinel.io/spare DoesNotExist` 필수 조건이다.
#   - limits 는 그대로 둔다 — 온디맨드까지 열린 뒤의 상한은 LT-02(부하 시험)
#     실측 뒤 다시 산정한다.
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "karpenter_nodepool_general" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "general"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "aquasentinel.io/nodepool" = "general"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "24h"
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = data.terraform_remote_state.cluster.outputs.general_pool_instance_types
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"]
            },
          ]
        }
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
      # 서비스 배치 최종 제안(2026-10-15) 6장 ③ — 상한 없으면 설정 실수·폭주 시
      # 무제한 증식. 현재 예약량(5장)의 몇 배 여유를 둔 값.
      limits = {
        cpu    = "32"
        memory = "128Gi"
      }
    }
  }

  depends_on = [kubernetes_manifest.karpenter_ec2nodeclass_default]
}

# ---------------------------------------------------------------------------
# NodePool "stateful-spare" — 온디맨드 1대가 빠졌을 때만 뜨는 예비 자리.
# SIM-14b-R1 검증 · SIM-14 결정 ①(카펜터 수정 방안 3.2) · 2026-10-23 반영.
#
# 왜 필요한가 — 관리형 노드그룹에 노드 자동 복구(nodeRepairConfig) 설정이 없고
# ASG 헬스체크가 `EC2`만이라, 인스턴스가 **살아 있는 채 NotReady** 가 되는 이탈
# (cordon · drain · kubelet NotReady)은 ASG 가 교체해 주지 않는다. 예비 풀이
# 없던 13d-R1 에서 고정 파드가 20분 Pending 이었다. 14b-R1 에서 이 풀을 넣고
# 같은 이탈을 재니 대체 290초였고(DB 파드 종료 대기 180초가 하한을 정한다),
# 카펜터가 볼륨이 묶인 AZ 를 따라 노드를 띄우는 것도 확인했다.
#
# 라벨 · taint 를 관리형 노드그룹과 같게 둔다 — CNPG·NATS(nodeSelector
# aquasentinel.io/nodepool=stateful)가 수정 없이 그대로 들어온다. 카펜터 컨트롤러는
# nodeAffinity karpenter.sh/nodepool DoesNotExist 라 예비 노드에는 안 뜬다.
#
# 🔴 aquasentinel.io/spare="true" 라벨이 이 풀만의 표식이다 — 상시 워크로드
# (api-module · 플랫폼 · CronJob)에 nodeAffinity required `spare DoesNotExist` 를
# 넣어 **부하가 이 자리를 먹지 못하게** 막는다(재희님 2026-10-22 결정 — 확정본
# 초안의 「선호 키 교체 + general weight: 50」 안을 이것으로 대체했다. weight 는
# 순서에 의존하고 general 이 상한에 걸리면 부하가 예비 1대를 먹을 수 있었다).
#
# 평소 0대다. 비면 1분 뒤 회수(WhenEmpty).
# 🔴 수명은 720h(기본과 같게 명시) — 짧게 잡으면 수명 만료로 고정 파드가 다시
# 옮겨 다닌다. **복귀는 런북으로** 한다: 원래(또는 ASG 가 바꾼) 노드 Ready 확인 →
# 예비 노드 cordon → drain(PDB 존중 · CNPG 가 primary 면 switchover 먼저) →
# 비면 1분 뒤 회수. WhenEmpty 라 원래 노드가 돌아와도 파드가 스스로 돌아오지 않는다.
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "karpenter_nodepool_stateful_spare" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "stateful-spare"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "aquasentinel.io/nodepool" = "stateful"
            "aquasentinel.io/spare"    = "true"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          # 관리형 노드그룹과 같은 taint — 일반 워크로드가 섞여 앉지 못한다.
          taints = [
            {
              key    = "dedicated"
              value  = "stateful"
              effect = "NoSchedule"
            },
          ]
          expireAfter = "720h"
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              # 노드그룹과 같은 유형을 쓴다(2-cluster node_instance_types = t3.large).
              # 고정 파드가 원래 노드와 같은 크기 자리로 가야 requests 가 들어간다.
              values = data.terraform_remote_state.cluster.outputs.node_instance_types
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
          ]
        }
      }
      disruption = {
        # general 과 달리 WhenEmpty — 비었을 때만 회수한다. Underutilized 까지
        # 보면 고정 파드가 반쯤 찬 예비 노드를 카펜터가 다시 옮기려 든다.
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "1m"
        budgets = [
          { nodes = "100%" },
        ]
      }
      # 1대만 — t3.large 2 vCPU 기준. node_instance_types 를 더 큰 유형으로 바꾸면
      # 이 값도 같이 봐야 한다.
      limits = {
        cpu = "2"
      }
    }
  }

  depends_on = [kubernetes_manifest.karpenter_ec2nodeclass_default]
}

# NodePool "stateful"은 스테이트풀 복귀 작업(2026-10-14)으로 제거했다 — CNPG·NATS가
# 더 이상 카펜터가 아니라 관리형 노드그룹 전용 고정 3대(온디맨드, 2-cluster/main.tf의
# node_labels/node_taints)에서 돈다. 보호장치 3종 중 이 리소스가 담당하던 ②③
# (consolidation 정책/disruption budget)은 애초에 카펜터가 관리하는 노드에서만
# 의미가 있던 설정이라 고정 노드그룹엔 적용 대상 자체가 없다.
