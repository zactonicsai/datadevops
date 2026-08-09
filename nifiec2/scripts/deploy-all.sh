#!/usr/bin/env bash
# ==========================================================================
# deploy-all.sh -- Runs the whole pipeline end to end.
# Use this once you have edited 00-config.sh (especially NIFI_PASSWORD).
# ==========================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

./01-preflight.sh
./02-network.sh
./03-launch.sh
./04-verify.sh --follow

echo
echo "Done. If the UI did not answer, run './04-verify.sh --logs' to see why."
