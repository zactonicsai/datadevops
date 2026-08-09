#!/usr/bin/env bash
# ==========================================================================
# 99-kc-teardown.sh -- Remove Keycloak.
#
#   ./99-kc-teardown.sh --dry-run       show the plan only
#   ./99-kc-teardown.sh                 interactive
#   ./99-kc-teardown.sh --yes           unattended
#   ./99-kc-teardown.sh --keep-nifi-oidc  do NOT restore NiFi's old login
#
# IMPORTANT: by default this restores NiFi to its original username-and-
# password login FIRST. If you delete Keycloak while NiFi still points at
# it, nobody can log in to NiFi at all - the login page would redirect to a
# server that no longer exists.
#
# Order (same principle as the main teardown - outside in):
#   1. NiFi back to single-user auth   (before its identity provider vanishes)
#   2. Keycloak instance               (frees the network interface)
#   3. Elastic IP                      (billed hourly even when unattached)
#   4. Keycloak security group         (it also unblocks VPC deletion later)
#   5. Local state and build files     (they hold passwords)
# ==========================================================================
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-kc-config.sh"
load_nifi_state
load_state

DRY_RUN=false; ASSUME_YES=false; RESTORE_NIFI=true
for arg in "$@"; do
  case "$arg" in
    --dry-run)            DRY_RUN=true ;;
    --yes|-y)             ASSUME_YES=true ;;
    --keep-nifi-oidc)     RESTORE_NIFI=false ;;
    *) die "Unknown option: $arg" ;;
  esac
done

exec 3>&1
RUN() { if $DRY_RUN; then printf '    \033[2m$ %s\033[0m\n' "$*" >&3; else "$@"; fi; }
A=(aws --region "$AWS_REGION")

