#!/usr/bin/env bash
# =============================================================================
# 00-config.sh  —  Shared settings and helpers. SOURCE this, do not run it.
#
#   source ./00-config.sh
#
# Every other script sources this file, so all your settings live in ONE place.
# Change values here (or export them before running) to resize the lab.
# =============================================================================

# ---------- Identity of this lab -------------------------------------------
export LAB_NAME="${LAB_NAME:-ekslab}"        # prefix on every AWS resource name
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-${LAB_NAME}-eks}"

# ---------- Cost controls ---------------------------------------------------
# The three biggest knobs. Defaults are the cheapest thing that still teaches
# real patterns. See README section "What this costs".
export K8S_VERSION="${K8S_VERSION:-1.34}"
export NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.large}"   # 2 vCPU / 8 GiB
export NODE_CAPACITY_TYPE="${NODE_CAPACITY_TYPE:-SPOT}"       # ~70% cheaper
export NODE_DESIRED="${NODE_DESIRED:-2}"
export NODE_MIN="${NODE_MIN:-2}"
export NODE_MAX="${NODE_MAX:-3}"
export NODE_DISK_GB="${NODE_DISK_GB:-40}"

# USE_NAT=true  -> nodes in PRIVATE subnets behind a NAT gateway (best practice,
#                  costs ~$0.045/hr + data = roughly $33/month if left running)
# USE_NAT=false -> nodes in PUBLIC subnets with public IPs (saves the NAT cost;
#                  still firewalled by security groups, but the nodes are
#                  directly addressable. Fine for a throwaway lab, NOT for prod)
export USE_NAT="${USE_NAT:-true}"

# ---------- Network layout --------------------------------------------------
export VPC_CIDR="${VPC_CIDR:-10.42.0.0/16}"
export AZ_A="${AZ_A:-${AWS_REGION}a}"
export AZ_B="${AZ_B:-${AWS_REGION}b}"
export PUBLIC_CIDR_A="${PUBLIC_CIDR_A:-10.42.0.0/20}"
export PUBLIC_CIDR_B="${PUBLIC_CIDR_B:-10.42.16.0/20}"
export PRIVATE_CIDR_A="${PRIVATE_CIDR_A:-10.42.32.0/20}"
export PRIVATE_CIDR_B="${PRIVATE_CIDR_B:-10.42.48.0/20}"

# ---------- Application settings --------------------------------------------
export NS_APPS="${NS_APPS:-lab}"             # one namespace keeps the lab simple
export NS_MON="${NS_MON:-monitoring}"
export KAFKA_TOPIC="${KAFKA_TOPIC:-messages}"
export S3_BUCKET="${S3_BUCKET:-}"            # auto-generated in 08 if empty

# Images. Pinned on purpose: "latest" makes labs unreproducible.
export IMG_KEYCLOAK="${IMG_KEYCLOAK:-quay.io/keycloak/keycloak:26.7.1}"
export IMG_KAFKA="${IMG_KAFKA:-apache/kafka:3.9.0}"
export IMG_NIFI="${IMG_NIFI:-apache/nifi:2.11.0}"
export IMG_PYTHON="${IMG_PYTHON:-python:3.12-slim}"

# ---------- State file ------------------------------------------------------
# Scripts write IDs here so the next script can read them. This is the
# poor-man's version of a Terraform state file, and seeing it makes the
# Terraform version much easier to understand later.
export STATE_FILE="${STATE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.lab-state}"
touch "$STATE_FILE"
# shellcheck disable=SC1090
source "$STATE_FILE"

# =============================================================================
# Helpers
# =============================================================================

# Colours (disabled if not a terminal)
if [ -t 1 ]; then
  C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'
  C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_OFF=""
fi

log()   { echo "${C_INFO}==>${C_OFF} $*"; }
ok()    { echo "${C_OK}  ok${C_OFF} $*"; }
warn()  { echo "${C_WARN}  !!${C_OFF} $*"; }
die()   { echo "${C_ERR}ERROR:${C_OFF} $*" >&2; exit 1; }

# save KEY VALUE  -> writes to the state file AND exports it right now
save() {
  local key="$1" val="$2"
  [ -z "$val" ] && die "save(): refusing to save empty value for $key"
  # remove any previous line for this key, then append
  grep -v "^export ${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  echo "export ${key}=\"${val}\"" >> "$STATE_FILE"
  export "${key}=${val}"
  ok "${key} = ${val}"
}

# require VAR1 VAR2 ...  -> fail early with a helpful message
require() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      die "\$${v} is not set. Did you run the earlier scripts in order?
     State file: ${STATE_FILE}"
    fi
  done
}

# need_tool aws kubectl ...
need_tool() {
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is not installed or not on PATH"
  done
}

# tags for every resource — makes cleanup and cost tracking possible
lab_tags_cli() {   # for `aws ec2 create-tags --tags ...`
  echo "Key=Name,Value=${1} Key=Lab,Value=${LAB_NAME} Key=ManagedBy,Value=shell-script"
}

# Confirm before doing something expensive or destructive
confirm() {
  local msg="${1:-Continue?}"
  if [ "${ASSUME_YES:-false}" = "true" ]; then return 0; fi
  read -r -p "${msg} [y/N] " reply
  case "$reply" in [yY]*) return 0 ;; *) echo "Aborted."; exit 1 ;; esac
}

# Print what the script is about to do, so learners can follow along
banner() {
  echo
  echo "============================================================"
  echo " $*"
  echo "============================================================"
}
