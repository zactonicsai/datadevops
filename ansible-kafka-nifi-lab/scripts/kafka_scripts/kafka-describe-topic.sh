#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-demo-events}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka-server1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-kafka-server1:9092}"

docker exec "${KAFKA_CONTAINER}" /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --describe \
  --topic "${TOPIC}"
