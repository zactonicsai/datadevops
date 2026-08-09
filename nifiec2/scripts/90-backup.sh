#!/usr/bin/env bash
# ==========================================================================
# 90-backup.sh -- RUN THIS BEFORE YOU DESTROY ANYTHING.
#
# Terminating an instance deletes its disk. Your dataflow lives in
# conf/flow.json.gz -- lose that and you rebuild the flow by hand.
# This pulls the important config files down to your laptop.
#
#   ./90-backup.sh                 -> saves to ./backups/<timestamp>/
#   ./90-backup.sh s3://my-bucket  -> also uploads to S3
# ==========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-config.sh"
load_state
[ -n "${INSTANCE_ID:-}" ] || die "No instance in state file. Nothing to back up."

S3_DEST="${1:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${SCRIPT_DIR}/backups/${STAMP}"
mkdir -p "$DEST"

log "Asking the server to package its config..."
CMD_ID="$(aws ssm send-command --region "$AWS_REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=[
     "cd /opt/nifi/current",
     "tar czf /tmp/nifi-backup.tgz conf/flow.json.gz conf/flow.xml.gz conf/nifi.properties conf/bootstrap.conf conf/authorizers.xml conf/login-identity-providers.xml conf/users.xml conf/authorizations.xml 2>/dev/null || true",
     "base64 -w0 /tmp/nifi-backup.tgz",
     "rm -f /tmp/nifi-backup.tgz"
   ]' \
  --query 'Command.CommandId' --output text)"

for _ in $(seq 1 40); do
  sleep 3
  ST="$(aws ssm get-command-invocation --region "$AWS_REGION" \
        --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
        --query Status --output text 2>/dev/null || echo Pending)"
  [ "$ST" = "Success" ] && break
  case "$ST" in Failed|Cancelled|TimedOut) die "Backup command $ST" ;; esac
done

aws ssm get-command-invocation --region "$AWS_REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query StandardOutputContent --output text \
  | tr -d '\n' > "${DEST}/backup.b64"

# GNU base64 decodes with -d, BSD/macOS with -D. Try both, then fall back to
# openssl, which is present everywhere.
decode() {
  base64 -d  < "${DEST}/backup.b64" > "$1" 2>/dev/null && return 0
  base64 -D  < "${DEST}/backup.b64" > "$1" 2>/dev/null && return 0
  openssl base64 -d -A < "${DEST}/backup.b64" > "$1" 2>/dev/null && return 0
  return 1
}
decode "${DEST}/nifi-conf-backup.tgz" || die "Could not decode the backup payload."
rm -f "${DEST}/backup.b64"

[ -s "${DEST}/nifi-conf-backup.tgz" ] || die "Backup came back empty."
tar tzf "${DEST}/nifi-conf-backup.tgz" | sed 's/^/    /'
ok "Saved ${DEST}/nifi-conf-backup.tgz ($(du -h "${DEST}/nifi-conf-backup.tgz" | cut -f1))"

# Optional: an EBS snapshot keeps the ENTIRE disk, repositories included.
log "Taking an EBS snapshot of the root volume as well..."
VOL_ID="$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)"
SNAP_ID="$(aws ec2 create-snapshot --region "$AWS_REGION" --volume-id "$VOL_ID" \
  --description "${PROJECT} pre-teardown ${STAMP}" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${PROJECT}-${STAMP}},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
  --query SnapshotId --output text)"
save_state SNAPSHOT_ID "$SNAP_ID"
ok "Snapshot $SNAP_ID started (completes in the background, ~$0.05/GB-month)"

if [ -n "$S3_DEST" ]; then
  log "Uploading to $S3_DEST ..."
  aws s3 cp "${DEST}/nifi-conf-backup.tgz" "${S3_DEST%/}/nifi-conf-${STAMP}.tgz"
  ok "Uploaded"
fi

warn "The snapshot is NOT deleted by 99-teardown.sh unless you pass --snapshots."
log "Backup done. Safe to run ./99-teardown.sh"
