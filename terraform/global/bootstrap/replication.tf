# ---------------------------------------------------------------------------
# tfstate 버킷의 리전 간 복제(CRR) — 서울 → 도쿄
# ---------------------------------------------------------------------------
#
# 왜 필요한가 — 「서울이 죽었다」는 가정과 실제 코드가 어긋나 있다.
#
#   전 컴포넌트(2026-10-27 기준 15개)의 backend.hcl 이 **전부**
#   bucket = aquasentinel-tfstate-…
#   region = ap-northeast-2 를 가리킨다(2026-10-26 실측). 진짜 서울 리전 장애면
#   도쿄를 세우려고 `terraform init` 하는 순간 **서울 S3 를 때리고 막힌다.**
#   DR 시나리오 문서가 이것을 `[가정 예외]` 로 적어 둔 그 지점이다.
#
# 2026-10-26 실측 — 전제조건은 이미 충족돼 있다:
#   원본 버킷 리전 ap-northeast-2 · 버전 관리 **Enabled** · 복제 설정 **없음**
#   → 복제는 원본 버전 관리가 켜져 있어야만 걸 수 있으므로, 남은 것은 설정뿐이다.
#   비용도 사실상 0이다(상태 파일 전체가 수 MB 규모).
#
# 🔴 복제만으로는 못 쓴다 — backend 를 바꾸는 단계가 같이 있어야 한다.
#   복제본이 있어도 backend.hcl 이 서울을 가리키면 아무 의미가 없다.
#   전환 절차와 스크립트: `runbooks/Terraform상태_리전전환.md` ·
#   `scripts/dr-switch-tfstate-backend.sh`
#
# 🔴 복제는 **설정한 뒤에 쓰인 객체만** 옮긴다(소급 적용 없음).
#   state 는 apply 할 때만 쓰이므로, 한동안 apply 하지 않은 컴포넌트는
#   복제본이 **비어 있다**. 그리고 그런 컴포넌트가 바로 DR 에서 필요한 쪽이다
#   (global/bootstrap · seoul/persistent). 그래서 켠 직후 **1회 전량 동기화**가
#   필요하다 — 위 런북 2장에 명령으로 적어 두었다.

provider "aws" {
  alias  = "replica"
  region = var.tfstate_replica_region

  default_tags {
    tags = {
      project    = var.project_name
      managed_by = "terraform"
      component  = "bootstrap"
    }
  }
}

# ── 받는 쪽 버킷(도쿄) ────────────────────────────────────────────────────
#
# 원본과 같은 이름을 쓸 수 없다(S3 버킷 이름은 전역 유일) — `-replica` 를 붙인다.
# 🔴 그래서 DR 때 backend.hcl 의 bucket 값도 **같이** 바뀐다(region 만 바꾸면 안 된다).

resource "aws_s3_bucket" "tfstate_replica" {
  count    = var.enable_tfstate_replication ? 1 : 0
  provider = aws.replica

  bucket = "${var.project_name}-tfstate-replica-${data.aws_caller_identity.current.account_id}"

  # 원본과 같은 이유로 보호한다 — 이쪽이 지워지면 DR 에서 쓸 것이 없다.
  lifecycle {
    prevent_destroy = true
  }
}

# 복제는 **받는 쪽도** 버전 관리가 켜져 있어야 동작한다.
resource "aws_s3_bucket_versioning" "tfstate_replica" {
  count    = var.enable_tfstate_replication ? 1 : 0
  provider = aws.replica

  bucket = aws_s3_bucket.tfstate_replica[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# 원본이 AES256(SSE-S3)이다. KMS 가 아니라서 복제 역할에 키 권한을 따로 줄 필요가 없다 —
# KMS 로 바꾸면 이 파일의 IAM 정책에 kms:Decrypt/Encrypt 와 키 정책이 추가로 필요해진다.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate_replica" {
  count    = var.enable_tfstate_replication ? 1 : 0
  provider = aws.replica

  bucket = aws_s3_bucket.tfstate_replica[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate_replica" {
  count    = var.enable_tfstate_replication ? 1 : 0
  provider = aws.replica

  bucket = aws_s3_bucket.tfstate_replica[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── 복제 역할 ─────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "replication_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  count = var.enable_tfstate_replication ? 1 : 0

  name               = "${var.project_name}-tfstate-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume.json
}

data "aws_iam_policy_document" "replication" {
  # 끄면 아예 계산하지 않는다 — 안 그러면 resources 가 빈 statement 가 만들어지고,
  # 그건 IAM 이 거부하는 형태다(지금은 아래 role_policy 도 같이 꺼져서 붙지는 않지만,
  # 나중에 누가 count 없이 붙이면 그대로 터진다).
  count = var.enable_tfstate_replication ? 1 : 0

  # 원본에서 읽을 권한
  statement {
    effect    = "Allow"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
    ]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  # 받는 쪽에 쓸 권한
  statement {
    effect = "Allow"
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
    ]
    resources = ["${aws_s3_bucket.tfstate_replica[0].arn}/*"]
  }
}

resource "aws_iam_role_policy" "replication" {
  count = var.enable_tfstate_replication ? 1 : 0

  name   = "${var.project_name}-tfstate-replication"
  role   = aws_iam_role.replication[0].id
  policy = data.aws_iam_policy_document.replication[0].json
}

# ── 복제 설정(원본에 붙는다) ──────────────────────────────────────────────

resource "aws_s3_bucket_replication_configuration" "tfstate" {
  count = var.enable_tfstate_replication ? 1 : 0

  # 복제는 원본 버전 관리가 켜진 뒤에만 걸 수 있다. 명시하지 않으면
  # 최초 apply 에서 순서가 뒤집혀 InvalidRequest 로 깨진다.
  depends_on = [
    aws_s3_bucket_versioning.tfstate,
    aws_s3_bucket_versioning.tfstate_replica,
  ]

  role   = aws_iam_role.replication[0].arn
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "all-state-to-replica"
    status = "Enabled"

    # 버킷 전체. filter {} 를 비워 두면 전 객체가 대상이고, 이때만
    # delete_marker_replication 을 쓸 수 있다(태그 기반 필터와는 함께 못 쓴다).
    filter {}

    # 🔴 왜 삭제 표식도 복제하는가 — **Terraform 락 때문이다.**
    #
    # 이 레포는 DynamoDB 가 아니라 S3 네이티브 락을 쓴다(`use_lockfile = true`).
    # apply 할 때마다 `<key>.tflock` 을 만들고 끝나면 지운다. 삭제 표식을
    # 복제하지 않으면 **도쿄에는 그 .tflock 이 지워지지 않고 남는다** →
    # DR 때 `terraform apply` 가 "Error acquiring the state lock" 으로 막힌다.
    # 락은 apply 마다 생기므로 이 사고는 드문 일이 아니라 기본값이 된다.
    #
    # 반대 위험(서울에서 실수로 state 를 지우면 도쿄도 지워진 것으로 보임)은
    # 받는 쪽 **버전 관리가 켜져 있어** 이전 버전으로 복구할 수 있다.
    # 즉 삭제 표식 복제를 켜는 쪽이 손실 위험은 같고 DR 성공률이 높다.
    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.tfstate_replica[0].arn
      storage_class = "STANDARD"
    }
  }
}
