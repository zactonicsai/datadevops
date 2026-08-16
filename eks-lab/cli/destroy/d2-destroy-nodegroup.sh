#!/usr/bin/env bash
# d2-destroy-nodegroup.sh  —  delete the worker machines and the launch template.
# This stops most of your hourly EC2 spend. Takes ~5 minutes.
set -uo pipefail
source "$(dirname "$0")/../00-config.sh"

banner "Destroy: node group + launch template"
R=(--region "$AWS_REGION")

if [ -n "${NG_NAME:-}" ] && aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG_NAME" "${R[@]}" >/dev/null 2>&1; then
  log "Deleting node group ${NG_NAME} (about 5 minutes)..."
  aws eks delete-nodegroup "${R[@]}" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG_NAME" >/dev/null
  aws eks wait nodegroup-deleted "${R[@]}" --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG_NAME"
  ok "Node group deleted"
else
  warn "No node group found"
fi

if [ -n "${LT_NAME:-}" ]; then
  log "Deleting launch template ${LT_NAME} ..."
  aws ec2 delete-launch-template "${R[@]}" --launch-template-name "$LT_NAME" >/dev/null 2>&1 || warn "already gone"
fi

ok "Done. Next: ./d3-destroy-cluster.sh"
