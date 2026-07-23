#!/usr/bin/env bash
set -Eeuo pipefail

REQUIRED=(terraform aws kubectl helm curl jq)
missing=0

for command_name in "${REQUIRED[@]}"; do
  if command -v "${command_name}" >/dev/null 2>&1; then
    printf '%-12s %s\n' "${command_name}" "OK: $(command -v "${command_name}")"
  else
    printf '%-12s %s\n' "${command_name}" "MISSING"
    missing=1
  fi
done

if [[ "${missing}" -ne 0 ]]; then
  echo "Install the missing tools before continuing."
  exit 1
fi

terraform version | head -n 1
aws --version
kubectl version --client
helm version --short
aws sts get-caller-identity
