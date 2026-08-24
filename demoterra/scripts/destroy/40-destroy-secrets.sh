#!/usr/bin/env bash
# TEARDOWN 4/6 - Secrets Manager.
# Deletes with a recovery window by default, so a mistake is reversible.
#   IMMEDIATE=1 forces permanent deletion.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "TEARDOWN 4/6 - SECRETS"
banner_env

RECOVERY_DAYS="${RECOVERY_DAYS:-7}"
IMMEDIATE="${IMMEDIATE:-0}"

ARNS="$(find_secret_arns)"
[[ -n "${ARNS}" ]] || { warn "no secrets under ${NAME_PREFIX}/"; exit 0; }

for arn in ${ARNS}; do
  name="$(aws secretsmanager describe-secret --secret-id "${arn}" --query Name --output text)"

  # Replicas must be removed before the primary can be deleted.
  REPLICAS="$(aws secretsmanager describe-secret --secret-id "${arn}" \
    --query 'ReplicationStatus[].Region' --output text 2>/dev/null || true)"
  if [[ -n "${REPLICAS}" && "${REPLICAS}" != "None" ]]; then
    run_soft aws secretsmanager remove-regions-from-replication --secret-id "${arn}" --remove-replica-regions ${REPLICAS}
  fi

  if [[ "${IMMEDIATE}" == "1" ]]; then
    warn "permanently deleting ${name} - unrecoverable"
    run_soft aws secretsmanager delete-secret --secret-id "${arn}" --force-delete-without-recovery
  else
    run_soft aws secretsmanager delete-secret --secret-id "${arn}" --recovery-window-in-days "${RECOVERY_DAYS}"
    log "${name} recoverable for ${RECOVERY_DAYS} days: aws secretsmanager restore-secret --secret-id ${arn}"
  fi
done

ok "secrets teardown complete"
