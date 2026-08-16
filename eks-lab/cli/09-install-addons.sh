#!/usr/bin/env bash
# =============================================================================
# 09-install-addons.sh  —  ONE JOB: the cluster plumbing our apps depend on.
#
#   metrics-server        makes `kubectl top` and autoscaling work
#   aws-ebs-csi-driver    lets pods request persistent disks (NiFi and Kafka
#                         both need one; without this their PVCs stay Pending)
#   a StorageClass        says "when a pod asks for disk, make a gp3 volume"
#
# The EBS driver needs its own IRSA role — same pattern as NiFi in step 08.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws kubectl
require CLUSTER_NAME ACCOUNT_ID OIDC_ISSUER OIDC_PROVIDER_ARN

banner "Step 9 / Cluster add-ons"
R=(--region "$AWS_REGION")
OIDC_HOST="${OIDC_ISSUER#https://}"

# --- IRSA role for the EBS CSI driver ---------------------------------------
EBS_ROLE="${LAB_NAME}-ebs-csi-irsa"
if ! aws iam get-role --role-name "$EBS_ROLE" >/dev/null 2>&1; then
  log "Creating IRSA role for the EBS CSI driver..."
  aws iam create-role --role-name "$EBS_ROLE" --tags "Key=Lab,Value=${LAB_NAME}" \
    --assume-role-policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Principal\": {\"Federated\": \"${OIDC_PROVIDER_ARN}\"},
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {\"StringEquals\": {
          \"${OIDC_HOST}:aud\": \"sts.amazonaws.com\",
          \"${OIDC_HOST}:sub\": \"system:serviceaccount:kube-system:ebs-csi-controller-sa\"
        }}
      }]
    }" >/dev/null
  aws iam attach-role-policy --role-name "$EBS_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
fi
EBS_ROLE_ARN=$(aws iam get-role --role-name "$EBS_ROLE" --query 'Role.Arn' --output text)
save EBS_ROLE_NAME "$EBS_ROLE"

# --- Managed add-ons --------------------------------------------------------
install_addon() {  # name [service-account-role-arn]
  local name="$1" role="${2:-}"
  if aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$name" "${R[@]}" >/dev/null 2>&1; then
    warn "add-on ${name} already installed"; return
  fi
  log "Installing add-on ${name} ..."
  if [ -n "$role" ]; then
    aws eks create-addon "${R[@]}" --cluster-name "$CLUSTER_NAME" --addon-name "$name" \
      --service-account-role-arn "$role" --resolve-conflicts OVERWRITE >/dev/null
  else
    aws eks create-addon "${R[@]}" --cluster-name "$CLUSTER_NAME" --addon-name "$name" \
      --resolve-conflicts OVERWRITE >/dev/null
  fi
  aws eks wait addon-active "${R[@]}" --cluster-name "$CLUSTER_NAME" --addon-name "$name"
  ok "${name} active"
}

install_addon aws-ebs-csi-driver "$EBS_ROLE_ARN"
install_addon metrics-server

# --- StorageClass -----------------------------------------------------------
# WaitForFirstConsumer is important: it delays creating the disk until
# Kubernetes knows which Availability Zone the pod landed in. Without it you
# can get a disk in zone A and a pod in zone B, which can never attach.
log "Creating the gp3 StorageClass..."
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
YAML

# The default gp2 class (if present) should not also claim to be default
kubectl patch storageclass gp2 -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true

echo
kubectl get storageclass
kubectl -n kube-system get pods | head -20
echo
log "Next: ./10-launch-keycloak.sh"
