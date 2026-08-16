#!/usr/bin/env bash
# =============================================================================
# 07-create-nodegroup.sh  —  ONE JOB: create the worker machines.
#
# A NODE GROUP is a self-healing set of identical EC2 instances that
# automatically join the cluster. If one dies, a replacement appears.
#
# COST: this is where most of your money goes after the control plane.
# We default to SPOT instances, which are spare AWS capacity at ~70% off.
# AWS can reclaim them with 2 minutes' notice — perfectly fine for a lab,
# and Kubernetes will simply reschedule the pods.
#
# Takes about 5 minutes.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws kubectl
require CLUSTER_NAME NODE_ROLE_ARN NODE_SUBNETS LT_ID LT_VERSION

banner "Step 7 / Node group (${NODE_DESIRED} x ${NODE_INSTANCE_TYPE} ${NODE_CAPACITY_TYPE})"
R=(--region "$AWS_REGION")
NG_NAME="${LAB_NAME}-ng"

if aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG_NAME" "${R[@]}" >/dev/null 2>&1; then
  warn "Node group ${NG_NAME} already exists"
else
  IFS=',' read -r SN1 SN2 <<< "$NODE_SUBNETS"
  log "Creating node group in subnets ${SN1} ${SN2} ..."

  aws eks create-nodegroup "${R[@]}" \
    --cluster-name "$CLUSTER_NAME" \
    --nodegroup-name "$NG_NAME" \
    --node-role "$NODE_ROLE_ARN" \
    --subnets "$SN1" "$SN2" \
    --instance-types "$NODE_INSTANCE_TYPE" \
    --capacity-type "$NODE_CAPACITY_TYPE" \
    --scaling-config "minSize=${NODE_MIN},maxSize=${NODE_MAX},desiredSize=${NODE_DESIRED}" \
    --update-config "maxUnavailable=1" \
    --launch-template "id=${LT_ID},version=${LT_VERSION}" \
    --labels "workload=lab" \
    --tags "Lab=${LAB_NAME}" \
    >/dev/null

  log "Waiting for nodes to join (about 5 minutes)..."
  aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG_NAME" "${R[@]}"
fi
save NG_NAME "$NG_NAME"

log "Waiting for all nodes to report Ready..."
kubectl wait --for=condition=Ready node --all --timeout=600s

echo
kubectl get nodes -o wide
echo
log "Handy checks:"
echo "  kubectl get nodes"
echo "  kubectl top nodes                 # needs metrics-server (step 09)"
echo "  aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} --nodegroup-name ${NG_NAME} --region ${AWS_REGION}"
echo
log "Next: ./08-create-s3-and-irsa.sh"
