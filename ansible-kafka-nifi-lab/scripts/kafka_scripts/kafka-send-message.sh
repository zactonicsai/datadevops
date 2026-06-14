#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-demo-events}"
MESSAGE="${2:-Hello Kafka from the CLI}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka-server1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-kafka-server1:9092}"

echo "Sending message to topic: ${TOPIC}"
echo "Message: ${MESSAGE}"

printf '%s\n' "${MESSAGE}" | docker exec -i "${KAFKA_CONTAINER}" /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --topic "${TOPIC}"

echo "Message sent."
