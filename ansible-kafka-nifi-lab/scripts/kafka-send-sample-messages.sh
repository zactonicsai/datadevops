#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-demo-events}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka-server1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-kafka-server1:9092}"

echo "Sending sample messages to topic: ${TOPIC}"

printf 'order-1001 created\norder-1002 paid\norder-1003 shipped\ninventory SKU-55 updated\n' | \
  docker exec -i "${KAFKA_CONTAINER}" /opt/kafka/bin/kafka-console-producer.sh \
    --bootstrap-server "${BOOTSTRAP_SERVER}" \
    --topic "${TOPIC}"

echo "Sample messages sent."
