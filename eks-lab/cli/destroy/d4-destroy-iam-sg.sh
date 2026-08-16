#!/usr/bin/env bash
# d4-destroy-iam-sg.sh  —  delete IAM roles, policies, the S3 bucket and the
#                          security groups.
#
# IAM roles must have all their policies DETACHED before they can be deleted.
# This trips people up constantly, so the helper below does it properly.
set -uo pipefail
source "$(dirname "$0")/../00-config.sh"

banner "Destroy: IAM, S3 and security groups"
R=(--region "$AWS_REGION")

delete_role() {
  local role="$1"
  aws iam get-role --role-name "$role" >/dev/null 2>&1 || { warn "$role not found"; return; }
  log "Deleting role $role ..."
  # 1. detach managed policies
  for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn"
  done
  # 2. delete inline policies
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  aws iam delete-role --role-name "$role"
  ok "deleted $role"
}

delete_role "${CLUSTER_ROLE_NAME:-${LAB_NAME}-eks-cluster-role}"
delete_role "${NODE_ROLE_NAME:-${LAB_NAME}-eks-node-role}"
delete_role "${NIFI_ROLE_NAME:-${LAB_NAME}-nifi-irsa}"
delete_role "${EBS_ROLE_NAME:-${LAB_NAME}-ebs-csi-irsa}"

# Customer-managed policy (must be detached from everything first, done above)
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID:-000000000000}:policy/${LAB_NAME}-nifi-s3-policy"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "Deleting policy ${LAB_NAME}-nifi-s3-policy ..."
  # non-default versions must go first
  for v in $(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$v"
  done
  aws iam delete-policy --policy-arn "$POLICY_ARN"
fi

# --- S3 ---------------------------------------------------------------------
if [ -n "${S3_BUCKET:-}" ] && aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
  warn "About to PERMANENTLY DELETE s3://${S3_BUCKET} and everything in it."
  confirm "Delete the bucket?"
  log "Emptying the bucket (including old versions)..."
  # Versioning is on, so plain `rm` leaves delete-markers behind and the
  # bucket cannot be removed. This loop clears every version.
  aws s3api delete-objects --bucket "$S3_BUCKET" \
    --delete "$(aws s3api list-object-versions --bucket "$S3_BUCKET" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" >/dev/null 2>&1 || true
  aws s3api delete-objects --bucket "$S3_BUCKET" \
    --delete "$(aws s3api list-object-versions --bucket "$S3_BUCKET" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" >/dev/null 2>&1 || true
  aws s3 rb "s3://${S3_BUCKET}" --force
  ok "Bucket deleted"
fi

# --- Security groups --------------------------------------------------------
# Rules that reference other groups must be removed before the groups can go.
for sg in "${SG_ALB:-}" "${SG_NODE:-}"; do
  [ -z "$sg" ] && continue
  log "Clearing rules from $sg ..."
  PERMS=$(aws ec2 describe-security-groups "${R[@]}" --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)
  [ "$PERMS" != "[]" ] && [ -n "$PERMS" ] && \
    aws ec2 revoke-security-group-ingress "${R[@]}" --group-id "$sg" --ip-permissions "$PERMS" >/dev/null 2>&1 || true
done
for sg in "${SG_ALB:-}" "${SG_NODE:-}"; do
  [ -z "$sg" ] && continue
  log "Deleting security group $sg ..."
  aws ec2 delete-security-group "${R[@]}" --group-id "$sg" 2>/dev/null || warn "$sg still in use — retry after the VPC's ENIs clear"
done

ok "Done. Next: ./d5-destroy-networking.sh"
