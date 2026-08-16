#!/usr/bin/env bash
# =============================================================================
# 16-verify.sh  —  ONE JOB: check every link in the chain and say what is
#                  broken, in order.
#
# Debug in ORDER. The first failure is the real problem; everything after it
# is a symptom. This script walks the same order as the layer triage tree.
# =============================================================================
set -uo pipefail   # note: no -e, we want to keep checking after a failure
source "$(dirname "$0")/00-config.sh"

banner "Verifying the lab"
FAILED=0
check() {  # description   command...
  local desc="$1"; shift
  printf '  %-46s' "$desc"
  if "$@" >/dev/null 2>&1; then echo "${C_OK}PASS${C_OFF}"
  else echo "${C_ERR}FAIL${C_OFF}"; FAILED=$((FAILED+1)); fi
}

echo "--- AWS layer ---"
check "AWS credentials work"          aws sts get-caller-identity
check "VPC exists"                    aws ec2 describe-vpcs --vpc-ids "${VPC_ID:-none}" --region "$AWS_REGION"
check "Cluster is ACTIVE"             bash -c "aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.status' --output text | grep -q ACTIVE"
check "S3 bucket exists"              aws s3api head-bucket --bucket "${S3_BUCKET:-none}"

echo "--- Kubernetes layer ---"
check "kubectl can reach the cluster" kubectl get --raw=/readyz
check "All nodes Ready"               bash -c "! kubectl get nodes --no-headers | grep -qv ' Ready'"
check "StorageClass gp3 exists"       kubectl get storageclass gp3
check "No pods stuck Pending"         bash -c "! kubectl get pods -n $NS_APPS --no-headers 2>/dev/null | grep -q Pending"

echo "--- Applications ---"
check "Keycloak ready"                kubectl -n "$NS_APPS" wait --for=condition=available deploy/keycloak --timeout=5s
check "Kafka ready"                   bash -c "kubectl -n $NS_APPS get pod kafka-0 -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q true"
check "NiFi ready"                    bash -c "kubectl -n $NS_APPS get pod nifi-0 -o jsonpath='{.status.containerStatuses[0].ready}' | grep -q true"
check "Webapp ready"                  kubectl -n "$NS_APPS" wait --for=condition=available deploy/webapp --timeout=5s
check "Kafka topic exists"            bash -c "kubectl -n $NS_APPS exec kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep -q '^${KAFKA_TOPIC}$'"

echo "--- Permissions (IRSA) ---"
check "NiFi pod has AWS_ROLE_ARN"     bash -c "kubectl -n $NS_APPS exec nifi-0 -- env | grep -q AWS_ROLE_ARN"

echo
echo "--- Data in S3 ---"
COUNT=$(aws s3 ls "s3://${S3_BUCKET:-none}/" --recursive 2>/dev/null | wc -l | tr -d ' ')
echo "  Objects in s3://${S3_BUCKET:-?} : ${COUNT}"
[ "$COUNT" -gt 0 ] && ok "The pipeline has delivered data end to end." \
                   || warn "No objects yet. Send a message from the web app, or check the NiFi flow is STARTED."

echo
if [ "$FAILED" -eq 0 ]; then
  ok "All checks passed."
else
  echo "${C_ERR}${FAILED} check(s) failed.${C_OFF} Investigate the FIRST failure above:"
  echo "  kubectl -n ${NS_APPS} get pods"
  echo "  kubectl -n ${NS_APPS} describe pod <name>       # read the Events at the bottom"
  echo "  kubectl -n ${NS_APPS} logs <name> --previous    # what it said before crashing"
fi

echo
log "Current spend estimate (rough, per hour):"
echo "  EKS control plane   \$0.10"
echo "  ${NODE_DESIRED} x ${NODE_INSTANCE_TYPE} (${NODE_CAPACITY_TYPE})  ~\$0.05"
[ "${USE_NAT:-true}" = "true" ] && echo "  NAT gateway         \$0.045"
echo "  ------------------------------"
echo "  Roughly \$0.15-0.20/hour, about \$4/day if left running."
echo
warn "When you are finished:  ./destroy/destroy-all.sh"
