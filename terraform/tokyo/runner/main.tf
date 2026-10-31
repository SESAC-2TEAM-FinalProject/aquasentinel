# 도쿄 GitLab Runner — 재해 때 "도쿄를 세울 수단" 자체를 서울 밖에 둔다.
#
# 왜 필요한가 (2026-10-27 실측):
#   도쿄 복구 경로는 tokyo/rebuild/* Terraform 이고 그것을 돌리는 것은 GitLab CI 다.
#   그런데 .gitlab-ci.yml 의 모든 잡이 tags: [eks-self-hosted] 단일 태그에 묶여 있고
#   공유 러너는 꺼져 있다("태그가 없으면 온라인 러너 없음으로 대기" — 같은 파일 주석).
#   그 태그를 가진 러너는 서울 사설 서브넷의 EC2 한 대뿐이다(global/runner).
#   → 서울 리전이 빠지면 러너도 같이 빠지고, 도쿄를 복구할 수단이 사라진다.
#   이 컴포넌트는 그 순환을 끊는 것 하나만 한다.
#
# 🔴 왜 tokyo/rebuild/* 가 아니라 tokyo/runner 인가:
#   rebuild 쪽에 두면 도쿄를 내릴 때 러너도 같이 사라진다. 그런데 이 러너는
#   도쿄를 "다시 세우기 위해" 살아 있어야 한다 — 같은 순환이 한 겹 더 생긴다.
#   그래서 tokyo/persistent 와 같은 층(재구축 주기 밖)에 둔다. 상태 키도
#   tokyo/runner/terraform.tfstate 로 분리한다 — global/runner 와 같은 키를 쓰면
#   서울 러너 상태를 덮어쓴다.
#
# 🔴 최초 apply 는 서울 러너 또는 로컬에서 한다 — global/runner 와 같은 종류의
#   "닭과 달걀"이다(자기 자신을 만드는 러너는 아직 없다). 그 뒤부터는 일반
#   컴포넌트와 같이 CI validate/plan 대상이고 apply 만 수동이다.

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project     = var.project_name
      owner       = var.owner
      environment = var.environment
      managed_by  = "terraform"
      component   = "runner-tokyo"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # 🔴 IAM 은 계정 전역이다 — global/runner 와 같은 이름을 쓰면 그 컴포넌트의
  # 역할·정책·인스턴스 프로파일을 그대로 집어가 서울 러너를 깨뜨린다.
  # 그래서 IAM 이름에만 -tokyo 를 붙인다(리전으로 구분되는 SG·EC2 는 그대로).
  iam_name = "${local.name_prefix}-gitlab-runner-tokyo"
}

# ---------------------------------------------------------------------------
# 네트워크 — 도쿄 기본 VPC 를 쓴다.
#
# 🔴 왜 기본 VPC 인가:
#   ⑴ tokyo/rebuild/1-network 의 VPC(10.1.0.0/16)는 도쿄를 내릴 때 사라진다.
#      이 러너는 그때도 살아 있어야 한다.
#   ⑵ 기본 VPC 는 172.31.0.0/16 이라 10.1.0.0/16 과 CIDR 이 겹치지 않는다
#      (2026-10-27 실측 — vpc-0fbdc871b703c5d11).
#   ⑶ IGW 가 이미 붙어 있고 서브넷 3개(1a·1c·1d, = 도쿄 재구축 AZ 와 동일)가
#      전부 map_public_ip_on_launch=true 다 → NAT 를 만들지 않아도 아웃바운드가 된다.
#      도쿄 NAT 는 0개이고, NAT 를 새로 만들면 월 비용 + 재구축 VPC 의존이 붙는다.
#
# 🔴 VPC·서브넷을 remote_state 로 읽지 않는다 — 서울 state 를 읽으면 "서울이
#   빠졌을 때 동작해야 한다"는 이 컴포넌트의 목적 자체와 모순된다.
#   (global/runner 는 main.tf:56·:68 에서 서울 1-network·2-cluster 를 읽는다.)
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  # 공개 IP 가 자동 할당되는 서브넷만 — 아웃바운드가 IGW 로 바로 나가야 한다.
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

# AL2023 최신 AMI — global/runner 와 같은 SSM 별칭을 쓴다(리전별로 다른 AMI ID 를
# 자동으로 받는다. 하드코딩하면 리전을 옮길 때마다 틀린다).
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# IAM — global/runner 와 같은 권한 묶음(SSM 접속 · ECR push/pull · 등록 토큰 1개).
# EKS 접근 권한은 여기도 주지 않는다 — 3-gitops 의 kubernetes·helm 프로바이더는
# 인스턴스 프로파일이 아니라 CI 의 OIDC 역할(modules/aws-cicd)로 인증한다.
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
  name               = local.iam_name
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = { project = var.project_name, owner = var.owner }
}

# SSM Session Manager 로 접속 — SSH 키·인바운드 규칙 불필요.
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

  # var.region 이 도쿄라 도쿄 ECR 로 좁혀진다. 도쿄 리포지토리는 서울 registry 의
  # Cross-Region Replication 이 AWS 쪽에서 만들어 둔다(tokyo/persistent 주석 참고).
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
  name   = "${local.iam_name}-ecr"
  policy = data.aws_iam_policy_document.runner_ecr.json
}

resource "aws_iam_role_policy_attachment" "runner_ecr" {
  role       = aws_iam_role.runner.name
  policy_arn = aws_iam_policy.runner_ecr.arn
}

