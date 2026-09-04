#!/usr/bin/env bash
# Run ONCE while online: downloads the pinned provider binaries into ./providers-mirror
# so that `terraform init` needs no network afterwards (see .terraformrc.example).
set -euo pipefail
cd "$(dirname "$0")/.."
terraform providers mirror -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64 ./providers-mirror
echo "Mirror written to $(pwd)/providers-mirror"
