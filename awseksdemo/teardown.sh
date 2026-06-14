#!/usr/bin/env bash
#
# Tear everything down in the correct order so nothing is orphaned.
# Deleting the Service first releases the AWS load balancer BEFORE the VPC
# stack tries to delete subnets (an orphaned LB blocks VPC deletion and keeps billing).
#
# Usage:
#   ./teardown.sh [cluster-name] [region]
set -euo pipefail

CLUSTER_NAME="${1:-hello-world-cluster}"
REGION="${2:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VPC_STACK="${CLUSTER_NAME}-vpc"
EKS_STACK="${CLUSTER_NAME}-eks"

echo "==> [1/4] Deleting Kubernetes Service (releases the load balancer)..."
kubectl delete -f "${SCRIPT_DIR}/03-hello-world.yaml" --ignore-not-found=true || true
echo "    Pausing 60s for the load balancer to deprovision..."
sleep 60

echo "==> [2/4] Deleting EKS stack (${EKS_STACK})..."
aws cloudformation delete-stack --region "${REGION}" --stack-name "${EKS_STACK}"
aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${EKS_STACK}"

echo "==> [3/4] Deleting VPC stack (${VPC_STACK})..."
aws cloudformation delete-stack --region "${REGION}" --stack-name "${VPC_STACK}"
aws cloudformation wait stack-delete-complete --region "${REGION}" --stack-name "${VPC_STACK}"

echo "==> [4/4] Done. All stacks removed."
