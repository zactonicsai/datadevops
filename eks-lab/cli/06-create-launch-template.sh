#!/usr/bin/env bash
# =============================================================================
# 06-create-launch-template.sh  —  ONE JOB: the EC2 launch template.
#
# A LAUNCH TEMPLATE is a saved recipe for "what an EC2 instance should look
# like". The node group uses it every time it needs a new worker machine.
#
# WHY BOTHER? The plain node-group API cannot express things we care about:
#   - encrypted disks
#   - IMDSv2 enforcement (a real security control, explained below)
#   - a specific disk size and type
#   - extra security groups
# A launch template can. This is the production pattern, and it costs nothing
# extra to learn it now.
#
# Note: this is the ONE real "launch template" in AWS terms. The scripts named
# 10-14 "launch" the applications using Kubernetes manifests, which are a
# different kind of template. The README explains the distinction.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws
require SG_NODE

banner "Step 6 / EC2 launch template for worker nodes"
R=(--region "$AWS_REGION")
LT_NAME="${LAB_NAME}-node-lt"

if aws ec2 describe-launch-templates "${R[@]}" --launch-template-names "$LT_NAME" >/dev/null 2>&1; then
  warn "Launch template ${LT_NAME} already exists"
else
  log "Creating launch template ${LT_NAME} ..."

  # -------------------------------------------------------------------------
  # IMDSv2 EXPLAINED (the httpTokens / hop-limit settings below)
  #
  # Every EC2 instance can ask a magic internal address (169.254.169.254) for
  # its own AWS credentials. Handy — and dangerous, because a compromised pod
  # could ask the same question and steal the NODE's permissions.
  #
  #   HttpTokens: required        -> must fetch a session token first, which
  #                                  blocks a whole class of attacks where an
  #                                  app is tricked into fetching a URL
  #   HttpPutResponseHopLimit: 1  -> the reply will not travel more than one
  #                                  network hop, so it cannot cross the
  #                                  container network boundary into a pod
  #
  # These two lines are free and stop pods from stealing node credentials.
  # -------------------------------------------------------------------------
  cat > /tmp/${LAB_NAME}-lt-data.json <<JSON
{
  "MetadataOptions": {
    "HttpTokens": "required",
    "HttpEndpoint": "enabled",
    "HttpPutResponseHopLimit": 1,
    "InstanceMetadataTags": "enabled"
  },
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/xvda",
      "Ebs": {
        "VolumeSize": ${NODE_DISK_GB},
        "VolumeType": "gp3",
        "Encrypted": true,
        "DeleteOnTermination": true
      }
    }
  ],
  "SecurityGroupIds": ["${SG_NODE}"],
  "Monitoring": { "Enabled": false },
  "TagSpecifications": [
    {
      "ResourceType": "instance",
      "Tags": [
        {"Key": "Name", "Value": "${LAB_NAME}-node"},
        {"Key": "Lab",  "Value": "${LAB_NAME}"}
      ]
    }
  ]
}
JSON

  # We deliberately do NOT set ImageId or InstanceType here.
  # Leaving them out lets the EKS managed node group choose the correct
  # EKS-optimised AMI for our Kubernetes version and patch it for us.
  # Set ImageId only when you need your own hardened image.
  aws ec2 create-launch-template "${R[@]}" \
    --launch-template-name "$LT_NAME" \
    --version-description "EKS lab worker nodes" \
    --launch-template-data "file:///tmp/${LAB_NAME}-lt-data.json" \
    --tag-specifications "ResourceType=launch-template,Tags=[{Key=Name,Value=${LT_NAME}},{Key=Lab,Value=${LAB_NAME}}]" \
    >/dev/null
  rm -f "/tmp/${LAB_NAME}-lt-data.json"
  ok "Launch template created"
fi

save LT_NAME "$LT_NAME"
save LT_ID "$(aws ec2 describe-launch-templates "${R[@]}" --launch-template-names "$LT_NAME" --query 'LaunchTemplates[0].LaunchTemplateId' --output text)"
save LT_VERSION "$(aws ec2 describe-launch-templates "${R[@]}" --launch-template-names "$LT_NAME" --query 'LaunchTemplates[0].LatestVersionNumber' --output text)"

echo
log "Inspect it with:"
echo "  aws ec2 describe-launch-template-versions --launch-template-name ${LT_NAME} --region ${AWS_REGION}"
echo
log "Next: ./07-create-nodegroup.sh"
