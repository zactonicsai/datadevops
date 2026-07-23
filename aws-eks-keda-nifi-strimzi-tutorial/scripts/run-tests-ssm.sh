#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config

instance_id="$(
  aws ec2 describe-instances \
    --region "${AWS_REGION}" \
    --filters \
      "Name=tag:Project,Values=${PROJECT_NAME}" \
      "Name=tag:Environment,Values=${ENVIRONMENT}" \
      "Name=tag:Role,Values=eks-test-runner" \
      "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text
)"

if [[ -z "${instance_id}" || "${instance_id}" == "None" ]]; then
  echo "No running test runner was found."
  exit 1
fi

aws ssm start-session --region "${AWS_REGION}" --target "${instance_id}"
