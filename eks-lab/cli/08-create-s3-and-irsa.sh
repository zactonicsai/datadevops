#!/usr/bin/env bash
# =============================================================================
# 08-create-s3-and-irsa.sh  —  ONE JOB: the destination bucket and the
#                              permission that lets NiFi (and only NiFi)
#                              write to it.
#
# THE IDEA: IRSA — "IAM Roles for Service Accounts"
#
#   Normally every pod on a node shares the node's AWS permissions. That is
#   bad: if the node can write to S3, ANY pod can write to S3.
#
#   IRSA gives ONE Kubernetes service account its own AWS role. The pod gets a
#   short-lived signed token, trades it at AWS for temporary credentials, and
#   only that pod can use them.
#
#   The magic is the "sub" condition in the trust policy below. It says:
#   "only the service account named 'nifi' in the namespace 'lab' may wear
#   this hat." One typo there and it silently falls back to the node role.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws kubectl
require ACCOUNT_ID OIDC_ISSUER OIDC_PROVIDER_ARN

banner "Step 8 / S3 bucket + IRSA role for NiFi"
R=(--region "$AWS_REGION")

# ---------------------------------------------------------------------------
# 1. The bucket. Bucket names are globally unique, so we add the account id.
# ---------------------------------------------------------------------------
if [ -z "${S3_BUCKET:-}" ]; then
  S3_BUCKET="${LAB_NAME}-messages-${ACCOUNT_ID}"
fi

if aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
  warn "Bucket ${S3_BUCKET} already exists"
else
  log "Creating bucket s3://${S3_BUCKET} ..."
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" --region us-east-1 >/dev/null
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi

  # --- Four settings that should be on EVERY bucket you ever create ---
  log "Blocking all public access..."
  aws s3api put-public-access-block --bucket "$S3_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  log "Enabling default encryption..."
  aws s3api put-bucket-encryption --bucket "$S3_BUCKET" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

  log "Enabling versioning (your undo button)..."
  aws s3api put-bucket-versioning --bucket "$S3_BUCKET" \
    --versioning-configuration Status=Enabled

  log "Adding a lifecycle rule so lab data auto-deletes after 7 days..."
  # This is the cheapest possible safety net: even if you forget to clean up,
  # storage costs stop growing.
  aws s3api put-bucket-lifecycle-configuration --bucket "$S3_BUCKET" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "lab-cleanup",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "Expiration": {"Days": 7},
        "NoncurrentVersionExpiration": {"NoncurrentDays": 1},
        "AbortIncompleteMultipartUpload": {"DaysAfterInitiation": 1}
      }]
    }'
  ok "Bucket configured"
fi
save S3_BUCKET "$S3_BUCKET"

# ---------------------------------------------------------------------------
# 2. The IAM policy — least privilege: this bucket, these actions, nothing else
# ---------------------------------------------------------------------------
POLICY_NAME="${LAB_NAME}-nifi-s3-policy"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if ! aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  log "Creating S3 policy ${POLICY_NAME} ..."
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:PutObject\", \"s3:GetObject\", \"s3:DeleteObject\"],
          \"Resource\": \"arn:aws:s3:::${S3_BUCKET}/*\"
        },
        {
          \"Effect\": \"Allow\",
          \"Action\": [\"s3:ListBucket\", \"s3:GetBucketLocation\"],
          \"Resource\": \"arn:aws:s3:::${S3_BUCKET}\"
        }
      ]
    }" >/dev/null
fi

# ---------------------------------------------------------------------------
# 3. The role, trusted by exactly one Kubernetes service account
# ---------------------------------------------------------------------------
OIDC_HOST="${OIDC_ISSUER#https://}"
ROLE_NAME="${LAB_NAME}-nifi-irsa"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  log "Creating IRSA role ${ROLE_NAME} ..."
  aws iam create-role --role-name "$ROLE_NAME" --tags "Key=Lab,Value=${LAB_NAME}" \
    --assume-role-policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": {\"Federated\": \"${OIDC_PROVIDER_ARN}\"},
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {
          \"StringEquals\": {
            \"${OIDC_HOST}:aud\": \"sts.amazonaws.com\",
            \"${OIDC_HOST}:sub\": \"system:serviceaccount:${NS_APPS}:nifi\"
          }
        }
      }]
    }" >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
fi
save NIFI_ROLE_ARN "$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"
save NIFI_ROLE_NAME "$ROLE_NAME"

# ---------------------------------------------------------------------------
# 4. Namespace + the service account carrying the annotation
# ---------------------------------------------------------------------------
kubectl create namespace "$NS_APPS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS_APPS" create serviceaccount nifi --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NS_APPS" annotate serviceaccount nifi \
  "eks.amazonaws.com/role-arn=${NIFI_ROLE_ARN}" --overwrite

echo
ok "Bucket: s3://${S3_BUCKET}"
ok "Role:   ${NIFI_ROLE_ARN}"
echo
warn "IRSA credentials are only injected when a pod STARTS. If you annotate a"
warn "service account after the pod is running, you must restart the pod."
echo
log "Next: ./09-install-addons.sh"
