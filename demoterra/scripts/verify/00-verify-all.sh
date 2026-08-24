#!/usr/bin/env bash
# Run every area check in dependency order and report a single verdict.
#   ENV=prod ./scripts/verify/00-verify-all.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

header "FULL VERIFICATION - ${NAME_PREFIX}"
banner_env

FAILED_AREAS=()
for script in "${VERIFY_DIR}"/[1-9]0-verify-*.sh; do
  if ! ENVIRONMENT="${ENVIRONMENT}" bash "${script}"; then
    FAILED_AREAS+=("$(basename "${script}")")
  fi
done

header "SUMMARY"
if [[ ${#FAILED_AREAS[@]} -eq 0 ]]; then
  ok "all areas passed"
  exit 0
fi
err "areas with failures:"
printf '   - %s\n' "${FAILED_AREAS[@]}"
exit 1
