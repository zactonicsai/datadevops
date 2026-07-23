#!/usr/bin/env bash
# =============================================================================
# scripts/lib.sh   --   SHARED FUNCTIONS FOR EVERY SCRIPT
# =============================================================================
# This file is not run directly. The other scripts "source" it, which means
# "read this file and treat its contents as if typed here". It is the shell
# equivalent of an import.
#
# Keeping shared logic in one place means a fix to the logging format or the
# prerequisite checks applies everywhere at once.
# =============================================================================

# -----------------------------------------------------------------------------
# STRICT MODE -- the three settings every serious bash script should have
# -----------------------------------------------------------------------------
#   -e  exit immediately if any command fails. Without it, a script carries on
#       after an error and does more damage on top of a broken state.
#   -u  treat an unset variable as an error. Catches typos: without it,
#       `rm -rf "$DIR/"` with DIR unset becomes `rm -rf /`.
#   -o pipefail  make a pipeline fail if ANY stage fails, not just the last.
#       Without it, `terraform apply | tee log` reports success whenever tee
#       succeeds -- even if terraform failed. That is exactly our situation.
set -euo pipefail

# -----------------------------------------------------------------------------
# PATHS
# -----------------------------------------------------------------------------
# Work out where this script lives, regardless of where it was called from.
# The BASH_SOURCE[0] / cd / pwd dance is the portable idiom for this; using
# $0 breaks when the script is sourced rather than executed.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$LIB_DIR/.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"

mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# THE LAYER LIST -- the single source of truth for ordering
# -----------------------------------------------------------------------------
# Apply runs top to bottom. Destroy runs bottom to top.
#
# The order is not arbitrary; each layer reads the state file of the one
# before it:
#   00 network      -> nothing
#   01 cluster      -> needs the VPC and subnets
#   02 addons       -> needs a cluster to install into
#   03 keda         -> needs metrics-server for CPU scaling to work
#   04 webapp       -> needs KEDA's CRDs to exist before it can PLAN
#   05 strimzi      -> needs a cluster
#   06 kafka        -> needs Strimzi's CRDs to exist before it can PLAN
#   07 nifi         -> reads Kafka's bootstrap address
#   08 toolbox      -> reads addresses from 04, 06 and 07
LAYERS=(
  "00-network"
  "01-cluster"
  "02-addons"
  "03-keda"
  "04-webapp"
  "05-strimzi-operator"
  "06-kafka-cluster"
  "07-nifi"
  "08-toolbox"
)

# -----------------------------------------------------------------------------
# COLOURS
# -----------------------------------------------------------------------------
# Only emit colour codes when writing to a terminal. `[ -t 1 ]` tests whether
# file descriptor 1 (stdout) is a TTY. Without this check, redirecting output
# to a log file fills it with escape sequences that make it hard to read.
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

# -----------------------------------------------------------------------------
# LOGGING FUNCTIONS
# -----------------------------------------------------------------------------
# Every message carries a timestamp. When you come back to a log three days
# later trying to work out why an apply took 40 minutes, timestamps are the
# difference between an answer and a shrug.

_timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
  echo "${C_BLUE}[$(_timestamp)] INFO ${C_RESET} $*"
}

log_ok() {
  echo "${C_GREEN}[$(_timestamp)] OK   ${C_RESET} $*"
}

log_warn() {
  echo "${C_YELLOW}[$(_timestamp)] WARN ${C_RESET} $*"
}

log_error() {
  # Errors go to stderr (>&2) so they survive when stdout is piped elsewhere,
  # and so they show up in a terminal even when output is redirected.
  echo "${C_RED}[$(_timestamp)] ERROR${C_RESET} $*" >&2
}

log_header() {
  echo ""
  echo "${C_BOLD}================================================================${C_RESET}"
  echo "${C_BOLD}  $*${C_RESET}"
  echo "${C_BOLD}================================================================${C_RESET}"
}

# -----------------------------------------------------------------------------
# PREREQUISITE CHECKS
# -----------------------------------------------------------------------------
# Failing fast with a clear message beats failing 20 minutes in with something
# cryptic. Checking up front is cheap and saves real frustration.

require_command() {
  local cmd="$1"
  local hint="${2:-}"

  # `command -v` is the portable way to ask "does this exist on PATH".
  # `which` is not standardised and behaves differently across systems.
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    [ -n "$hint" ] && log_error "  $hint"
    return 1
  fi
  return 0
}

