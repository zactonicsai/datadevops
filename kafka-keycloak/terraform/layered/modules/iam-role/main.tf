locals {
  oidc_host = var.oidc_provider_arn == null ? null : element(split("oidc-provider/", var.oidc_provider_arn), 1)
}

data "aws_iam_policy_document" "assume" {
  dynamic "statement" {
    for_each = length(var.trusted_services) > 0 ? [1] : []
    content {
      actions = ["sts:AssumeRole"]
      principals {
        type        = "Service"
        identifiers = var.trusted_services
      }
    }
  }
  dynamic "statement" {
    for_each = var.oidc_provider_arn != null ? [1] : []
    content {
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [var.oidc_provider_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.oidc_host}:sub"
        values   = var.oidc_subjects
      }
      condition {
        test     = "StringEquals"
        variable = "${local.oidc_host}:aud"
        values   = ["sts.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role" "this" {
  count              = var.create ? 1 : 0
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = var.create ? toset(var.managed_policy_arns) : []
  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "file" {
  for_each = var.create ? var.inline_policy_files : {}
  name     = each.key
  role     = aws_iam_role.this[0].id
  policy   = file(each.value)
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.create ? var.inline_policies : {}
  name     = each.key
  role     = aws_iam_role.this[0].id
  policy   = each.value
}

resource "aws_iam_instance_profile" "this" {
  count = var.create && var.create_instance_profile ? 1 : 0
  name  = var.name
  role  = aws_iam_role.this[0].name
  tags  = var.tags
}
