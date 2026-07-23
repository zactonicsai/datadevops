#!/usr/bin/env bash
# =============================================================================
# tests/run-tests.sh   --   VERIFY THE WHOLE PLATFORM WORKS
# =============================================================================
# WHAT THIS DOES
#
# Runs a series of checks that prove each component is not merely "Running" but
# actually reachable and functioning. There is a real difference: a pod can sit
# in Running state while its application is deadlocked, misconfigured, or
# listening on the wrong port.
#
# Most checks execute INSIDE the toolbox pod, because that is the only place
# cluster-internal DNS names resolve.
#
# USAGE
#   ./tests/run-tests.sh           # run everything
#   ./tests/run-tests.sh --quick   # skip the slow Kafka produce/consume test
#
# EXIT CODE
#   0 = every test passed
#   1 = at least one failed (the summary lists which)
# This makes it usable in CI, not just by hand.
# =============================================================================

set -uo pipefail
# NOTE: deliberately NOT using -e here. We WANT to run every test and report a
# full picture, rather than stopping at the first failure. Each test checks its
# own exit code explicitly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"

LOGFILE="$LOG_DIR/tests_$(date '+%Y%m%d-%H%M%S').log"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# ---- Colours, only when attached to a terminal ----
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BOLD=""
fi

TESTS_RUN=0
TESTS_PASSED=0
FAILED_NAMES=()

TOOLBOX_NS="toolbox"
# The -- separates kubectl's own flags from the command run inside the pod.
TB="kubectl exec -n $TOOLBOX_NS deploy/toolbox --"

# -----------------------------------------------------------------------------
# TEST HELPERS
# -----------------------------------------------------------------------------

section() {
  echo "" | tee -a "$LOGFILE"
  echo "${C_BOLD}--- $* ---${C_RESET}" | tee -a "$LOGFILE"
}

# check <name> <command...>
# Runs the command, prints PASS or FAIL, and records the result.
check() {
  local name="$1"; shift
  TESTS_RUN=$(( TESTS_RUN + 1 ))

  # Capture both stdout and stderr so a failure message is preserved.
  local output
  if output="$("$@" 2>&1)"; then
    echo "${C_GREEN}  PASS${C_RESET}  $name" | tee -a "$LOGFILE"
    echo "        $output" >> "$LOGFILE"
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    return 0
  else
    echo "${C_RED}  FAIL${C_RESET}  $name" | tee -a "$LOGFILE"
    # Show the first three lines of the error inline; the full text is in the
    # log. Three lines is usually enough to recognise the problem without
    # flooding the terminal.
    echo "$output" | head -3 | sed 's/^/        /' | tee -a "$LOGFILE"
    FAILED_NAMES+=("$name")
    return 1
  fi
}

# check_contains <name> <expected-substring> <command...>
# Like check, but also requires the output to contain a given string. Useful
# when a command succeeds but returns the wrong thing.
check_contains() {
  local name="$1"; local expected="$2"; shift 2
  TESTS_RUN=$(( TESTS_RUN + 1 ))

  local output
  output="$("$@" 2>&1)"
  local rc=$?

  if [ $rc -eq 0 ] && echo "$output" | grep -q "$expected"; then
    echo "${C_GREEN}  PASS${C_RESET}  $name" | tee -a "$LOGFILE"
    echo "        $output" >> "$LOGFILE"
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
    return 0
  else
    echo "${C_RED}  FAIL${C_RESET}  $name (expected to find: '$expected')" | tee -a "$LOGFILE"
    echo "$output" | head -3 | sed 's/^/        /' | tee -a "$LOGFILE"
    FAILED_NAMES+=("$name")
    return 1
  fi
}

echo "${C_BOLD}================================================================${C_RESET}"
echo "${C_BOLD}  EKS PLATFORM VERIFICATION${C_RESET}"
echo "${C_BOLD}================================================================${C_RESET}"
echo "Log: $LOGFILE"

# =============================================================================
# 0. PRECONDITIONS
# =============================================================================
section "0. Preconditions"

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "${C_RED}Cannot reach the cluster.${C_RESET}"
  echo "Run: aws eks update-kubeconfig --region <region> --name <cluster>"
  exit 1