check_prerequisites() {
  log_info "Checking prerequisites..."
  local failed=0

  require_command terraform "Install from https://developer.hashicorp.com/terraform/downloads" || failed=1
  require_command aws        "Install AWS CLI v2: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" || failed=1
  require_command kubectl    "Install from https://kubernetes.io/docs/tasks/tools/" || failed=1
  require_command jq         "Install with: brew install jq   OR   apt-get install jq" || failed=1

  if [ "$failed" -ne 0 ]; then
    log_error "Missing prerequisites. Install them and try again."
    return 1
  fi

  # ---- Verify AWS credentials actually work ----
  # Having the CLI installed is not the same as being logged in. This calls a
  # harmless read-only API to confirm we have a working identity.
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS credentials are not working."
    log_error "  Run 'aws configure' or set AWS_PROFILE / AWS_ACCESS_KEY_ID."
    log_error "  Verify with: aws sts get-caller-identity"
    return 1
  fi

  local account_id
  account_id="$(aws sts get-caller-identity --query Account --output text)"
  local caller_arn
  caller_arn="$(aws sts get-caller-identity --query Arn --output text)"

  log_ok "AWS account: $account_id"
  log_ok "Identity:    $caller_arn"

  # ---- Check the tfvars file exists ----
  if [ ! -f "$PROJECT_ROOT/common.auto.tfvars" ]; then
    log_warn "common.auto.tfvars not found; defaults will be used."
    log_warn "  Create it with:"
    log_warn "    cp common.auto.tfvars.example common.auto.tfvars"
  fi

  log_ok "Prerequisites satisfied."
  return 0
}

# -----------------------------------------------------------------------------
# COPY SHARED FILES INTO EACH LAYER
# -----------------------------------------------------------------------------
# Terraform has no include mechanism, so shared declarations must physically
# exist in every layer directory. We copy rather than symlink because symlinks
# do not survive zip archives or Windows checkouts reliably.
sync_shared_files() {
  log_info "Syncing shared files into each layer..."

  for layer in "${LAYERS[@]}"; do
    cp "$PROJECT_ROOT/common-variables.tf" "$PROJECT_ROOT/$layer/common-variables.tf"

    # The tfvars file is optional; only copy it if the user made one.
    if [ -f "$PROJECT_ROOT/common.auto.tfvars" ]; then
      cp "$PROJECT_ROOT/common.auto.tfvars" "$PROJECT_ROOT/$layer/common.auto.tfvars"
    fi
  done

  log_ok "Shared files synced to ${#LAYERS[@]} layers."
}

# -----------------------------------------------------------------------------
# RUN A TERRAFORM COMMAND IN ONE LAYER, WITH FULL LOGGING
# -----------------------------------------------------------------------------
# Usage: run_terraform <layer-dir> <action> [extra args...]
#
# Every invocation writes its own timestamped log file, so a failed run three
# layers ago is still available for inspection.
run_terraform() {
  local layer="$1"
  local action="$2"
  shift 2

  local layer_dir="$PROJECT_ROOT/$layer"
  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  local logfile="$LOG_DIR/${layer}_${action}_${stamp}.log"

  if [ ! -d "$layer_dir" ]; then
    log_error "Layer directory not found: $layer_dir"
    return 1
  fi

  log_header "$layer :: terraform $action"
  log_info "Logging to $logfile"

  # A subshell (the parentheses) so the `cd` does not leak into the caller's
  # working directory.
  (
    cd "$layer_dir"

    # ---- terraform init ----
    # Safe to run every time. -input=false stops it prompting, which would
    # hang a script. -upgrade re-resolves providers within their pinned range.
    echo "=== terraform init ($(_timestamp)) ==="
    terraform init -input=false -upgrade

    echo ""
    echo "=== terraform $action ($(_timestamp)) ==="
    terraform "$action" -input=false "$@"

  # `2>&1` merges stderr into stdout so errors land in the log too.
  # `tee` writes to the file AND the terminal, so you watch progress live and
  # keep a permanent record. This is why `pipefail` at the top matters: without
  # it, tee's success would mask terraform's failure.
  ) 2>&1 | tee "$logfile"

  # PIPESTATUS is a bash array holding the exit code of each pipeline stage.
  # [0] is the subshell (terraform); [1] would be tee. We want terraform's.
  local rc="${PIPESTATUS[0]}"

  if [ "$rc" -ne 0 ]; then
    log_error "$layer :: terraform $action FAILED (exit $rc)"
    log_error "Full log: $logfile"
    return "$rc"
  fi

  log_ok "$layer :: terraform $action completed."
  return 0
}

# -----------------------------------------------------------------------------
# CONFIGURE kubectl FOR THE CLUSTER
# -----------------------------------------------------------------------------
configure_kubectl() {
  local cluster_dir="$PROJECT_ROOT/01-cluster"

  if [ ! -f "$cluster_dir/terraform.tfstate" ]; then
    log_warn "Cluster state not found; skipping kubectl configuration."
    return 0
  fi

  local cluster_name region
  # `terraform output -raw` prints the bare value with no quotes or newline,
  # which is what you want when capturing into a variable.
  # The `|| echo ""` guards against the output not existing yet.
  cluster_name="$(cd "$cluster_dir" && terraform output -raw cluster_name 2>/dev/null || echo "")"
  region="$(cd "$cluster_dir" && terraform output -raw aws_region 2>/dev/null || echo "")"

  if [ -z "$cluster_name" ] || [ -z "$region" ]; then
    log_warn "Could not read cluster name or region from state; skipping kubectl setup."
    return 0
  fi

  log_info "Configuring kubectl for cluster '$cluster_name' in $region..."

  # This writes a context into ~/.kube/config so kubectl knows how to
  # authenticate. It is safe to run repeatedly.
  aws eks update-kubeconfig --region "$region" --name "$cluster_name" >/dev/null

  log_ok "kubectl configured. Verify with: kubectl get nodes"
}
