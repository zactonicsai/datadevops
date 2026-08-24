#!/usr/bin/env bash
# AREA 3/7 - Secrets Manager: presence, shape, encryption, replication.
# Secret VALUES are never printed - only their keys.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

header "VERIFY 3/7 - SECRETS"

ARNS="$(find_secret_arns)"
[[ -n "${ARNS}" ]] || { check_fail "no secrets found under ${NAME_PREFIX}/"; check_summary; exit 1; }

for arn in ${ARNS}; do
  name="$(aws secretsmanager describe-secret --secret-id "${arn}" --query Name --output text)"
  check_pass "secret ${name}"

  aws secretsmanager describe-secret --secret-id "${arn}" \
    --query '{KmsKey:KmsKeyId,Rotation:RotationEnabled,Replicas:length(ReplicationStatus||`[]`),Deleted:DeletedDate}' \
    --output table

  KEYS="$(aws secretsmanager get-secret-value --secret-id "${arn}" \
          --query SecretString --output text | jq -r 'keys | join(", ")')"
  log "  keys: ${KEYS}"

  case "${name}" in
    */rds/*)
      jq -e 'has("username") and has("password") and has("host")' >/dev/null \
        <<< "$(aws secretsmanager get-secret-value --secret-id "${arn}" --query SecretString --output text)" \
        && check_pass "  database secret has the expected fields" \
        || check_fail "  database secret is missing fields" ;;
    */keycloak/*)
      jq -e 'has("username") and has("password")' >/dev/null \
        <<< "$(aws secretsmanager get-secret-value --secret-id "${arn}" --query SecretString --output text)" \
        && check_pass "  admin secret has the expected fields" \
        || check_fail "  admin secret is missing fields" ;;
  esac
done

check_summary
