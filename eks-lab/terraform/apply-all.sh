#!/usr/bin/env bash
# =============================================================================
# apply-all.sh — run every Terraform layer in order.
#
# You can equally run each layer by hand; that is the point of splitting them.
# This just saves typing while you are learning.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
VARS="$(pwd)/dev.tfvars"

for layer in 01-vpc 02-iam-sg 03-cluster 04-nodegroup; do
  echo
  echo "############################  $layer  ############################"
  ( cd "$layer"
    terraform init -input=false
    terraform plan  -input=false -var-file="$VARS" -out=tfplan
    terraform apply -input=false tfplan )
done

# The cluster must exist before we can point kubectl at it.
CLUSTER=$(cd 03-cluster && terraform output -raw cluster_name)
REGION=$(grep -E '^\s*region' dev.tfvars | head -1 | cut -d'"' -f2)
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

echo
echo "############################  05-apps  ############################"
# Note: this layer talks to the Kubernetes API, so the cluster and nodes
# must already be up. That is why it runs last and separately.
( cd 05-apps
  terraform init -input=false
  terraform plan  -input=false -var-file="$VARS" -out=tfplan
  terraform apply -input=false tfplan
  terraform output )
