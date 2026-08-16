#!/usr/bin/env bash
# =============================================================================
# d1-destroy-apps.sh  —  remove the applications (and their disks).
#
# ORDER MATTERS when destroying. You must remove things in the REVERSE order
# you created them, because later things depend on earlier things.
#
# Apps first, because:
#   - deleting a Service of type LoadBalancer removes the AWS load balancer.
#     If you skip this, the load balancer survives, keeps costing money, and
#     BLOCKS the VPC from being deleted later with a confusing dependency error.
#   - deleting PVCs removes the EBS volumes, which also cost money.
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/../00-config.sh"

banner "Destroy: applications"

if ! kubectl cluster-info >/dev/null 2>&1; then
  warn "Cannot reach the cluster — skipping (it may already be gone)."
  exit 0
fi

log "Uninstalling Helm releases..."
helm uninstall monitoring -n "$NS_MON" 2>/dev/null || true

log "Deleting application namespace ${NS_APPS} ..."
kubectl delete namespace "$NS_APPS" --ignore-not-found --timeout=300s
log "Deleting monitoring namespace ${NS_MON} ..."
kubectl delete namespace "$NS_MON" --ignore-not-found --timeout=300s

# Deleting a namespace removes its PVCs, and the EBS CSI driver then deletes
# the underlying volumes (because our StorageClass uses reclaimPolicy: Delete).
log "Checking no stray load balancers remain..."
kubectl get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null || true

log "Checking for orphaned EBS volumes tagged for this cluster..."
aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
  --query 'Volumes[].{Id:VolumeId,State:State,Size:Size}' --output table 2>/dev/null || true

ok "Applications removed."
log "Next: ./d2-destroy-nodegroup.sh"
