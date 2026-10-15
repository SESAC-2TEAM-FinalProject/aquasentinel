# GitLab Runner를 EKS 클러스터 밖(전용 EC2)으로 이전 — 7단계(2026-10-14).
# 배경: AquaSentinel_GitLab러너_클러스터밖_이전_배경과계획_팀공유용 참고.
#
# 의도적으로 seoul/rebuild/2-cluster의 state를 읽지 않는다 — 이 컴포넌트의
# 핵심 목적 자체가 "CI가 클러스터 생명주기와 독립적이어야 한다"는 것이라,
# 여기서 클러스터 state를 참조하면 지금 없애려는 결합을 그대로 재현하게
# 된다. ECR 정책도 seoul/rebuild/2-cluster/irsa.tf의 gitlab_runner_ecr과
# 내용은 같지만 독립적으로 새로 작성한다.
#
# [2026-10-15 정정] 아래 전제가 반만 맞았다 — "이 러너는 kubectl/helm을
# 쓰지 않는다"는 web·api-module 등 앱 레포 CI 잡 기준의 실측이었는데,
# 정작 이 AWS 레포 자신의 3-gitops 컴포넌트는 kubernetes·helm Terraform
# 프로바이더로 EKS API 서버에 직접 TCP 연결한다(3-gitops/main.tf 참고).
# 이전 직후엔 3-gitops plan을 이 러너로 돌려본 적이 없어 늦게 발견했다
# (plan:seoul [rebuild/3-gitops]가 "dial tcp ...:443: i/o timeout"으로
# 실패 — 클러스터 SG가 러너 SG의 inbound를 허용하지 않아서였다).
# 그래서 위 "state를 읽지 않는다" 원칙에 scoped 예외를 둔다 — 클러스터
# SG ID 하나만 읽어 인그레스 규칙 1개를 추가한다(아래 "EKS API 접근"
# 섹션). 그 외 EKS Access Entry 등은 여전히 불필요하다는 판단 그대로다.
#
# 최초 apply는 아직 이 EC2(미래의 새 러너)가 존재하지 않는 시점이라 기존
# 클러스터 내부 러너 또는 로컬에서 실행해야 한다 — global/bootstrap·
# global/cicd와 같은 종류의 "닭과 달걀" 예외이지만, 이후부터는 일반
# 컴포넌트와 동일하게 CI validate/plan 자동화 대상에 포함한다(.gitlab-ci.yml
# 참고 — apply만 계속 수동).
#
# 그래서 backend.hcl도 global/bootstrap·cicd(로컬 전용)가 아니라 seoul·tokyo
# 컴포넌트와 같은 쪽 관례를 따라 git에 올린다 — CI가 읽지 못하면
# terraform init 자체가 실패한다(2026-10-14 첫 파이프라인에서 실제 발생).

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = var.project_name
      owner       = var.owner
      environment = var.environment
      managed_by  = "terraform"
      component   = "runner"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/rebuild/1-network/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

# [2026-10-15 추가] 위 헤더 주석의 scoped 예외 — 클러스터 SG ID를 읽는
# 용도로만 쓴다. 2-cluster의 다른 출력(인스턴스 타입 등)은 참조하지 않는다.
data "terraform_remote_state" "cluster" {
  backend = "s3"

  config = {
    bucket = var.tfstate_bucket
    key    = "seoul/rebuild/2-cluster/terraform.tfstate"
    region = var.tfstate_bucket_region
  }
}

# AL2023 최신 AMI — 하드코딩 대신 SSM Parameter Store 별칭을 참조해 apply할
# 때마다 최신 패치 버전을 자동으로 따라간다(기존 관리형 노드그룹 AMI와 같은
# 계열이라 팀 친숙도 유지).
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# IAM — 인스턴스 프로필. ECR push/pull + 러너 등록 토큰 1개만 읽는 권한.
# EKS 접근 권한은 의도적으로 부여하지 않는다(위 주석 참고).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${local.name_prefix}-gitlab-runner-ec2"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = { project = var.project_name, owner = var.owner }
}

# SSM Session Manager로 접속하기 위한 AWS 관리형 정책 — SSH 키 불필요.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "runner_ecr" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPullScoped"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.region}:*:repository/${local.name_prefix}/*"]
  }
}

resource "aws_iam_policy" "runner_ecr" {
  name   = "${local.name_prefix}-gitlab-runner-ec2-ecr"
  policy = data.aws_iam_policy_document.runner_ecr.json
}

