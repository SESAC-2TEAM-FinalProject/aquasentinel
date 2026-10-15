# 카펜터 NodePool/EC2NodeClass — 가용성/DR 재구축 개선안(2026-10-13) 2단계,
# applications.tf의 karpenter_app(컨트롤러 Helm) 다음 순서. IAM/SQS/디스커버리
# 태그는 2-cluster/karpenter.tf, 컨트롤러 설치는 applications.tf 참고.
#
# NodePool/EC2NodeClass는 Helm 차트가 아니라 카펜터 자신이 등록하는 CRD라,
# 컨트롤러가 CRD를 실제로 설치할 때까지 기다려야 한다 — LBC+Gateway API CRD
# 경쟁 조건(applications.tf restart_lbc_for_gateway_api 주석 참고)과 같은
# 계열의 문제라 같은 폴링 패턴(wait_for_api_module_namespace)을 재사용한다.

resource "null_resource" "wait_for_karpenter_crds" {
  depends_on = [kubernetes_manifest.karpenter_app]

  # (2026-10-14) wait_for_api_module_namespace에서 발견된 것과 같은 마스킹 버그를
  # 피하기 위해, 마지막 조회 결과를 STATUS로 받아 타임아웃 시 exit 1 하도록 작성한다
  # — rm -f가 마지막 줄이면 polling이 전부 실패해도 항상 exit 0으로 끝난다.
  provisioner "local-exec" {
    command = <<-EOT
      CA_FILE=$(mktemp)
      echo "${data.terraform_remote_state.cluster.outputs.cluster_certificate_authority_data}" | base64 -d > "$CA_FILE"
      for i in $(seq 1 60); do
        kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} get crd nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws >/dev/null 2>&1 && break
        sleep 5
      done
      kubectl --server=${data.terraform_remote_state.cluster.outputs.cluster_endpoint} --certificate-authority="$CA_FILE" --token=${data.aws_eks_cluster_auth.this.token} get crd nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws
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
# NodePool "general" — 앱·수집기 등 무상태 워크로드. 전부 스팟(비용 프로필
# 유지, t3.large 한 유형 → 2vCPU/8GiB 급 5종으로 다변화. 2026-10-15, 서비스
# 배치 최종 제안 1장 ②·6장 ③ — 한 유형이 통째로 회수돼도 나머지가 살아남는다).
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
          requirements = [
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = data.terraform_remote_state.cluster.outputs.general_pool_instance_types
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot"]
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

# NodePool "stateful"은 스테이트풀 복귀 작업(2026-10-14)으로 제거했다 — CNPG·NATS가
# 더 이상 카펜터가 아니라 관리형 노드그룹 전용 고정 3대(온디맨드, 2-cluster/main.tf의
# node_labels/node_taints)에서 돈다. 보호장치 3종 중 이 리소스가 담당하던 ②③
# (consolidation 정책/disruption budget)은 애초에 카펜터가 관리하는 노드에서만
# 의미가 있던 설정이라 고정 노드그룹엔 적용 대상 자체가 없다.
