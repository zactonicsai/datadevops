#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-demo-events}"
PARTITIONS="${PARTITIONS:-3}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-3}"
KAFKA_CONTAINER="${KAFKA_CONTAINER:-kafka-server1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-kafka-server1:9092}"

echo "Creating or checking topic: ${TOPIC}"

docker exec "${KAFKA_CONTAINER}" /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --create \
  --if-not-exists \
  --topic "${TOPIC}" \
  --partitions "${PARTITIONS}" \
  --replication-factor "${REPLICATION_FACTOR}"

echo ""
echo "Current topics:"
docker exec "${KAFKA_CONTAINER}" /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --list
