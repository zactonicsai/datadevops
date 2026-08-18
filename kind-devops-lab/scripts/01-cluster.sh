#!/usr/bin/env bash
# Step 1: local image registry + kind cluster, wired together.
source "$(dirname "$0")/lib.sh"
need docker; need kind; need kubectl

log "making sure the docker network 'kind' exists"
docker network inspect kind >/dev/null 2>&1 || docker network create kind

log "starting the local registry (${REG_NAME}) on port ${REG_PORT}"
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != "true" ]; then
  docker run -d --restart=unless-stopped \
    --name "${REG_NAME}" --network kind \
    -p "127.0.0.1:${REG_PORT}:${REG_INTERNAL_PORT}" \
    registry:2
else
  log "registry already running"
fi
# make sure it is on the kind network even if it existed already
docker network connect kind "${REG_NAME}" 2>/dev/null || true

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  log "cluster '${CLUSTER_NAME}' already exists - skipping create"
else
  log "creating the kind cluster (this takes a minute or two)"
  kind create cluster --config "${ROOT_DIR}/kind/cluster.yaml" --name "${CLUSTER_NAME}"
fi

log "teaching every node that localhost:${REG_PORT} means the registry container"
REG_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" mkdir -p "${REG_DIR}"
  docker exec -i "${node}" cp /dev/stdin "${REG_DIR}/hosts.toml" <<HOSTS
[host."http://${REG_NAME}:${REG_INTERNAL_PORT}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
HOSTS
done

if [ "${IN_TOOLBOX:-0}" = "1" ]; then
  log "exporting an in-network kubeconfig"
  kind export kubeconfig --name "${CLUSTER_NAME}" --internal
fi

log "advertising the registry to the cluster"
kubectl apply -f - <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REG_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
YAML

kubectl get nodes
log "cluster ready"
