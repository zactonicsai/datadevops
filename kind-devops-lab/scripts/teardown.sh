#!/usr/bin/env bash
# Delete everything this lab created.
source "$(dirname "$0")/lib.sh"
log "deleting cluster ${CLUSTER_NAME}"
kind delete cluster --name "${CLUSTER_NAME}" || true
if [ "${KEEP_REGISTRY:-0}" != "1" ]; then
  log "removing the registry container"
  docker rm -f "${REG_NAME}" >/dev/null 2>&1 || true
fi
docker network rm kind >/dev/null 2>&1 || true
log "clean"
