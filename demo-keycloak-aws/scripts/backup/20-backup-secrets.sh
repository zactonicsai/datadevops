#!/usr/bin/env bash
# BACKUP 2/4 - Secrets Manager contents.
#
# This writes plaintext credentials to disk. The file is chmod 600, but move it
# into a password manager or vault and delete it as soon as you are done.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

DEST="${BACKUP_DIR:-$(cat "${BACKUP_ROOT}/.last" 2>/dev/null || echo "${BACKUP_ROOT}/${NAME_PREFIX}-$(date -u +%Y%m%dT%H%M%SZ)")}"
mkdir -p "${DEST}"

header "BACKUP 2/4 - SECRETS"
warn "the output file contains plaintext credentials - handle accordingly"

OUT="${DEST}/secrets.json"
: > "${OUT}"; chmod 600 "${OUT}"

ARNS="$(find_secret_arns)"
[[ -n "${ARNS}" ]] || { warn "no secrets under ${NAME_PREFIX}/"; exit 0; }

{
  echo "{"
  first=1
  for arn in ${ARNS}; do
    name="$(aws secretsmanager describe-secret --secret-id "${arn}" --query Name --output text)"
    value="$(aws secretsmanager get-secret-value --secret-id "${arn}" --query SecretString --output text)"
    [[ ${first} -eq 0 ]] && echo ","
    printf '  %s: %s' "$(jq -Rn --arg n "${name}" '$n')" "$(jq -c . <<< "${value}")"
    first=0
  done
  echo
  echo "}"
} > "${OUT}"

jq -e . "${OUT}" >/dev/null && ok "secrets -> ${OUT} (mode 600)"
