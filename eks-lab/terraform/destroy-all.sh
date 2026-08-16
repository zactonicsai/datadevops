#!/usr/bin/env bash
# =============================================================================
# destroy-all.sh — tear down every layer, in REVERSE order.
#
# Reverse order matters: layer 5's load balancers and disks must go before
# the nodes, the nodes before the cluster, the cluster before the network.
# Skip the order and you get "DependencyViolation" errors.
#
# RUN THIS WHEN YOU ARE DONE. An idle lab still costs about $4/day.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
VARS="$(pwd)/dev.tfvars"

read -r -p "Destroy EVERYTHING including the S3 bucket contents? [y/N] " ok
[[ "$ok" =~ ^[yY] ]] || { echo "Aborted."; exit 1; }

for layer in 05-apps 04-nodegroup 03-cluster 02-iam-sg 01-vpc; do
  echo
  echo "############################  destroy $layer  ############################"
  ( cd "$layer" && terraform destroy -input=false -auto-approve -var-file="$VARS" ) \
    || echo "!! $layer reported a problem — continuing"
done

echo
echo "Verify nothing is left:"
echo "  aws ec2 describe-vpcs --filters Name=tag:Lab,Values=ekslab"
echo "  aws eks list-clusters"
echo "  aws ec2 describe-addresses      # unattached Elastic IPs are billed hourly"
