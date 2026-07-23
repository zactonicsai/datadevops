#!/usr/bin/env bash
###############################################################################
# 02-create-database.sh
#
# CLI equivalent of terraform/02-database.tf.
# Creates a PostgreSQL 18.3 RDS instance in the private subnets, generates a
# strong password, and stores it in AWS Secrets Manager.
#
# Run 01-create-network.sh first.
# Usage:  ./02-create-database.sh
#
# TIME WARNING: RDS takes 5-12 minutes to create. The script waits for it.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/keycloak-state.env"

[[ -f "$STATE_FILE" ]] || { echo "ERROR: $STATE_FILE not found. Run 01-create-network.sh first."; exit 1; }
# shellcheck source=/dev/null
source "$STATE_FILE"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------
DB_ENGINE_VERSION="${DB_ENGINE_VERSION:-18.3}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t4g.micro}"
DB_STORAGE_GB="${DB_STORAGE_GB:-20}"
DB_NAME="${DB_NAME:-keycloak}"
DB_USERNAME="${DB_USERNAME:-kcadmin}"
DB_BACKUP_DAYS="${DB_BACKUP_DAYS:-7}"
DB_MULTI_AZ="${DB_MULTI_AZ:-false}"

DB_IDENTIFIER="${PROJECT}-db-${SUFFIX}"
PARAM_GROUP="${PROJECT}-pg18-params-${SUFFIX}"
DB_SECRET_NAME="${PROJECT}/db-credentials-${SUFFIX}"

step() { echo ""; echo "=========================================================="; echo ">>> $*"; echo "=========================================================="; }
info() { echo "    $*"; }
save() { echo "export $1='$2'" >> "$STATE_FILE"; info "saved $1=$2"; }

# ---------------------------------------------------------------------------
# 1. Confirm the version really exists in this region
# ---------------------------------------------------------------------------
step "1/6  Checking that PostgreSQL $DB_ENGINE_VERSION is available here"
# Versions get retired. Asking AWS beats guessing and getting a cryptic error.

if ! aws rds describe-db-engine-versions \
      --engine postgres --engine-version "$DB_ENGINE_VERSION" \
      --query 'DBEngineVersions[0].EngineVersion' --output text 2>/dev/null | grep -q .; then
  echo "WARNING: $DB_ENGINE_VERSION not found. Available recent versions:"
  aws rds describe-db-engine-versions --engine postgres \
    --query 'DBEngineVersions[-10:].EngineVersion' --output table
  exit 1
fi
info "PostgreSQL $DB_ENGINE_VERSION confirmed available"

# ---------------------------------------------------------------------------
# 2. Generate the password
# ---------------------------------------------------------------------------
step "2/6  Generating a 32-character master password"
# RDS forbids these characters in a master password:  /  @  "  and spaces.
# We build our own alphabet rather than trusting a random generator to avoid them.

DB_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!#$%&*()_+=-' </dev/urandom | head -c 32)
info "Password generated (32 chars, never printed to the screen)"

# ---------------------------------------------------------------------------
# 3. Parameter group
# ---------------------------------------------------------------------------
step "3/6  Creating the DB parameter group"
# Parameter groups are the database's settings file. The single most
# valuable setting is rds.force_ssl=1: without it a client can connect in
# plaintext and never know. With it, PostgreSQL refuses unencrypted logins.

aws rds create-db-parameter-group \
  --db-parameter-group-name "$PARAM_GROUP" \
  --db-parameter-group-family "postgres18" \
  --description "Keycloak tuning for PostgreSQL 18" \
  --tags "Key=Project,Value=${PROJECT}" >/dev/null
save PARAM_GROUP "$PARAM_GROUP"

aws rds modify-db-parameter-group \
  --db-parameter-group-name "$PARAM_GROUP" \
  --parameters \
    "ParameterName=rds.force_ssl,ParameterValue=1,ApplyMethod=pending-reboot" \
    "ParameterName=log_min_duration_statement,ParameterValue=1000,ApplyMethod=immediate" \
    "ParameterName=max_connections,ParameterValue=150,ApplyMethod=pending-reboot" >/dev/null
info "Set rds.force_ssl=1, slow query log at 1000ms, max_connections=150"

# ---------------------------------------------------------------------------
# 4. Create the instance
# ---------------------------------------------------------------------------
step "4/6  Creating the RDS instance (this takes 5-12 minutes)"

