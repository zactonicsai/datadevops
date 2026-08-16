#!/usr/bin/env bash
# =============================================================================
# 05-create-cluster.sh  —  ONE JOB: create the EKS control plane.
#
# The CONTROL PLANE is the brain of Kubernetes: the API server you talk to,
# the database that stores what you asked for, and the controllers that make
# it happen. AWS runs all of it for you across three data centres.
#
# You get NO servers to log into here. You just get an HTTPS endpoint.
# Cost: about $0.10 per hour, whether you use it or not.
#
# This takes 10-15 minutes. That is normal.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws kubectl
require VPC_ID SUBNET_PUB_A SUBNET_PUB_B SUBNET_PRIV_A SUBNET_PRIV_B CLUSTER_ROLE_ARN SG_NODE

banner "Step 5 / EKS cluster: ${CLUSTER_NAME}"
R=(--region "$AWS_REGION")

if aws eks describe-cluster --name "$CLUSTER_NAME" "${R[@]}" >/dev/null 2>&1; then
  warn "Cluster ${CLUSTER_NAME} already exists"
else
  warn "This creates a cluster billed at ~\$0.10/hour until you destroy it."
  confirm "Create the EKS control plane now?"

  log "Creating cluster (10-15 minutes)..."
  # We give EKS ALL four subnets. It places its own network cards in them so
  # the control plane can reach your nodes.
  #
  # authenticationMode=API uses modern "access entries" instead of the old
  # aws-auth ConfigMap. A typo in aws-auth could lock you out permanently;
  # access entries are normal AWS API objects you can always fix.
  aws eks create-cluster "${R[@]}" \
    --name "$CLUSTER_NAME" \
    --kubernetes-version "$K8S_VERSION" \
    --role-arn "$CLUSTER_ROLE_ARN" \
    --resources-vpc-config "subnetIds=${SUBNET_PUB_A},${SUBNET_PUB_B},${SUBNET_PRIV_A},${SUBNET_PRIV_B},securityGroupIds=${SG_NODE},endpointPublicAccess=true,endpointPrivateAccess=true" \
    --access-config "authenticationMode=API,bootstrapClusterCreatorAdminPermissions=true" \
    --logging '{"clusterLogging":[{"types":["api","audit","authenticator"],"enabled":true}]}' \
    >/dev/null

  log "Waiting for the cluster to become ACTIVE..."
  aws eks wait cluster-active --name "$CLUSTER_NAME" "${R[@]}"
  ok "Cluster is ACTIVE"
fi

# SECURITY NOTE
# endpointPublicAccess=true keeps this lab usable from your laptop.
# For anything real, set it to false and reach the API through a VPN or a
# bastion inside the VPC. To lock the public endpoint to just your address:
#   aws eks update-cluster-config --name "$CLUSTER_NAME" \
#     --resources-vpc-config publicAccessCidrs=$(curl -s https://checkip.amazonaws.com)/32

save CLUSTER_ENDPOINT "$(aws eks describe-cluster --name "$CLUSTER_NAME" "${R[@]}" --query 'cluster.endpoint' --output text)"
save OIDC_ISSUER      "$(aws eks describe-cluster --name "$CLUSTER_NAME" "${R[@]}" --query 'cluster.identity.oidc.issuer' --output text)"

# ---------------------------------------------------------------------------
# Register the cluster's OIDC provider with IAM.
# This is what lets an individual POD get its own AWS permissions later
# (the feature is called IRSA: IAM Roles for Service Accounts).
# ---------------------------------------------------------------------------
OIDC_HOST="${OIDC_ISSUER#https://}"
if ! aws iam list-open-id-connect-providers \
      --query "OpenIDConnectProviderList[?contains(Arn,'${OIDC_HOST##*/}')]" --output text | grep -q .; then
  log "Registering the cluster's OIDC provider with IAM..."
  THUMB=$(echo | openssl s_client -servername oidc.eks."${AWS_REGION}".amazonaws.com \
            -connect oidc.eks."${AWS_REGION}".amazonaws.com:443 2>/dev/null \
          | openssl x509 -fingerprint -noout 2>/dev/null \
          | sed 's/.*=//' | tr -d ':' | tr 'A-Z' 'a-z')
  aws iam create-open-id-connect-provider \
    --url "$OIDC_ISSUER" --client-id-list sts.amazonaws.com \
    --thumbprint-list "${THUMB:-9e99a48a9960b14926bb7f3b02e22da2b0ab7280}" >/dev/null || \
    warn "OIDC provider may already exist"
fi
save OIDC_PROVIDER_ARN "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"

# ---------------------------------------------------------------------------
# Write cluster credentials into ~/.kube/config so kubectl works
# ---------------------------------------------------------------------------
log "Configuring kubectl..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" --alias "$LAB_NAME"
kubectl cluster-info
echo
warn "'kubectl get nodes' will say 'No resources found' — that is correct."
warn "We have a brain but no workers yet. That is the next two scripts."
echo
log "Next: ./06-create-launch-template.sh"
