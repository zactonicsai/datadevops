#!/usr/bin/env bash
# Formatting and configuration validation.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
need_cmd terraform
cd "${PROJECT_DIR}"

header "terraform validate"
run terraform fmt -recursive -check -diff || die "run 'terraform fmt -recursive' to fix formatting"
run terraform validate
ok "configuration is valid"