aws rds create-db-instance \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --db-name "$DB_NAME" \
  --engine postgres \
  --engine-version "$DB_ENGINE_VERSION" \
  --db-instance-class "$DB_INSTANCE_CLASS" \
  --master-username "$DB_USERNAME" \
  --master-user-password "$DB_PASSWORD" \
  --allocated-storage "$DB_STORAGE_GB" \
  --max-allocated-storage "$((DB_STORAGE_GB * 5))" \
  --storage-type gp3 \
  --storage-encrypted \
  --db-subnet-group-name "$DB_SUBNET_GROUP" \
  --vpc-security-group-ids "$DB_SG_ID" \
  --db-parameter-group-name "$PARAM_GROUP" \
  --no-publicly-accessible \
  --backup-retention-period "$DB_BACKUP_DAYS" \
  --preferred-backup-window "07:00-08:00" \
  --preferred-maintenance-window "Mon:08:30-Mon:09:30" \
  --auto-minor-version-upgrade \
  --copy-tags-to-snapshot \
  --enable-performance-insights \
  --performance-insights-retention-period 7 \
  --enable-cloudwatch-logs-exports postgresql upgrade \
  --no-deletion-protection \
  $( [[ "$DB_MULTI_AZ" == "true" ]] && echo "--multi-az" || echo "--no-multi-az" ) \
  --tags "Key=Name,Value=${PROJECT}-db" "Key=Project,Value=${PROJECT}" >/dev/null

save DB_IDENTIFIER "$DB_IDENTIFIER"
info "Creation started. Waiting for status 'available'..."

# The waiter polls every 30 seconds, up to 60 times (30 minutes).
aws rds wait db-instance-available --db-instance-identifier "$DB_IDENTIFIER"
info "Database is available"

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
save DB_ENDPOINT "$DB_ENDPOINT"
save DB_NAME "$DB_NAME"
save DB_USERNAME "$DB_USERNAME"

# ---------------------------------------------------------------------------
# 5. Store credentials in Secrets Manager
# ---------------------------------------------------------------------------
step "5/6  Storing credentials in AWS Secrets Manager"
# Why not just bake the password into the server's config with a script?
# Because that leaves it in shell history, in cloud-init logs, and in any
# backup of the instance. Secrets Manager keeps it encrypted, audited in
# CloudTrail, and readable only by the IAM role we created in script 01.
#
# The name MUST start with "${PROJECT}/db-" or the IAM policy will not match.

SECRET_JSON=$(jq -n \
  --arg u "$DB_USERNAME" --arg p "$DB_PASSWORD" \
  --arg h "$DB_ENDPOINT" --arg d "$DB_NAME" \
  '{username:$u, password:$p, engine:"postgres", host:$h, port:5432, dbname:$d}')

DB_SECRET_ARN=$(aws secretsmanager create-secret \
  --name "$DB_SECRET_NAME" \
  --description "Keycloak RDS PostgreSQL master credentials" \
  --secret-string "$SECRET_JSON" \
  --tags "Key=Project,Value=${PROJECT}" \
  --query 'ARN' --output text)

save DB_SECRET_NAME "$DB_SECRET_NAME"
save DB_SECRET_ARN "$DB_SECRET_ARN"
unset DB_PASSWORD SECRET_JSON

# ---------------------------------------------------------------------------
# 6. Verify the security posture
# ---------------------------------------------------------------------------
step "6/6  Verifying the database is not reachable from the internet"

PUBLIC=$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].PubliclyAccessible' --output text)
ENCRYPTED=$(aws rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].StorageEncrypted' --output text)

info "PubliclyAccessible = $PUBLIC   (must be False)"
info "StorageEncrypted   = $ENCRYPTED   (must be True)"

[[ "$PUBLIC" == "False" ]] || { echo "FAIL: database is publicly accessible!"; exit 1; }

step "DATABASE COMPLETE"
cat <<SUMMARY

  Identifier .......... $DB_IDENTIFIER
  Endpoint ............ $DB_ENDPOINT
                        (private - resolves only inside the VPC)
  Engine .............. PostgreSQL $DB_ENGINE_VERSION
  Class ............... $DB_INSTANCE_CLASS
  Storage ............. ${DB_STORAGE_GB} GB gp3, encrypted
  Secret .............. $DB_SECRET_NAME

  Estimated cost of THIS script:
    db.t4g.micro on-demand ...... ~\$12.41/month
    20 GB gp3 storage ........... ~\$2.30/month
    Backups (7 days, <20GB) ..... \$0.00  (free up to 100% of storage)
    Secrets Manager (1 secret) .. ~\$0.40/month
    ----------------------------------------------
    Subtotal .................... ~\$15.11/month

  Next:  ./03-create-keycloak.sh

SUMMARY
