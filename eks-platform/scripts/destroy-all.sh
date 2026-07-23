#!/usr/bin/env bash
# =============================================================================
# scripts/destroy-all.sh   --   TEAR EVERYTHING DOWN, IN REVERSE ORDER
# =============================================================================
# READ THIS BEFORE RUNNING IT. This deletes infrastructure permanently.
#
# WHY REVERSE ORDER MATTERS
# You cannot delete a VPC that still contains a running EKS cluster; AWS
# refuses. You cannot cleanly delete a cluster that still has LoadBalancer
# services, because those left an AWS load balancer behind that holds network
# interfaces in your subnets. Destroying bottom-up removes dependents first.
#
# Getting this wrong produces the classic failure: "DependencyViolation: The
# vpc has dependencies and cannot be deleted", followed by an hour of clicking
# around the console hunting orphaned network interfaces.
#
# USAGE
#   ./scripts/destroy-all.sh              # destroy everything (prompts first)
#   ./scripts/destroy-all.sh --yes        # skip the confirmation prompt
#   ./scripts/destroy-all.sh 07-nifi      # destroy ONE layer only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

SKIP_CONFIRM=0
SINGLE_LAYER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) SKIP_CONFIRM=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) SINGLE_LAYER="$1"; shift ;;
  esac
done

log_header "EKS PLATFORM :: DESTROY"

# ---- Build the reversed layer list ----
REVERSED=()
for (( i=${#LAYERS[@]}-1 ; i>=0 ; i-- )); do
  REVERSED+=("${LAYERS[i]}")
done

TO_RUN=()
if [ -n "$SINGLE_LAYER" ]; then
  for l in "${LAYERS[@]}"; do
    if [ "$l" = "$SINGLE_LAYER" ] || [[ "$l" == "$SINGLE_LAYER"-* ]]; then
      TO_RUN=("$l"); break
    fi
  done
  [ ${#TO_RUN[@]} -eq 0 ] && { log_error "Unknown layer: $SINGLE_LAYER"; exit 1; }
else
  TO_RUN=("${REVERSED[@]}")
fi

# ---- Confirmation ----
if [ "$SKIP_CONFIRM" -eq 0 ]; then
  echo ""
  log_warn "This will PERMANENTLY DESTROY:"
  for l in "${TO_RUN[@]}"; do echo "    - $l"; done
  echo ""
  log_warn "All data in Kafka and NiFi will be lost."
  echo ""
  # -r stops backslashes being interpreted; -p prints the prompt.
  read -r -p "Type 'destroy' to confirm: " answer
  if [ "$answer" != "destroy" ]; then
    log_info "Cancelled. Nothing was changed."
    exit 0
  fi
fi

sync_shared_files

START_TIME=$(date +%s)
FAILED_LAYERS=()

for layer in "${TO_RUN[@]}"; do

  # Skip layers that were never applied. A missing state file means there is
  # nothing to destroy, and running terraform anyway just wastes time.
  if [ ! -f "$PROJECT_ROOT/$layer/terraform.tfstate" ]; then
    log_info "$layer :: no state file, skipping."
    continue
  fi

  # ---- Special handling before destroying the web app ----
  # LoadBalancer services create real AWS load balancers. Terraform deletes the
  # Kubernetes Service, but AWS takes a minute or two to finish tearing down
  # the NLB and release its network interfaces. Destroying the VPC too soon
  # after fails with DependencyViolation.
  if [ "$layer" = "04-webapp" ]; then
    log_info "Web app has a LoadBalancer; AWS needs time to release it."
  fi

  # NOTE: we do NOT use `|| true` here. If a destroy fails we want to know,
  # record it, and carry on to the other layers rather than stopping dead --
  # because a half-destroyed platform still costs money.
  if ! run_terraform "$layer" "destroy" -auto-approve; then
    log_error "$layer :: destroy FAILED. Continuing with remaining layers."
    FAILED_LAYERS+=("$layer")
  fi

  # Let AWS finish releasing load balancer network interfaces before we try to
  # remove the subnets they were attached to.
  if [ "$layer" = "04-webapp" ]; then
    log_info "Waiting 60s for AWS to release load balancer network interfaces..."
    sleep 60
  fi
done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

log_header "DESTROY FINISHED in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

if [ ${#FAILED_LAYERS[@]} -ne 0 ]; then
  log_error "These layers failed to destroy:"
  for l in "${FAILED_LAYERS[@]}"; do log_error "    - $l"; done
  log_error "Re-run this script, or destroy them individually."
fi

# -----------------------------------------------------------------------------
# ORPHAN CHECK -- the part people skip and then regret
# -----------------------------------------------------------------------------
# Some resources deliberately outlive `terraform destroy`:
#   - StatefulSet PVCs. Kubernetes keeps them on purpose so an accidental
#     delete does not destroy data. NiFi's volumes are in this category.
#   - Kafka PVCs when deleteClaim = false.
#   - Load balancers, if their Service was deleted outside Terraform.
#
# An orphaned 10 GiB EBS volume costs about $0.80/month. Ten of them across a
# few experiments is real money for something you cannot even see.
log_header "CHECKING FOR ORPHANED RESOURCES"

REGION="$(cd "$PROJECT_ROOT/00-network" 2>/dev/null && terraform output -raw aws_region 2>/dev/null || echo "")"
[ -z "$REGION" ] && REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

log_info "Looking for unattached EBS volumes in $REGION..."

# 'available' status means the volume exists but is attached to nothing.
ORPHANS="$(aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=status,Values=available" \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Created:CreateTime}' \
  --output text 2>/dev/null || echo "")"

if [ -n "$ORPHANS" ]; then
  log_warn "Unattached EBS volumes found (these still cost money):"
  echo "$ORPHANS"
  echo ""
  log_warn "Review them, then delete with:"
  log_warn "    aws ec2 delete-volume --region $REGION --volume-id vol-XXXXX"
  log_warn "CHECK CAREFULLY -- some may belong to other projects in this account."
else
  log_ok "No unattached EBS volumes found."
fi

log_info "Also worth checking manually:"
echo "    aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[].LoadBalancerName'"
echo "    aws ec2 describe-nat-gateways --region $REGION --filter Name=state,Values=available"
echo "    aws logs describe-log-groups --region $REGION --log-group-name-prefix /aws/eks"
