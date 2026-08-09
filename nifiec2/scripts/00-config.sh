#!/usr/bin/env bash
# ==========================================================================
# 00-config.sh  --  ALL settings live here. Edit this file, nothing else.
# This file is "sourced" (loaded) by every other script. Do not run it alone.
# ==========================================================================

# ---------- AWS placement ----------
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PROFILE="${AWS_PROFILE:-default}"

# ---------- Naming (everything gets this prefix so cleanup is easy) ----------
export PROJECT="nifi-demo"
export TAG_KEY="Project"
export TAG_VALUE="$PROJECT"

# ---------- NiFi ----------
# 1.28.1 is the FINAL release of the NiFi 1.x line (Nov 2024).
# Use 1.28.0 only if you have a specific reason.
export NIFI_VERSION="1.28.1"
export NIFI_MIRROR="https://archive.apache.org/dist/nifi"
# NiFi 1.x officially supports Java 8 and Java 11 ONLY. Do not use 17/21 here.
export JAVA_PKG="java-11-amazon-corretto-headless"
export NIFI_HEAP="2g"            # -Xms and -Xmx. Keep <= ~50% of instance RAM.
export NIFI_HTTPS_PORT="8443"

# Single-user login created on first boot.
# Password MUST be 12+ characters or NiFi refuses it.
export NIFI_USERNAME="admin"
export NIFI_PASSWORD="ChangeMe-Str0ngPass!"   # <-- CHANGE THIS

# ---------- EC2 ----------
# t3.large = 2 vCPU / 8 GB RAM. This is a sane minimum for real NiFi work.
export INSTANCE_TYPE="t3.large"
export ROOT_VOLUME_GB="40"        # NiFi zip alone is ~1.2 GB; repos grow fast.
export VOLUME_TYPE="gp3"
export KEY_NAME="${PROJECT}-key"
export KEY_FILE="${HOME}/.ssh/${KEY_NAME}.pem"
export SG_NAME="${PROJECT}-sg"
export IAM_ROLE_NAME="${PROJECT}-role"
export INSTANCE_PROFILE_NAME="${PROJECT}-instance-profile"

# ---------- Access control ----------
# true  = open port 22 to your IP as a backup way in
# false = SSM Session Manager only (more secure, recommended)
export ENABLE_SSH="true"
# true = give the box a fixed public IP that survives stop/start
export ALLOCATE_EIP="false"

# ---------- Networking ----------
# 02-network.sh BUILDS a dedicated VPC with its own subnets, and
# 99-teardown.sh deletes every piece of it. Nothing is shared with the
# account's default VPC, so a mistake here cannot damage anything else.
export VPC_CIDR="10.20.0.0/16"

# Two PUBLIC subnets in two different Availability Zones. NiFi runs in the
# first one; the second exists because almost everything you might add later
# (an Application Load Balancer, an RDS subnet group) requires two AZs.
export PUBLIC_SUBNET_CIDRS="10.20.1.0/24 10.20.2.0/24"

# Two PRIVATE subnets: no route to the internet. Good place for future
# cluster nodes or a database. Set to "" to skip creating them.
export PRIVATE_SUBNET_CIDRS="10.20.11.0/24 10.20.12.0/24"

# true = reuse the account's default VPC instead of building one.
# Teardown then leaves the VPC alone (it is not ours to delete).
export REUSE_DEFAULT_VPC="false"

# ---------- Internal ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export STATE_FILE="${SCRIPT_DIR}/.deploy-state"
export BUILD_DIR="${SCRIPT_DIR}/build"

# Save a key=value pair to the state file so later scripts can find resources.
save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  grep -v "^export ${1}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "export ${1}=\"${2}\"" >> "$STATE_FILE"
  export "${1}=${2}"
}

# Load previously saved resource IDs, if any.
load_state() {
  # shellcheck disable=SC1090
  [ -f "$STATE_FILE" ] && source "$STATE_FILE"
  return 0
}

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  XX\033[0m %s\n' "$*" >&2; exit 1; }

export AWS_PAGER=""   # stop the AWS CLI from opening "less" on every command
