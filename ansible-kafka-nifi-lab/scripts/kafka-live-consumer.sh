#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-demo-events}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka-server1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-kafka-server1:9092}"

echo "Opening live consumer for topic: ${TOPIC}"
echo "Leave this open, then send messages from another terminal."
echo "Press Ctrl+C to stop."
echo ""

docker exec -it "${KAFKA_CONTAINER}" /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --topic "${TOPIC}"
