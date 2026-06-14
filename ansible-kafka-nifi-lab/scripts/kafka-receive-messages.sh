#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-demo-events}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka-server1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-kafka-server1:9092}"
TIMEOUT_MS="${TIMEOUT_MS:-10000}"

echo "Reading messages from topic: ${TOPIC}"
echo "This will stop after ${TIMEOUT_MS} ms if no more messages arrive."
echo ""

docker exec -it "${KAFKA_CONTAINER}" /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --topic "${TOPIC}" \
  --from-beginning \
  --timeout-ms "${TIMEOUT_MS}"
