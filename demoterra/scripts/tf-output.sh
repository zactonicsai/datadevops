#!/usr/bin/env bash
# Show stack outputs. Pass an output name for a single raw value.
#   ENV=dev ./scripts/tf-output.sh keycloak_url
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_cmd terraform
cd "${PROJECT_DIR}"

if [[ $# -gt 0 ]]; then
  terraform output -raw "$1"
else
  terraform output
fi
