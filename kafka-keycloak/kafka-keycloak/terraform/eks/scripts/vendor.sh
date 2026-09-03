#!/usr/bin/env bash
# Re-download the vendored charts, manifests and IAM policy (run only when bumping versions).
set -euo pipefail
cd "$(dirname "$0")/.."
STRIMZI=0.45.0; EKS_CHARTS=v0.0.190; KEYCLOAK=26.3.0; LBC=v2.11.0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

curl -sSL -o "$TMP/strimzi.tgz" "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${STRIMZI}/strimzi-kafka-operator-helm-3-chart-${STRIMZI}.tgz"
rm -rf charts/strimzi-kafka-operator && tar xzf "$TMP/strimzi.tgz" -C charts

curl -sSL -o "$TMP/eks.tgz" "https://codeload.github.com/aws/eks-charts/tar.gz/refs/tags/${EKS_CHARTS}"
tar xzf "$TMP/eks.tgz" -C "$TMP"
rm -rf charts/aws-load-balancer-controller && cp -r "$TMP"/eks-charts-*/stable/aws-load-balancer-controller charts/

curl -sSL -o "$TMP/kafbat.tgz" "https://codeload.github.com/kafbat/helm-charts/tar.gz/refs/heads/main"
tar xzf "$TMP/kafbat.tgz" -C "$TMP"
rm -rf charts/kafka-ui && cp -r "$TMP"/helm-charts-main/charts/kafka-ui charts/

B="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK}/kubernetes"
curl -sSL -o manifests/keycloak-operator/01-crd-keycloaks.yml            "$B/keycloaks.k8s.keycloak.org-v1.yml"
curl -sSL -o manifests/keycloak-operator/02-crd-keycloakrealmimports.yml "$B/keycloakrealmimports.k8s.keycloak.org-v1.yml"
curl -sSL -o manifests/keycloak-operator/03-operator.yml                 "$B/kubernetes.yml"

curl -sSL -o iam/aws-load-balancer-controller-policy.json "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC}/docs/install/iam_policy.json"
echo "Vendored. Update charts/VERSIONS.md if versions changed."