resource "aws_iam_role_policy_attachment" "runner_ecr" {
  role       = aws_iam_role.runner.name
  policy_arn = aws_iam_policy.runner_ecr.arn
}

# 러너 등록 토큰 — GitLab UI에서 미리 발급해 AWS CLI로 이 이름 그대로 AWS
# Secrets Manager에 직접 넣어둔다(다른 모든 시크릿과 동일하게 Terraform이
# 아니라 수동 생성 — 평문을 git/user-data에 남기지 않기 위함). 읽기 권한만
# 이 시크릿 하나로 좁힌다.
data "aws_iam_policy_document" "runner_token_read" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${local.name_prefix}-gitlab-runner-ec2-token-*"]
  }
}

resource "aws_iam_policy" "runner_token_read" {
  name   = "${local.name_prefix}-gitlab-runner-ec2-token-read"
  policy = data.aws_iam_policy_document.runner_token_read.json
}

resource "aws_iam_role_policy_attachment" "runner_token_read" {
  role       = aws_iam_role.runner.name
  policy_arn = aws_iam_policy.runner_token_read.arn
}

resource "aws_iam_instance_profile" "runner" {
  name = "${local.name_prefix}-gitlab-runner-ec2"
  role = aws_iam_role.runner.name
}

# ---------------------------------------------------------------------------
# 보안그룹 — 인바운드 없음(SSM만 사용), 아웃바운드 전체(NAT 경유 — GitLab.com·
# ECR·패키지 저장소).
# ---------------------------------------------------------------------------

resource "aws_security_group" "runner" {
  name_prefix = "${local.name_prefix}-gitlab-runner-ec2-"
  # AWS가 보안그룹 description에 ASCII만 허용해서 한글을 쓸 수 없다(실제 apply에서
  # InvalidParameterValue로 거부됨) — 설명은 영문으로 두고 한글 맥락은 주석으로 남긴다.
  # 인바운드 없음(접속은 SSM Session Manager 전용), 아웃바운드만 전체 허용(NAT 경유).
  description = "GitLab Runner EC2: no inbound (SSM only), all outbound"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# EKS API 접근 — 2026-10-15 추가. 3-gitops Terraform 컴포넌트가 kubernetes·
# helm 프로바이더로 EKS API 서버에 직접 TCP 443 연결을 시도하는데, 클러스터
# 보안그룹(EKS가 자동 생성·관리)이 기본적으로 자기 자신과 LBC 타겟그룹
# 바인딩만 허용해 러너 SG는 막혀 있었다(plan:seoul [rebuild/3-gitops]가
# "dial tcp ...:443: i/o timeout"으로 실패 — 10/14 러너 이전 때는 발견하지
# 못했다, 위 헤더 주석 정정 참고).
#
# 클러스터 SG 자체는 2-cluster/modules/aws-eks가 관리하므로 여기서는 그
# 리소스를 건드리지 않고 별도 aws_vpc_security_group_ingress_rule로 규칙만
# 하나 추가한다 — AWS는 같은 SG에 여러 Terraform 컴포넌트가 각자 규칙을
# 추가하는 걸 허용하므로 2-cluster state에 영향이 없다(CNPG·NATS 무관).
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "runner_to_cluster_api" {
  security_group_id            = data.terraform_remote_state.cluster.outputs.cluster_security_group_id
  referenced_security_group_id = aws_security_group.runner.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
  description                  = "gitlab-runner-ec2 needs K8s API for 3-gitops kubernetes/helm providers"
}

# ---------------------------------------------------------------------------
# EC2 — 전용 EBS(빌드 캐시가 CNPG·NATS와 노드 디스크를 공유하던 경합 제거가
# 이전의 목적 중 하나) + ASG(desired=1)로 감싸 인스턴스 장애 시 자동 재생성.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "runner" {
  name_prefix   = "${local.name_prefix}-gitlab-runner-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.runner.arn
  }

  vpc_security_group_ids = [aws_security_group.runner.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_tokens = "required" # IMDSv2 강제
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    region            = var.region
    token_secret_name = "${local.name_prefix}-gitlab-runner-ec2-token"
    concurrent        = var.runner_concurrent
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${local.name_prefix}-gitlab-runner"
      project = var.project_name
      owner   = var.owner
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "runner" {
  name                = "${local.name_prefix}-gitlab-runner"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = data.terraform_remote_state.network.outputs.private_app_subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.runner.id
    version = aws_launch_template.runner.latest_version
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-gitlab-runner"
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
  }
}
