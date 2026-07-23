#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
load_config

failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

kubectl cluster-info >/dev/null && pass "Kubernetes API is reachable" || fail "Kubernetes API is not reachable"

not_ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {count++} END {print count+0}')"
[[ "${not_ready_nodes}" -eq 0 ]] && pass "All EKS nodes are Ready" || fail "One or more EKS nodes are not Ready"

kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=5m \
  && pass "Metrics Server is Available" || fail "Metrics Server is not Available"

kubectl wait --for=condition=Available deployment/keda-operator -n keda --timeout=5m \
  && pass "KEDA operator is Available" || fail "KEDA operator is not Available"

kubectl wait --for=condition=Available deployment/hello-server-a -n web --timeout=5m \
  && pass "Hello server A is Available" || fail "Hello server A is not Available"

kubectl wait --for=condition=Available deployment/hello-server-b -n web --timeout=5m \
  && pass "Hello server B is Available" || fail "Hello server B is not Available"

web_results="$(
  for _ in $(seq 1 20); do
    kubectl exec -n test-tools deployment/toolbox --       curl -fsS --max-time 10 http://hello-web.web.svc.cluster.local 2>/dev/null || true
  done
)"

if [[ "${web_results}" == *"Hello from server A"* && "${web_results}" == *"Hello from server B"* ]]; then
  pass "Toolbox pod reached both hello web Deployments through the shared Service"
else
  fail "The shared web Service did not return pages from both server A and server B"
fi

kubectl get scaledobject -n web hello-server-a >/dev/null 2>&1 \
  && pass "KEDA ScaledObject for server A exists" || fail "KEDA ScaledObject for server A is missing"

kubectl get scaledobject -n web hello-server-b >/dev/null 2>&1 \
  && pass "KEDA ScaledObject for server B exists" || fail "KEDA ScaledObject for server B is missing"

kubectl wait kafka/tutorial-kafka -n kafka --for=condition=Ready --timeout=15m \
  && pass "Kafka cluster is Ready" || fail "Kafka cluster did not become Ready"

broker_pod="$(kubectl get pods -n kafka -l strimzi.io/name=tutorial-kafka-kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${broker_pod}" ]]; then
  test_message="terraform-eks-test-$(date +%s)"
  printf '%s\n' "${test_message}" | kubectl exec -i -n kafka "${broker_pod}" -- \
    /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server tutorial-kafka-kafka-bootstrap:9092 \
    --topic tutorial-topic >/dev/null 2>&1 || true

  consumed="$(kubectl exec -n kafka "${broker_pod}" -- timeout 20 \
    /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server tutorial-kafka-kafka-bootstrap:9092 \
    --topic tutorial-topic \
    --from-beginning \
    --max-messages 20 2>/dev/null || true)"

  [[ "${consumed}" == *"${test_message}"* ]] \
    && pass "Kafka produced and consumed a test message" \
    || fail "Kafka test message was not read back"
else
  fail "No Kafka broker pod was found"
fi

kubectl rollout status statefulset/nifi -n nifi --timeout=15m \
  && pass "Both NiFi pods rolled out" || fail "NiFi StatefulSet did not finish rollout"

nifi_result="$(kubectl exec -n test-tools deployment/toolbox -- curl -fsS --max-time 15 http://nifi.nifi.svc.cluster.local:8080/nifi/ 2>/dev/null || true)"
[[ -n "${nifi_result}" ]] && pass "Toolbox pod reached the NiFi web service" || fail "Toolbox pod could not reach NiFi"

nifi_cluster_json="$(
  kubectl exec -n test-tools deployment/toolbox --     curl -fsS --max-time 20 http://nifi.nifi.svc.cluster.local:8080/nifi-api/controller/cluster 2>/dev/null || true
)"
nifi_node_count="$(printf '%s' "${nifi_cluster_json}" | jq -r '.cluster.nodes | length' 2>/dev/null || echo 0)"
[[ "${nifi_node_count}" -eq 2 ]]   && pass "NiFi API reports two cluster nodes"   || fail "NiFi API did not report two cluster nodes"

nifi_leases="$(kubectl get lease -n nifi --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[[ "${nifi_leases}" -ge 1 ]] && pass "NiFi created Kubernetes leader-election Leases" || fail "No NiFi leader-election Lease was found"

pending_pvcs="$(kubectl get pvc -A --no-headers 2>/dev/null | awk '$4 != "Bound" {count++} END {print count+0}')"
[[ "${pending_pvcs}" -eq 0 ]] && pass "All application PVCs are Bound" || fail "One or more PVCs are not Bound"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} test(s) failed."
  exit 1
fi

echo "All tests passed."
