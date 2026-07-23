#!/usr/bin/env bash
# =============================================================================
# scripts/apply-all.sh   --   BUILD THE WHOLE PLATFORM, IN ORDER
# =============================================================================
# Applies every layer from 00 to 08, stopping immediately if any fails.
#
# USAGE
#   ./scripts/apply-all.sh              # apply everything
#   ./scripts/apply-all.sh 04-webapp    # apply ONE layer only
#   ./scripts/apply-all.sh --from 05    # apply from layer 05 onwards
#   ./scripts/apply-all.sh --plan       # plan everything, change nothing
#
# TIMING: expect 25-40 minutes for a full build from scratch. The EKS control
# plane alone takes 10-15 minutes, and nothing can hurry it.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

ACTION="apply"
START_FROM=""
SINGLE_LAYER=""

# ---- Parse arguments ----
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)
      # Plan mode: show what WOULD change without changing it. Always worth
      # doing before a real apply on anything you care about.
      ACTION="plan"
      shift
      ;;
    --from)
      START_FROM="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0"   # print the usage block at the top of this file
      exit 0
      ;;
    *)
      SINGLE_LAYER="$1"
      shift
      ;;
  esac
done

# -auto-approve skips the "type yes to continue" prompt. Correct for a script;
# NOT something to do casually by hand in production.
EXTRA_ARGS=()
[ "$ACTION" = "apply" ] && EXTRA_ARGS=(-auto-approve)

log_header "EKS PLATFORM :: $ACTION"

check_prerequisites
sync_shared_files

# ---- Work out which layers to run ----
TO_RUN=()
if [ -n "$SINGLE_LAYER" ]; then
  # Accept either "04-webapp" or just "04".
  for l in "${LAYERS[@]}"; do
    if [ "$l" = "$SINGLE_LAYER" ] || [[ "$l" == "$SINGLE_LAYER"-* ]]; then
      TO_RUN=("$l")
      break
    fi
  done
  if [ ${#TO_RUN[@]} -eq 0 ]; then
    log_error "Unknown layer: $SINGLE_LAYER"
    log_error "Valid layers: ${LAYERS[*]}"
    exit 1
  fi
elif [ -n "$START_FROM" ]; then
  found_start=0
  for l in "${LAYERS[@]}"; do
    if [ "$found_start" -eq 0 ] && { [ "$l" = "$START_FROM" ] || [[ "$l" == "$START_FROM"-* ]]; }; then
      found_start=1
    fi
    [ "$found_start" -eq 1 ] && TO_RUN+=("$l")
  done
  if [ ${#TO_RUN[@]} -eq 0 ]; then
    log_error "Unknown starting layer: $START_FROM"
    exit 1
  fi
else
  TO_RUN=("${LAYERS[@]}")
fi

log_info "Will $ACTION: ${TO_RUN[*]}"

START_TIME=$(date +%s)

for layer in "${TO_RUN[@]}"; do

  if ! run_terraform "$layer" "$ACTION" "${EXTRA_ARGS[@]}"; then
    log_error "Stopped at $layer. Later layers were NOT run."
    log_error "Fix the problem, then resume with:"
    log_error "    ./scripts/apply-all.sh --from $layer"
    exit 1
  fi

  # Point kubectl at the cluster as soon as it exists, so later layers (and
  # you) can use it.
  if [ "$layer" = "01-cluster" ] && [ "$ACTION" = "apply" ]; then
    configure_kubectl
  fi

  # ---- Settle time between layers ----
  # Kubernetes is eventually consistent. A Helm release can report "deployed"
  # while its webhooks are still registering, and the next layer's plan then
  # fails against a schema that is a few seconds from existing.
  # A short pause is an unglamorous but effective guard against that race.
  if [ "$ACTION" = "apply" ]; then
    case "$layer" in
      03-keda|05-strimzi-operator)
        log_info "Pausing 20s for CRDs to register with the API server..."
        sleep 20
        ;;
    esac
  fi
done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

log_header "COMPLETE in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

if [ "$ACTION" = "apply" ]; then
  log_ok "Platform built. Next steps:"
  echo ""
  echo "  1. Check everything is running:"
  echo "       kubectl get pods -A"
  echo ""
  echo "  2. Run the verification suite:"
  echo "       ./tests/run-tests.sh"
  echo ""
  echo "  3. Open the web app (wait 2-3 min for DNS):"
  echo "       cd 04-webapp && terraform output -raw web_url"
  echo ""
  echo "  4. Open the NiFi UI:"
  echo "       kubectl port-forward -n nifi svc/nifi 8443:8443"
  echo "       cd 07-nifi && terraform output -raw nifi_password"
  echo ""
  log_warn "This platform costs roughly \$250-350/month while running."
  log_warn "Tear it down with: ./scripts/destroy-all.sh"
fi
