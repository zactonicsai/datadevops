#!/usr/bin/env bash
# Shared settings + helpers for all scripts.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-devops-lab}"
NAMESPACE="${NAMESPACE:-devops}"
REG_NAME="${REG_NAME:-kind-registry}"
REG_PORT="${REG_PORT:-5001}"          # port on your laptop
REG_INTERNAL_PORT=5000                # port inside the registry container
REGISTRY_HOST="localhost:${REG_PORT}" # name baked into the image tags

GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-jenkins}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-jenkins123}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-jenkins@example.com}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

# Where do we reach the cluster's published ports from here?
# - from your laptop  -> localhost
# - from the toolbox  -> the control-plane container on the "kind" network
node_addr() {
  if [ "${IN_TOOLBOX:-0}" = "1" ]; then
    echo "${CLUSTER_NAME}-control-plane"
  else
    echo "localhost"
  fi
}
gitea_addr() {
  if [ "${IN_TOOLBOX:-0}" = "1" ]; then echo "$(node_addr):30300"; else echo "localhost:3000"; fi
}
jenkins_addr() {
  if [ "${IN_TOOLBOX:-0}" = "1" ]; then echo "$(node_addr):30808"; else echo "localhost:8080"; fi
}
