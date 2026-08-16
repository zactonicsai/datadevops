#!/usr/bin/env bash
# d3-destroy-cluster.sh  —  delete the EKS control plane. Stops the $0.10/hour.
# Must run AFTER the node group is gone, or AWS refuses.
set -uo pipefail
source "$(dirname "$0")/../00-config.sh"

banner "Destroy: EKS cluster"
R=(--region "$AWS_REGION")

if aws eks describe-cluster --name "$CLUSTER_NAME" "${R[@]}" >/dev/null 2>&1; then
  log "Deleting cluster ${CLUSTER_NAME} (about 10 minutes)..."
  aws eks delete-cluster "${R[@]}" --name "$CLUSTER_NAME" >/dev/null
  aws eks wait cluster-deleted "${R[@]}" --name "$CLUSTER_NAME"
  ok "Cluster deleted"
else
  warn "Cluster not found"
fi

# The OIDC provider is per-cluster; leaving it behind is harmless but untidy.
if [ -n "${OIDC_PROVIDER_ARN:-}" ]; then
  log "Deleting the IAM OIDC provider..."
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" 2>/dev/null || warn "already gone"
fi

# CloudWatch log group left by the cluster — deleting it stops storage charges.
log "Deleting the cluster log group..."
aws logs delete-log-group "${R[@]}" --log-group-name "/aws/eks/${CLUSTER_NAME}/cluster" 2>/dev/null || true

ok "Done. Next: ./d4-destroy-iam-sg.sh"
