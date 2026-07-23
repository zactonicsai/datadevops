#!/usr/bin/env bash
# =============================================================================
# tests/load-test.sh   --   PROVE KEDA AUTOSCALING ACTUALLY WORKS
# =============================================================================
# WHAT THIS DOES
# Generates sustained HTTP load against the web app from inside the cluster,
# while showing you the replica count changing in real time.
#
# WHAT YOU SHOULD SEE
#   0:00  2 pods, CPU near 0%
#   0:30  CPU climbs past the 50% target
#   1:00  KEDA's HPA adds pods (up to double per 30s, capped at max_replicas)
#   ...   load stops
#   6:00  after the 300s stabilisation window, pods scale back down slowly
#
# The scale-DOWN is deliberately slow (see 04-webapp/scaling.tf). That is not a
# bug; scaling in aggressively is how a traffic dip becomes an outage.
#
# USAGE
#   ./tests/load-test.sh              # 120 seconds of load
#   ./tests/load-test.sh 300          # 300 seconds of load
# =============================================================================

set -uo pipefail

DURATION="${1:-120}"
NAMESPACE="hello-web"
TARGET="http://hello-web.hello-web.svc.cluster.local/burn"
# How many parallel request loops. More workers = more load.
WORKERS=40

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[0;32m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_GREEN=""; C_BOLD=""
fi

echo "${C_BOLD}=== KEDA AUTOSCALING LOAD TEST ===${C_RESET}"
echo "Target:   $TARGET"
echo "Duration: ${DURATION}s with $WORKERS parallel workers"
echo ""

if ! kubectl get deploy/toolbox -n toolbox >/dev/null 2>&1; then
  echo "Toolbox pod not found. Apply layer 08 first."
  exit 1
fi

echo "Starting state:"
kubectl get hpa -n "$NAMESPACE" 2>/dev/null || echo "  (no HPA found)"
kubectl get pods -n "$NAMESPACE" --no-headers | wc -l | xargs echo "  pods:"
echo ""

# ---- Start the load generator in the background ----
# Each worker loops making requests until the deadline. Running this INSIDE the
# cluster matters: from a laptop you would be measuring your own internet
# connection rather than the cluster's capacity.
echo "${C_GREEN}Generating load...${C_RESET}"
kubectl exec -n toolbox deploy/toolbox -- bash -c "
  end=\$(( \$(date +%s) + $DURATION ))
  for w in \$(seq 1 $WORKERS); do
    (
      while [ \$(date +%s) -lt \$end ]; do
        curl -s -o /dev/null --max-time 2 '$TARGET' || true
      done
    ) &
  done
  wait
" >/dev/null 2>&1 &

LOAD_PID=$!

# ---- Watch the scaling happen ----
echo ""
printf "%-10s %-8s %-14s %s\n" "ELAPSED" "PODS" "HPA TARGETS" "REPLICAS"
echo "-----------------------------------------------------------"

START=$(date +%s)
# Watch for the load duration plus 6 minutes, so you also see the scale-down.
WATCH_UNTIL=$(( START + DURATION + 360 ))

while [ "$(date +%s)" -lt "$WATCH_UNTIL" ]; do
  ELAPSED=$(( $(date +%s) - START ))

  PODS="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=hello-web --no-headers 2>/dev/null | grep -c Running || echo 0)"

  HPA_LINE="$(kubectl get hpa -n "$NAMESPACE" --no-headers 2>/dev/null | head -1)"
  TARGETS="$(echo "$HPA_LINE" | awk '{print $4}')"
  REPLICAS="$(echo "$HPA_LINE" | awk '{print $7}')"

  printf "%-10s %-8s %-14s %s\n" \
    "$(( ELAPSED / 60 ))m$(( ELAPSED % 60 ))s" \
    "${PODS:-?}" \
    "${TARGETS:-?}" \
    "${REPLICAS:-?}"

  # Once load has stopped and we are back at the floor, there is nothing more
  # to watch.
  if [ "$ELAPSED" -gt "$(( DURATION + 60 ))" ] && [ "${PODS:-0}" -le 2 ]; then
    echo ""
    echo "${C_GREEN}Scaled back down to the floor. Test complete.${C_RESET}"
    break
  fi

  sleep 15
done

wait $LOAD_PID 2>/dev/null || true

echo ""
echo "${C_BOLD}Final state:${C_RESET}"
kubectl get hpa -n "$NAMESPACE"
kubectl get pods -n "$NAMESPACE"
echo ""
echo "To see the scaling decisions KEDA and the HPA made:"
echo "    kubectl describe hpa -n $NAMESPACE"
echo "    kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp | tail -20"
