#!/usr/bin/env bash
# ==========================================================================
# 00-existing-config.sh -- Settings for deploying NiFi into a network that
# ALREADY EXISTS and that you do not own.
#
# WHAT THIS MODE DOES NOT DO
#   No VPC. No subnets. No internet gateway. No route tables. No NAT.
#   No public IP addresses. No Elastic IPs.
#   Nothing public is created at all.
#
# WHAT IT DOES CREATE
#   A security group (inside the existing VPC)
#   An IAM role + instance profile
#   One EC2 instance with a PRIVATE address only
#   One DNS record in the EXISTING hosted zone
#
# People reach NiFi by its DNS name, resolved by the hosted zone, over your
# corporate network (VPN, Direct Connect, or from inside the VPC).
#
# Sourced by the other scripts here. Do not run it on its own.
# ==========================================================================

EX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export EX_DIR

# Reuse the shared helpers (log/ok/warn/die, save_state/load_state) and the
# NiFi version settings from the main project.
# shellcheck disable=SC1091
source "${EX_DIR}/../scripts/00-config.sh"

# ...but keep our own state file, so this deployment never collides with the
# build-your-own-network one.
export STATE_FILE="${EX_DIR}/.existing-state"
export BUILD_DIR="${EX_DIR}/build"
export SCRIPT_DIR="${EX_DIR}"

# ==========================================================================
# 1. THE EXISTING NETWORK  -- ask your network team for these
# ==========================================================================

# Required. The VPC you have been given.
export EXISTING_VPC_ID="vpc-CHANGEME"

# Required. One or more subnets, space separated. The FIRST one is where the
# instance is launched; the others are only recorded for later use (a load
# balancer or a second node needs two Availability Zones).
# These should be PRIVATE subnets: no route to an internet gateway.
export EXISTING_SUBNET_IDS="subnet-CHANGEME1 subnet-CHANGEME2"

# Optional. Leave empty to look the subnets up by tag instead of listing IDs.
#   export SUBNET_TAG_KEY="Tier"
#   export SUBNET_TAG_VALUE="private"
export SUBNET_TAG_KEY=""
export SUBNET_TAG_VALUE=""

# ==========================================================================
# 2. THE EXISTING HOSTED ZONE  -- this is how people reach NiFi
# ==========================================================================

# Give EITHER the zone id OR the zone name. The id wins if both are set.
export HOSTED_ZONE_ID=""                      # e.g. Z0123456789ABCDEFGHIJ
export HOSTED_ZONE_NAME="internal.example.com" # with or without a trailing dot

# The name people will type. Must sit inside the zone above.
export NIFI_DNS_NAME="nifi.internal.example.com"

# How long resolvers may cache the record. 60 seconds keeps failover quick
# and costs almost nothing at this volume.
export DNS_TTL="60"

# ==========================================================================
# 3. WHO MAY CONNECT
# ==========================================================================
# There is no public IP, so "your laptop's public IP" is meaningless here.
# List the internal ranges that should reach NiFi: your VPN pool, your office
# range, the VPC itself. Space separated.
export ALLOWED_CIDRS="10.0.0.0/8"

# Extra security groups allowed to reach NiFi (e.g. a shared load balancer
# the platform team already runs). Space separated group ids, or empty.
export ALLOWED_SOURCE_SGS=""

# ==========================================================================
# 4. HOW THE INSTANCE REACHES THE INTERNET (it may not!)
# ==========================================================================
# A private subnet often has no route out. The bootstrap needs to download
# ~1.2 GB of NiFi and some OS packages, so decide where they come from.
#
#   "internet"  - there is a NAT gateway; download from Apache directly
#   "s3"        - no NAT; download from a bucket you control, reached through
#                 an S3 gateway VPC endpoint (also how dnf reaches the
#                 Amazon Linux repositories)
export NIFI_SOURCE_MODE="internet"

# Used when NIFI_SOURCE_MODE="s3". Upload the zip and its .sha512 first:
#   aws s3 cp nifi-1.28.1-bin.zip        s3://my-bucket/nifi/
#   aws s3 cp nifi-1.28.1-bin.zip.sha512 s3://my-bucket/nifi/
export NIFI_S3_PREFIX="s3://my-artifacts-bucket/nifi"

# ==========================================================================
# 5. THE INSTANCE
# ==========================================================================
export EX_INSTANCE_TYPE="t3.large"
export EX_ROOT_VOLUME_GB="40"
export EX_SG_NAME="${PROJECT}-private-sg"
export EX_NAME="${PROJECT}-private"

# Reuse an IAM instance profile your account already has? Put its name here
# and no IAM objects will be created (useful when you cannot create roles).
export EXISTING_INSTANCE_PROFILE=""

# An existing KMS key for the EBS volume, if your account requires one.
export EBS_KMS_KEY_ID=""

# SSH is off by default: with no public IP there is no reason for it, and
# SSM Session Manager works better. Set a key name to turn it back on.
export EX_KEY_NAME=""

# ==========================================================================
# 6. CERTIFICATE
# ==========================================================================
# NiFi normally generates a self-signed certificate naming the machine's own
# hostname, which does not match NIFI_DNS_NAME and makes browsers complain
# twice as loudly. "true" generates one that names the DNS record instead.
# Still self-signed - still one warning - but the name is right.
export GENERATE_CERT_FOR_DNS="true"