# 등록 토큰 — GitLab UI 에서 발급해 **도쿄 리전** Secrets Manager 에 수동으로
# 넣어둔다. 평문을 git·user-data 에 남기지 않기 위함.
data "aws_iam_policy_document" "runner_token_read" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.token_secret_name}-*"]
  }
}

resource "aws_iam_policy" "runner_token_read" {
  name   = "${local.iam_name}-token-read"
  policy = data.aws_iam_policy_document.runner_token_read.json
}

resource "aws_iam_role_policy_attachment" "runner_token_read" {
  role       = aws_iam_role.runner.name
  policy_arn = aws_iam_policy.runner_token_read.arn
}

resource "aws_iam_instance_profile" "runner" {
  name = local.iam_name
  role = aws_iam_role.runner.name
}

# ---------------------------------------------------------------------------
# 보안그룹 — 인바운드 없음, 아웃바운드 전체.
#
# 🔴 global/runner 에 있는 "클러스터 SG 에 443 인그레스 추가"(main.tf:208)를
#   여기서는 하지 않는다. 두 가지 이유다.
#   ⑴ SG 참조(referenced_security_group_id)는 같은 리전의 같은 VPC 또는 피어링된
#      VPC 사이에서만 된다. 이 러너는 기본 VPC(172.31), 도쿄 EKS 는 재구축
#      VPC(10.1)라 피어링 없이는 성립하지 않는다.
#   ⑵ 필요가 없다 — 도쿄 EKS 는 공개 엔드포인트가 열려 있다. modules/aws-eks 는
#      endpoint_public_access 기본값이 true 이고 public_access_cidrs 는 레포 전체에
#      변수 자체가 없어(2026-10-27 전수 0건) AWS 기본 0.0.0.0/0 이 적용된다.
#      서울 실물도 PublicAccess=true · PublicCidrs=["0.0.0.0/0"] 로 확인했다.
#      이는 팀 결정 (ㄱ) "제한하지 않음"에 따른 것이고 사유는 ADR 로 남긴다.
#   🔴 만약 나중에 공개 엔드포인트를 CIDR 로 좁히게 되면 이 러너에 고정 주소
#      (EIP)가 필요해진다. 지금은 아래 "EIP 를 두지 않는 이유" 참고.
# ---------------------------------------------------------------------------

resource "aws_security_group" "runner" {
  name_prefix = "${local.name_prefix}-gitlab-runner-tokyo-"
  # AWS 가 SG description 에 ASCII 만 허용한다(한글은 apply 에서 거부됨).
  description = "GitLab Runner EC2 (Tokyo DR): no inbound (SSM only), all outbound"
  vpc_id      = data.aws_vpc.default.id

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
# EC2 — ASG desired=1 로 상시 가동(2026-10-27 원주님 결정).
#
# 🔴 왜 desired=0 으로 두고 재해 때 올리지 않는가:
#   비용은 싸지만 0 → 1 로 올릴 수단이 Terraform 이고, 그 Terraform 을 돌릴
#   러너가 바로 이 러너다 — 순환이 다시 생긴다. 손으로
#   `aws autoscaling set-desired-capacity` 를 치면 풀리지만, 재해 중에 런북
#   한 줄이 더 늘고 부팅 2~3분이 RTO 에 더해진다. 상시 가동을 택했다.
#
# 🔴 EIP 를 두지 않는 이유:
#   이 러너는 아웃바운드만 한다(GitLab.com · ECR · EKS 공개 엔드포인트 · SSM).
#   들어오는 연결이 없고, 공개 엔드포인트가 0.0.0.0/0 이라 주소를 허용목록에
#   올릴 곳도 없다. 그래서 서브넷의 자동 공개 IP 로 충분하다 — EIP 를 붙이면
#   user-data 에 associate-address 와 IAM 권한이 늘고 실패 지점이 하나 생긴다.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "runner" {
  name_prefix   = "${local.name_prefix}-gitlab-runner-tokyo-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.runner.arn
  }

  # 🔴 network_interfaces 를 쓰면 최상위 vpc_security_group_ids 와 같이 쓸 수 없다.
  # 공개 IP 를 명시로 받기 위해 이쪽을 쓴다(서브넷 기본값에만 의존하지 않는다).
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.runner.id]
    delete_on_termination       = true
  }

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
    # 기본값 1 은 Docker 브리지 네트워크의 홉 하나를 못 넘어 job 컨테이너에서
    # IMDS 에 닿지 않는다 — Kaniko 가 ECR 인증을 인스턴스 프로파일에서
    # 가져오려면 2 여야 한다(global/runner 와 같은 이유).
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh.tpl", {
    region            = var.region
    token_secret_name = var.token_secret_name
    concurrent        = var.runner_concurrent
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${local.name_prefix}-gitlab-runner-tokyo"
      project = var.project_name
      owner   = var.owner
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "runner" {
  name = "${local.name_prefix}-gitlab-runner-tokyo"

  # 🔴 평소 0 — 이 러너는 DR 훈련·재해 때만 쓴다(variables.tf 의 설명).
  #   깨울 때는 -var runner_desired_capacity=1 로 apply 한다.
  desired_capacity    = var.runner_desired_capacity
  min_size            = var.runner_desired_capacity
  max_size            = 1
  vpc_zone_identifier = data.aws_subnets.public.ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.runner.id
    version = aws_launch_template.runner.latest_version
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-gitlab-runner-tokyo"
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
  }
}
