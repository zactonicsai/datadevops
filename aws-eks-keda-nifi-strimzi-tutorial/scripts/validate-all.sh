#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config
find_public_cidr

status=0
while IFS= read -r -d '' folder; do
  echo "Validating ${folder#${ROOT_DIR}/}"
  pushd "${folder}" >/dev/null
  terraform fmt -check -recursive || status=1
  terraform init -backend=false -upgrade >/dev/null
  terraform validate || status=1
  popd >/dev/null
done < <(find "${ROOT_DIR}/terraform" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

for script in "${ROOT_DIR}"/scripts/*.sh; do
  bash -n "${script}" || status=1
done

exit "${status}"
