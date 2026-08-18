#!/usr/bin/env bash
# Step 2: build the Java and C++ Jenkins agent images and push them to the registry.
source "$(dirname "$0")/lib.sh"
need docker

build_push() {
  local name="$1" dir="$2"
  log "building ${REGISTRY_HOST}/${name}:latest"
  docker build -t "${REGISTRY_HOST}/${name}:latest" "${dir}"
  log "pushing ${REGISTRY_HOST}/${name}:latest"
  docker push "${REGISTRY_HOST}/${name}:latest"
}

build_push agent-java "${ROOT_DIR}/agents/java"
build_push agent-cpp  "${ROOT_DIR}/agents/cpp"

log "images available in the registry:"
curl -s "http://127.0.0.1:${REG_PORT}/v2/_catalog" || true
echo