# Discover by tag if the state file is gone.
[ -n "${KC_INSTANCE_ID:-}" ] || KC_INSTANCE_ID="$("${A[@]}" ec2 describe-instances \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=tag:Component,Values=keycloak" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' ' ')"
[ -n "${KC_SG_ID:-}" ] || KC_SG_ID="$("${A[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=${KC_SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)"
[ "${KC_SG_ID:-}" = "None" ] && KC_SG_ID=""
[ -n "${KC_ALLOC_ID:-}" ] || KC_ALLOC_ID="$("${A[@]}" ec2 describe-addresses \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=tag:Component,Values=keycloak" \
  --query 'Addresses[].AllocationId' --output text 2>/dev/null | tr '\t' ' ')"

cat <<PLAN

  ┌──────────────────────────────────────────────────────────────┐
  │  KEYCLOAK TEARDOWN — region ${AWS_REGION}
  ├──────────────────────────────────────────────────────────────┤
  │  1. Restore NiFi login : $($RESTORE_NIFI && echo "YES (runs ./04-nifi-restore.sh)" || echo "NO (--keep-nifi-oidc)")
  │  2. Instance           : ${KC_INSTANCE_ID:-<none>}
  │  3. Elastic IP         : ${KC_ALLOC_ID:-<none>}
  │  4. Security group     : ${KC_SG_ID:-<none>}
  │  5. Local files        : ${STATE_FILE}, ${BUILD_DIR}
  └──────────────────────────────────────────────────────────────┘

PLAN

if $RESTORE_NIFI; then
  echo "  NiFi will go back to:  ${NIFI_USERNAME} / (NIFI_PASSWORD from ../scripts/00-config.sh)"
else
  warn "NiFi will keep pointing at a Keycloak that is about to disappear."
  warn "Nobody will be able to log in until you run ./04-nifi-restore.sh."
fi
echo

if $DRY_RUN; then
  warn "DRY RUN — nothing will change."
elif ! $ASSUME_YES; then
  read -r -p "  Type 'delete' to continue: " ANSWER
  [ "$ANSWER" = "delete" ] || die "Aborted."
fi

# --------------------------------------------------------------------------
# 1. NiFi first, while Keycloak is still alive
# --------------------------------------------------------------------------
if $RESTORE_NIFI && [ "${OIDC_APPLIED:-false}" = "true" ]; then
  log "STEP 1/5  Restoring NiFi's original login..."
  if $DRY_RUN; then
    RUN ./04-nifi-restore.sh
  else
    if printf 'restore\n' | "${KC_DIR}/04-nifi-restore.sh"; then
      ok "NiFi restored"
    else
      warn "The restore did not finish cleanly. Stopping here so Keycloak stays up."
      warn "Fix it, or run ./04-nifi-restore.sh --list to pick a backup, then re-run this."
      exit 1
    fi
  fi
else
  ok "STEP 1/5  NiFi restore skipped"
fi

# --------------------------------------------------------------------------
# 2. Instance
# --------------------------------------------------------------------------
if [ -n "${KC_INSTANCE_ID:-}" ]; then
  log "STEP 2/5  Terminating ${KC_INSTANCE_ID}"
  # shellcheck disable=SC2086
  RUN "${A[@]}" ec2 terminate-instances --instance-ids $KC_INSTANCE_ID >/dev/null 2>&1
  if ! $DRY_RUN; then
    log "          Waiting for termination..."
    # shellcheck disable=SC2086
    "${A[@]}" ec2 wait instance-terminated --instance-ids $KC_INSTANCE_ID 2>/dev/null
    ok "Terminated"
  fi
else
  ok "STEP 2/5  No Keycloak instance"
fi

# --------------------------------------------------------------------------
# 3. Elastic IP
# --------------------------------------------------------------------------
if [ -n "${KC_ALLOC_ID:-}" ]; then
  log "STEP 3/5  Releasing Elastic IP ${KC_ALLOC_ID}"
  for a in $KC_ALLOC_ID; do
    ASSOC="$("${A[@]}" ec2 describe-addresses --allocation-ids "$a" \
      --query 'Addresses[0].AssociationId' --output text 2>/dev/null)"
    [ -n "$ASSOC" ] && [ "$ASSOC" != "None" ] && \
      RUN "${A[@]}" ec2 disassociate-address --association-id "$ASSOC" >/dev/null 2>&1
    RUN "${A[@]}" ec2 release-address --allocation-id "$a" >/dev/null 2>&1 && ok "Released $a"
  done
else
  ok "STEP 3/5  No Elastic IP"
fi

# --------------------------------------------------------------------------
# 4. Security group. The NiFi group references it, so retry while AWS
#    finishes detaching the network interface.
# --------------------------------------------------------------------------
if [ -n "${KC_SG_ID:-}" ]; then
  log "STEP 4/5  Deleting security group ${KC_SG_ID}"
  if $DRY_RUN; then
    RUN "${A[@]}" ec2 delete-security-group --group-id "$KC_SG_ID"
  else
    DEL=false
    for attempt in $(seq 1 12); do
      "${A[@]}" ec2 delete-security-group --group-id "$KC_SG_ID" 2>/dev/null && { DEL=true; break; }
      printf '\r          attempt %02d/12 - still in use, waiting 10s...' "$attempt"
      sleep 10
    done
    echo
    $DEL && ok "Deleted" || warn "Could not delete ${KC_SG_ID} - the main ../scripts/99-teardown.sh will retry it."
  fi
else
  ok "STEP 4/5  No security group"
fi

# --------------------------------------------------------------------------
# 5. Local files (they contain the admin password and the client secret)
# --------------------------------------------------------------------------
log "STEP 5/5  Local cleanup"
RUN rm -f "$STATE_FILE"
RUN rm -rf "$BUILD_DIR"
ok "Removed .kc-state and build/"

if $DRY_RUN; then
  echo; log "Dry run complete."
  exit 0
fi

echo
log "VERIFY"
LEFT="$("${A[@]}" ec2 describe-instances \
  --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=tag:Component,Values=keycloak" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | xargs)"
[ -z "$LEFT" ] && ok "No Keycloak instances remain" || warn "Still present: $LEFT"

echo
echo "  NiFi is untouched and still running at https://${NIFI_PUBLIC_IP}:${NIFI_HTTPS_PORT}/nifi"
echo "  To remove NiFi and the whole VPC as well:  cd ../scripts && ./99-teardown.sh"
