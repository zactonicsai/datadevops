#!/usr/bin/env bash
# =============================================================================
# 03-create-iam.sh  —  ONE JOB: the IAM roles.
#
# IAM answers "who is allowed to do what in AWS?"
#
# A ROLE is a hat that something can wear. It has:
#   - a TRUST POLICY  : who is allowed to wear the hat
#   - PERMISSIONS     : what the wearer may do
#
# We create two roles here:
#   1. Cluster role — worn by the EKS service itself, so AWS can manage
#      network cards and load balancers on your behalf.
#   2. Node role    — worn by each worker EC2 instance, so it can join the
#      cluster, pull container images and set up pod networking.
#
# The role that lets NiFi write to S3 is created later (08) because it needs
# the cluster's OIDC identity, which does not exist until the cluster exists.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool aws

banner "Step 3 / IAM roles"

R=(--region "$AWS_REGION")
TAGS="Key=Lab,Value=${LAB_NAME}"

# ---------------------------------------------------------------------------
# 1. EKS cluster role
# ---------------------------------------------------------------------------
CLUSTER_ROLE_NAME="${LAB_NAME}-eks-cluster-role"
if ! aws iam get-role --role-name "$CLUSTER_ROLE_NAME" >/dev/null 2>&1; then
  log "Creating cluster role ${CLUSTER_ROLE_NAME} ..."
  # "Principal: eks.amazonaws.com" = ONLY the EKS service may assume this role.
  # This is the least-privilege trust boundary; never use "*" here.
  aws iam create-role --role-name "$CLUSTER_ROLE_NAME" --tags "$TAGS" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "eks.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null
  aws iam attach-role-policy --role-name "$CLUSTER_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
  ok "Cluster role created"
else
  warn "Cluster role already exists, reusing it"
fi
save CLUSTER_ROLE_ARN "$(aws iam get-role --role-name "$CLUSTER_ROLE_NAME" --query 'Role.Arn' --output text)"
save CLUSTER_ROLE_NAME "$CLUSTER_ROLE_NAME"

# ---------------------------------------------------------------------------
# 2. Node role
# ---------------------------------------------------------------------------
NODE_ROLE_NAME="${LAB_NAME}-eks-node-role"
if ! aws iam get-role --role-name "$NODE_ROLE_NAME" >/dev/null 2>&1; then
  log "Creating node role ${NODE_ROLE_NAME} ..."
  aws iam create-role --role-name "$NODE_ROLE_NAME" --tags "$TAGS" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' >/dev/null

  # The four policies every EKS worker node needs:
  for P in \
    arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
    arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
    arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
    arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  do
    aws iam attach-role-policy --role-name "$NODE_ROLE_NAME" --policy-arn "$P"
    ok "attached $(basename "$P")"
  done
  # AmazonSSMManagedInstanceCore lets you get a shell on a node WITHOUT SSH:
  #   aws ssm start-session --target i-xxxx
  # That means no SSH keys, no port 22 open anywhere. Big security win, free.
else
  warn "Node role already exists, reusing it"
fi
save NODE_ROLE_ARN "$(aws iam get-role --role-name "$NODE_ROLE_NAME" --query 'Role.Arn' --output text)"
save NODE_ROLE_NAME "$NODE_ROLE_NAME"

# NOTE ON BEST PRACTICE:
# We deliberately give the NODE role nothing beyond what Kubernetes itself
# needs. Applications get their own roles (step 08). If the node role could
# write to S3, then every pod on that node could too — which would make our
# per-application permissions meaningless.

echo
log "Next: ./04-create-security-groups.sh"
