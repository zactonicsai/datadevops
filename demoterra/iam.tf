###############################################################################
# IAM - lookups only.
#
# The instance profile is managed OUTSIDE this project, so this stack never
# needs iam:Create* permissions.
#
# The role behind instance_profile_name needs:
#   - secretsmanager:GetSecretValue on  <project>-<env>/*
#   - kms:Decrypt                       if a customer-managed key is used
#   - logs:CreateLogStream, logs:PutLogEvents on the Keycloak log group
#   - AmazonSSMManagedInstanceCore      for Session Manager access (recommended)
#   - Trust policy: ec2.amazonaws.com
#
# See docs/iam-requirements.json for ready-to-hand-over policy documents.
###############################################################################

data "aws_iam_instance_profile" "keycloak" {
  name = var.instance_profile_name
}

data "aws_iam_role" "vpc_flow_logs" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  name = var.vpc_flow_logs_role_name
}
