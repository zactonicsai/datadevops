data "aws_iam_role" "existing" {
  count = var.create ? 0 : 1
  name  = var.existing_role_name
}

data "aws_iam_policy_document" "trust" {
  count = var.create ? 1 : 0

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
    for_each = length(var.trusted_role_arns) > 0 ? [1] : []
    content {
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = var.trusted_role_arns
      }
    }
  }
  dynamic "statement" {
    for_each = var.oidc != null ? [var.oidc] : []
    content {
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [statement.value.provider_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${statement.value.issuer_host}:aud"
        values   = ["sts.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "${statement.value.issuer_host}:sub"
        values   = [for sa in statement.value.service_accounts : "system:serviceaccount:${sa}"]
      }
    }
  }
}

resource "aws_iam_role" "this" {
  count              = var.create ? 1 : 0
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.trust[0].json
  tags               = var.tags
}

locals {
  role_name = var.create ? aws_iam_role.this[0].name : data.aws_iam_role.existing[0].name
  role_arn  = var.create ? aws_iam_role.this[0].arn : data.aws_iam_role.existing[0].arn
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = var.create ? toset(var.managed_policy_arns) : toset([])
  role       = local.role_name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.create ? var.inline_policies : {}
  name     = each.key
  role     = local.role_name
  policy   = each.value
}

resource "aws_iam_policy" "from_file" {
  for_each = var.create ? var.policy_files : {}
  name     = "${var.name}-${each.key}"
  policy   = file(each.value)
  tags     = var.tags
}

resource "aws_iam_role_policy_attachment" "from_file" {
  for_each   = aws_iam_policy.from_file
  role       = local.role_name
  policy_arn = each.value.arn
}

resource "aws_iam_instance_profile" "this" {
  count = var.create && var.create_instance_profile ? 1 : 0
  name  = var.name
  role  = local.role_name
  tags  = var.tags
}