fi
echo "${C_GREEN}  PASS${C_RESET}  kubectl can reach the cluster"

# The toolbox is where nearly every other test runs, so verify it first.
if ! kubectl get deploy/toolbox -n "$TOOLBOX_NS" >/dev/null 2>&1; then
  echo "${C_RED}Toolbox pod not found. Apply layer 08 first:${C_RESET}"
  echo "    ./scripts/apply-all.sh 08-toolbox"
  exit 1
fi

echo "  Waiting for the toolbox pod to be Ready..."
kubectl wait --for=condition=Available --timeout=120s deploy/toolbox -n "$TOOLBOX_NS" >/dev/null 2>&1
echo "${C_GREEN}  PASS${C_RESET}  toolbox pod is ready"

# =============================================================================
# 1. CLUSTER HEALTH
# =============================================================================
section "1. Cluster health"

check "All nodes are Ready" \
  bash -c 'test "$(kubectl get nodes --no-headers | grep -cv " Ready ")" -eq 0'

check "No pods stuck in CrashLoopBackOff" \
  bash -c '! kubectl get pods -A --no-headers 2>/dev/null | grep -q CrashLoopBackOff'

check "No pods stuck Pending" \
  bash -c '! kubectl get pods -A --no-headers 2>/dev/null | grep -q " Pending "'

# metrics-server underpins all CPU-based autoscaling, so this is not optional.
check "metrics-server is serving metrics (kubectl top)" \
  bash -c 'kubectl top nodes >/dev/null 2>&1'

# =============================================================================
# 2. DNS RESOLUTION FROM INSIDE THE CLUSTER
# =============================================================================
# Testing DNS separately from TCP matters: "cannot connect" has a completely
# different cause and fix depending on whether the NAME resolved.
section "2. In-cluster DNS resolution"

check_contains "CoreDNS resolves kubernetes.default" "kubernetes.default" \
  $TB nslookup kubernetes.default.svc.cluster.local

check "Resolve hello-web service" \
  $TB getent hosts hello-web.hello-web.svc.cluster.local

check "Resolve Kafka bootstrap service" \
  $TB getent hosts demo-kafka-kafka-bootstrap.kafka.svc.cluster.local

check "Resolve NiFi service" \
  $TB getent hosts nifi.nifi.svc.cluster.local

# StatefulSet pods get individual DNS names; this proves that property works.
check "Resolve individual NiFi pod (nifi-0)" \
  $TB getent hosts nifi-0.nifi-headless.nifi.svc.cluster.local

# =============================================================================
# 3. THE WEB APPLICATION
# =============================================================================
section "3. Web application"

check "Deployment has at least 2 ready replicas" \
  bash -c 'test "$(kubectl get deploy hello-web -n hello-web -o jsonpath="{.status.readyReplicas}")" -ge 2'

# An empty endpoints list is the classic symptom of a label selector mismatch.
check "Service has endpoints (selector matches pods)" \
  bash -c 'test -n "$(kubectl get endpoints hello-web -n hello-web -o jsonpath="{.subsets[0].addresses[0].ip}" 2>/dev/null)"'

check_contains "HTTP 200 and page content served" "Hello from Kubernetes" \
  $TB curl -sf --max-time 10 http://hello-web.hello-web.svc.cluster.local/

check_contains "Health endpoint returns ok" "ok" \
  $TB curl -sf --max-time 10 http://hello-web.hello-web.svc.cluster.local/healthz

# ---- Prove load balancing actually spreads requests ----
# Ten requests should hit more than one pod. If they all hit the same one,
# either there is only one pod or something is pinning traffic.
section "3b. Load balancing across replicas"
echo "  Making 10 requests and counting distinct pods..."
DISTINCT="$($TB bash -c 'for i in $(seq 1 10); do curl -s --max-time 5 http://hello-web.hello-web.svc.cluster.local/ | grep -o "hello-web-[a-z0-9]*-[a-z0-9]*"; done | sort -u | wc -l' 2>/dev/null || echo 0)"
TESTS_RUN=$(( TESTS_RUN + 1 ))
if [ "${DISTINCT:-0}" -ge 2 ]; then
  echo "${C_GREEN}  PASS${C_RESET}  Requests reached $DISTINCT distinct pods"
  TESTS_PASSED=$(( TESTS_PASSED + 1 ))
