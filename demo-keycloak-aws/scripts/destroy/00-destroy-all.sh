#!/usr/bin/env bash
# Primary teardown path: back up, then terraform destroy, then confirm.
# Falls back to 99-destroy-cli-fallback.sh if Terraform cannot finish.
#
#   ENV=dev ./scripts/destroy/00-destroy-all.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_cmd terraform
cd "${PROJECT_DIR}"

header "DESTROY - ${NAME_PREFIX}"
banner_env

[[ "${ENVIRONMENT}" == "prod" && "${FORCE}" != "1" ]] && \
  warn "this is PRODUCTION - be certain"

# --- 1. Backup --------------------------------------------------------------
if [[ "${SKIP_BACKUP:-0}" == "1" ]]; then
  warn "SKIP_BACKUP=1 - proceeding with no backup"
else
  ENVIRONMENT="${ENVIRONMENT}" "${SCRIPTS_DIR}/backup/00-backup-all.sh" \
    || die "backup failed - refusing to destroy"
fi

confirm "Destroy the ${NAME_PREFIX} stack? Confirm by typing the stack prefix:"

# --- 2. Clear the protections Terraform cannot remove while destroying ------
log "disabling deletion protection"
ALB_ARN="$(find_alb_arn)"
[[ -n "${ALB_ARN}" ]] && run_soft aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn "${ALB_ARN}" --attributes Key=deletion_protection.enabled,Value=false

DB_ID="$(db_identifier)"
[[ -n "$(find_db_status)" ]] && run_soft aws rds modify-db-instance \
  --db-instance-identifier "${DB_ID}" --no-deletion-protection --apply-immediately

# --- 3. Drain the service so the ALB detaches cleanly ----------------------
run_soft aws ecs update-service --cluster "$(cluster_name)" --service "$(service_name)" --desired-count 0
[[ "${DRY_RUN}" == "1" ]] || run_soft aws ecs wait services-stable \
  --cluster "$(cluster_name)" --services "$(service_name)"

# --- 4. Terraform destroy ---------------------------------------------------
DESTROY_ARGS=(-var-file="${TFVARS_FILE}"
              -var="db_deletion_protection=false"
              -var="alb_deletion_protection=false")
[[ "${FORCE}" == "1" ]] && DESTROY_ARGS+=(-auto-approve)

if run terraform destroy "${DESTROY_ARGS[@]}"; then
  ok "terraform destroy completed"
else
  err "terraform destroy failed"
  warn "fall back to the ordered CLI teardown:"
  warn "  SKIP_BACKUP=1 ENV=${ENVIRONMENT} ./scripts/destroy/99-destroy-cli-fallback.sh"
  exit 1
fi

# --- 5. Confirm nothing is left --------------------------------------------
header "POST-DESTROY CHECK"
LEFT=0
[[ -n "$(find_vpc_id)" ]]        && { warn "VPC still present";  LEFT=1; }
[[ -n "$(find_alb_arn)" ]]       && { warn "ALB still present";  LEFT=1; }
[[ -n "$(find_db_status)" ]]     && { warn "RDS still present";  LEFT=1; }
[[ ${LEFT} -eq 0 ]] && ok "no stack resources remain" \
  || warn "leftovers found - run ./scripts/destroy/99-destroy-cli-fallback.sh"

log "secrets are retained for their recovery window; snapshots are retained indefinitely"
