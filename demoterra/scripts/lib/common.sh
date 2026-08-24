#!/usr/bin/env bash
# Shared helpers for every script in this project.
# Sourced, never executed directly.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${LIB_DIR}/.." && pwd)"
PROJECT_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-${PROJECT_DIR}/.backups}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_OFF=''
fi

log()   { printf '%s[ .. ]%s %s\n' "${C_BLU}" "${C_OFF}" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "${C_GRN}" "${C_OFF}" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "${C_YLW}" "${C_OFF}" "$*" >&2; }
err()   { printf '%s[FAIL]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }
die()   { err "$*"; exit 1; }

header() {
  printf '\n%s==============================================================%s\n' "${C_BLD}" "${C_OFF}"
  printf '%s %s%s\n' "${C_BLD}" "$*" "${C_OFF}"
  printf '%s==============================================================%s\n' "${C_BLD}" "${C_OFF}"
}

# Counters used by the verify scripts.
CHECKS_PASSED=0
CHECKS_FAILED=0
check_pass() { CHECKS_PASSED=$((CHECKS_PASSED + 1)); ok "$*"; }
check_fail() { CHECKS_FAILED=$((CHECKS_FAILED + 1)); err "$*"; }

check_summary() {
  printf '\n  passed: %s%d%s   failed: %s%d%s\n' \
    "${C_GRN}" "${CHECKS_PASSED}" "${C_OFF}" "${C_RED}" "${CHECKS_FAILED}" "${C_OFF}"
  [[ ${CHECKS_FAILED} -eq 0 ]]
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
need_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}

need_cmd aws jq

# ---------------------------------------------------------------------------
# Environment resolution
#
# Values come from (highest precedence first):
#   1. exported environment variables
#   2. environments/<env>.tfvars
#   3. built-in defaults
# ---------------------------------------------------------------------------
ENVIRONMENT="${ENVIRONMENT:-${ENV:-dev}}"
TFVARS_FILE="${PROJECT_DIR}/environments/${ENVIRONMENT}.tfvars"

tfvar() {
  local key="$1" default="${2:-}"
  [[ -f "${TFVARS_FILE}" ]] || { printf '%s' "${default}"; return; }
  local v
  v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${TFVARS_FILE}" 2>/dev/null \
       | head -1 | cut -d= -f2- | tr -d ' "' || true)"
  printf '%s' "${v:-${default}}"
}

PROJECT_NAME="${PROJECT_NAME:-$(tfvar project_name keycloak)}"
AWS_REGION="${AWS_REGION:-$(tfvar aws_region us-east-1)}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION}"

NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"

# Every resource carries these tags, so the scripts can find things without
# any Terraform state at all - that is the point of the CLI fallback.
TAG_FILTER=(
  "Name=tag:Project,Values=${PROJECT_NAME}"
  "Name=tag:Environment,Values=${ENVIRONMENT}"
)

# ---------------------------------------------------------------------------
# Execution control
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"
FORCE="${FORCE:-0}"

# Print then run. With DRY_RUN=1, print only.
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '  %s[dry-run]%s %s\n' "${C_YLW}" "${C_OFF}" "$*"
    return 0
  fi
  printf '  %s$%s %s\n' "${C_BLU}" "${C_OFF}" "$*"
  "$@"
}

# Same as run, but a failure is logged and swallowed. Teardown must keep going
# when a resource is already gone.
run_soft() {
  run "$@" || warn "command failed (continuing): $*"
}

confirm() {
  local prompt="${1:-Proceed?}"
  [[ "${FORCE}" == "1" ]] && { warn "FORCE=1 - skipping confirmation"; return 0; }
  [[ "${DRY_RUN}" == "1" ]] && return 0
  printf '%s%s%s [type: %s] ' "${C_YLW}" "${prompt}" "${C_OFF}" "${NAME_PREFIX}"
  local answer; read -r answer
  [[ "${answer}" == "${NAME_PREFIX}" ]] || die "confirmation did not match - aborting"
}

banner_env() {
  printf '%sproject%s   %s\n' "${C_BLD}" "${C_OFF}" "${PROJECT_NAME}"
  printf '%senv%s       %s\n' "${C_BLD}" "${C_OFF}" "${ENVIRONMENT}"
  printf '%sregion%s    %s\n' "${C_BLD}" "${C_OFF}" "${AWS_REGION}"
  printf '%sprefix%s    %s\n' "${C_BLD}" "${C_OFF}" "${NAME_PREFIX}"
  printf '%saccount%s   %s\n' "${C_BLD}" "${C_OFF}" "$(aws_account_id)"
  [[ "${DRY_RUN}" == "1" ]] && printf '%smode%s      DRY RUN - nothing will change\n' "${C_BLD}" "${C_OFF}"
  echo
}

# ---------------------------------------------------------------------------
# Discovery - tag- and name-based, no Terraform state required
# ---------------------------------------------------------------------------
aws_account_id() { aws sts get-caller-identity --query Account --output text; }

find_vpc_id() {
  aws ec2 describe-vpcs --filters "${TAG_FILTER[@]}" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null | grep -v '^None$' || true
}

find_alb_arn() {
  aws elbv2 describe-load-balancers --names "${NAME_PREFIX}-alb" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null | grep -v '^None$' || true
}

find_target_group_arn() {
  aws elbv2 describe-target-groups --names "${NAME_PREFIX}-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null | grep -v '^None$' || true
}

asg_name()      { printf '%s-asg' "${NAME_PREFIX}"; }
db_identifier() { printf '%s-postgres' "${NAME_PREFIX}"; }

find_instance_ids() {
  aws ec2 describe-instances \
    --filters "${TAG_FILTER[@]}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true
}

find_db_status() {
  aws rds describe-db-instances --db-instance-identifier "$(db_identifier)" \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true
}

find_secret_arns() {
  aws secretsmanager list-secrets \
    --filters "Key=name,Values=${NAME_PREFIX}/" \
    --query 'SecretList[].ARN' --output text 2>/dev/null || true
}

find_sg_id() {
  # $1 = suffix, e.g. alb-sg / keycloak-sg / database-sg / vpce-sg
  aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${NAME_PREFIX}-$1" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true
}

subnet_ids_by_tier() {
  # $1 = public | private | database
  local vpc; vpc="$(find_vpc_id)"
  [[ -n "${vpc}" ]] || return 0
  aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${vpc}" "Name=tag:Tier,Values=$1" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || true
}

wait_for() {
  # wait_for <seconds> <interval> <description> <command...>
  local timeout="$1" interval="$2" desc="$3"; shift 3
  local elapsed=0
  log "waiting for ${desc} (timeout ${timeout}s)"
  while (( elapsed < timeout )); do
    if "$@" >/dev/null 2>&1; then ok "${desc}"; return 0; fi
    sleep "${interval}"; elapsed=$((elapsed + interval))
    printf '  ... %ds\n' "${elapsed}"
  done
  warn "timed out waiting for ${desc}"
  return 1
}