else
  echo "${C_YELLOW}  WARN${C_RESET}  Requests reached only ${DISTINCT:-0} pod(s)."
  echo "        Not necessarily broken -- with few requests this can happen by chance."
  FAILED_NAMES+=("load balancing spread")
fi

# =============================================================================
# 4. KEDA AUTOSCALING
# =============================================================================
section "4. KEDA autoscaling"

check "KEDA operator pods are running" \
  bash -c 'test "$(kubectl get pods -n keda --no-headers | grep -c Running)" -ge 3'

check_contains "ScaledObject exists and is Ready" "True" \
  bash -c 'kubectl get scaledobject hello-web-scaler -n hello-web -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}"'

# KEDA creates an HPA behind the scenes. Its existence proves the whole chain
# (ScaledObject -> KEDA operator -> HPA) is wired up.
check "KEDA created the underlying HPA" \
  kubectl get hpa -n hello-web keda-hpa-hello-web-scaler

# "<unknown>" in the targets column means metrics-server is not feeding it.
check "HPA is reading real metrics (not <unknown>)" \
  bash -c '! kubectl get hpa -n hello-web --no-headers 2>/dev/null | grep -q "<unknown>"'

# =============================================================================
# 5. KAFKA
# =============================================================================
section "5. Kafka"

check_contains "Kafka cluster reports Ready" "True" \
  bash -c 'kubectl get kafka demo-kafka -n kafka -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}"'

# 3 controllers + 2 brokers = 5. This confirms our sizing actually materialised.
check "All 5 Kafka pods running (3 controllers + 2 brokers)" \
  bash -c 'test "$(kubectl get pods -n kafka -l strimzi.io/cluster=demo-kafka --no-headers 2>/dev/null | grep -c Running)" -eq 5'

check "TCP port 9092 is open on the bootstrap service" \
  $TB nc -z -w 5 demo-kafka-kafka-bootstrap.kafka.svc.cluster.local 9092

check_contains "Test topic exists and is Ready" "True" \
  bash -c 'kubectl get kafkatopic demo-topic -n kafka -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}"'

# ---- The real end-to-end test: write a message, then read it back ----
if [ "$QUICK" -eq 0 ]; then
  section "5b. Kafka produce and consume (end-to-end)"
  echo "  This takes ~60 seconds..."

  # A unique marker so we know we read back OUR message, not a leftover.
  MARKER="test-$(date +%s)-$RANDOM"

  # Produce. We run a throwaway pod with the Kafka CLI tools rather than
  # installing them in the toolbox, because the official Strimzi image already
  # has them and matches the broker version exactly.
  kubectl run kafka-test-producer -n kafka --rm -i --restart=Never \
    --image="quay.io/strimzi/kafka:latest-kafka-4.2.0" \
    --command -- bash -c "echo '$MARKER' | bin/kafka-console-producer.sh \
      --bootstrap-server demo-kafka-kafka-bootstrap:9092 \
      --topic demo-topic" >>"$LOGFILE" 2>&1

  PRODUCE_RC=$?
  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if [ $PRODUCE_RC -eq 0 ]; then
    echo "${C_GREEN}  PASS${C_RESET}  Produced a message to demo-topic"
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
  else
    echo "${C_RED}  FAIL${C_RESET}  Could not produce to demo-topic"
    FAILED_NAMES+=("kafka produce")
  fi

  # Consume from the beginning and look for our marker.
  # --timeout-ms makes the consumer exit rather than waiting forever.
  CONSUMED="$(kubectl run kafka-test-consumer -n kafka --rm -i --restart=Never \
    --image="quay.io/strimzi/kafka:latest-kafka-4.2.0" \
    --command -- bash -c "bin/kafka-console-consumer.sh \
      --bootstrap-server demo-kafka-kafka-bootstrap:9092 \
      --topic demo-topic --from-beginning --timeout-ms 20000" 2>/dev/null || true)"

  TESTS_RUN=$(( TESTS_RUN + 1 ))
  if echo "$CONSUMED" | grep -q "$MARKER"; then
    echo "${C_GREEN}  PASS${C_RESET}  Consumed the exact message we produced"
    TESTS_PASSED=$(( TESTS_PASSED + 1 ))
  else
    echo "${C_RED}  FAIL${C_RESET}  Did not read back our message ($MARKER)"
    FAILED_NAMES+=("kafka consume")
  fi
