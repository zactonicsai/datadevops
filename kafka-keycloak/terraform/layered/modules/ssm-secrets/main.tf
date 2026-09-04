resource "aws_ssm_parameter" "this" {
  for_each = nonsensitive(toset(keys(var.secrets)))
  name     = "${var.prefix}/${each.key}"
  type     = "SecureString"
  value    = var.secrets[each.key]
  tags     = var.tags
}
