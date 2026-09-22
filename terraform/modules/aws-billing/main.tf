locals {
  budget_name = coalesce(var.budget_name, "${var.project_name}-monthly")
}

# ---------------------------------------------------------------------------
# 비용 배분 태그 활성화 — default_tags로 리소스에 태그가 달려 있어도, 이걸
# 활성화하지 않으면 Cost Explorer/Budgets가 태그 기준으로 비용을 못 쪼갠다.
# (계정 전체에 1번만 존재하는 설정이라 environments/global/billing에 둔다)
# ---------------------------------------------------------------------------

resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(var.cost_allocation_tag_keys)

  tag_key = each.value
  status  = "Active"
}

# ---------------------------------------------------------------------------
# AWS Budgets — 계획서 16절 "50/80/100% 알림" 요구사항.
# 이 프로젝트 태그(project=var.project_name)가 붙은 리소스만 집계 대상으로 한다.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = local.budget_name
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    # "$${...}"로 이어붙이면 Terraform이 "${"를 리터럴 이스케이프로 오인하므로
    # format()으로 "user:project$<값>" 문자열을 만든다.
    values = [format("user:project$%s", var.project_name)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  depends_on = [aws_ce_cost_allocation_tag.this]
}
