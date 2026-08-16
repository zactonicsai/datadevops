#!/usr/bin/env bash
# =============================================================================
# destroy-all.sh  —  tear the whole lab down, in the correct order.
#
# Run this when you are finished. Total time: about 20 minutes, most of it
# waiting for AWS to delete the node group and the cluster.
#
# RUN IT. An idle lab still costs roughly $4/day.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"
source ../00-config.sh

banner "DESTROY EVERYTHING"
echo "This deletes:"
echo "  - all applications and their data"
echo "  - the S3 bucket AND ITS CONTENTS"
echo "  - the node group, cluster, IAM roles, network and VPC"
echo
confirm "Are you sure?"

for s in d1-destroy-apps.sh d2-destroy-nodegroup.sh d3-destroy-cluster.sh \
         d4-destroy-iam-sg.sh d5-destroy-networking.sh d6-destroy-vpc.sh; do
  echo
  echo "############ $s ############"
  ASSUME_YES=true bash "./$s" || warn "$s reported a problem — continuing"
done

echo
ok "Teardown finished. Verify nothing is left:"
echo "  aws ec2 describe-vpcs --region ${AWS_REGION} --filters Name=tag:Lab,Values=${LAB_NAME}"
echo "  aws eks list-clusters --region ${AWS_REGION}"
echo "  aws ec2 describe-addresses --region ${AWS_REGION}   # unattached Elastic IPs cost money"