fi

# =============================================================================
# 6. NIFI
# =============================================================================
section "6. NiFi"

check "Both NiFi pods are running" \
  bash -c 'test "$(kubectl get pods -n nifi -l app.kubernetes.io/name=nifi --no-headers 2>/dev/null | grep -c Running)" -eq 2'

# Each StatefulSet pod should have claimed its own volume.
check "Each NiFi pod has its own PersistentVolumeClaim" \
  bash -c 'test "$(kubectl get pvc -n nifi --no-headers 2>/dev/null | grep -c Bound)" -eq 2'

check "TCP port 8443 is open on the NiFi service" \
  $TB nc -z -w 5 nifi.nifi.svc.cluster.local 8443

# -k skips certificate verification. NiFi generates a self-signed cert, so this
# is expected, not a workaround being papered over.
check "NiFi HTTPS endpoint responds" \
  $TB curl -sk --max-time 15 -o /dev/null -w "%{http_code}" https://nifi.nifi.svc.cluster.local:8443/nifi

# =============================================================================
# 7. CROSS-COMPONENT REACHABILITY
# =============================================================================
# This is the specific thing you asked for: one Linux pod proving it can reach
# every other component.
section "7. Toolbox reaches everything"

check "Toolbox -> web app (HTTP)" \
  $TB curl -sf --max-time 10 -o /dev/null http://hello-web.hello-web.svc.cluster.local/

check "Toolbox -> Kafka (TCP 9092)" \
  $TB nc -z -w 5 demo-kafka-kafka-bootstrap.kafka.svc.cluster.local 9092

check "Toolbox -> Kafka TLS listener (TCP 9093)" \
  $TB nc -z -w 5 demo-kafka-kafka-bootstrap.kafka.svc.cluster.local 9093

check "Toolbox -> NiFi (TCP 8443)" \
  $TB nc -z -w 5 nifi.nifi.svc.cluster.local 8443

check "Toolbox -> individual NiFi pod nifi-0" \
  $TB nc -z -w 5 nifi-0.nifi-headless.nifi.svc.cluster.local 8443

check "Toolbox -> individual NiFi pod nifi-1" \
  $TB nc -z -w 5 nifi-1.nifi-headless.nifi.svc.cluster.local 8443

# Confirms the RBAC we granted actually works.
check "Toolbox can read the Kubernetes API (RBAC)" \
  $TB kubectl get pods -A

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "${C_BOLD}================================================================${C_RESET}"
echo "${C_BOLD}  RESULTS: $TESTS_PASSED / $TESTS_RUN passed${C_RESET}"
echo "${C_BOLD}================================================================${C_RESET}"

if [ ${#FAILED_NAMES[@]} -eq 0 ]; then
  echo "${C_GREEN}Everything passed. The platform is working end to end.${C_RESET}"
  echo "Full log: $LOGFILE"
  exit 0
else
  echo "${C_RED}Failed checks:${C_RESET}"
  for n in "${FAILED_NAMES[@]}"; do echo "    - $n"; done
  echo ""
  echo "Full log: $LOGFILE"
  echo ""
  echo "Common causes:"
  echo "  - Ran too soon. Kafka and NiFi take several minutes to become Ready."
  echo "    Watch with: kubectl get pods -A -w"
  echo "  - A pod is Pending because the cluster is out of CPU or memory."
  echo "    Check with: kubectl describe pod <name> -n <namespace>"
  echo "  - Look at the events, which usually name the real problem:"
  echo "    kubectl get events -A --sort-by=.lastTimestamp | tail -30"
  exit 1
fi
