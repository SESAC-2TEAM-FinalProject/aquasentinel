resource "aws_eks_access_entry" "team" {
  for_each = { for m in var.team_members : m.name => m }

  cluster_name  = var.cluster_name
  principal_arn = each.value.iam_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "team" {
  for_each = aws_eks_access_entry.team

  cluster_name  = var.cluster_name
  principal_arn = each.value.principal_arn
  policy_arn    = var.access_policy_arn

  access_scope {
    type = "cluster"
  }
}
