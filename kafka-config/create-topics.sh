#!/bin/bash
# Create one Kafka topic per grocery dataset. Replication factor 3 across the
# 3-broker cluster, 3 partitions each for parallel consumption.
set -e
BROKER="kafka1:29092"

TOPICS=(
  "grocery.sales"
  "grocery.inventory"
  "grocery.vendor_delivery"
  "grocery.customer_feedback"
  "grocery.shelf_space"
  "grocery.ad_program"
  "grocery.marketing"
  "grocery.discount_program"
  "grocery.expiry"
  "grocery.binary"          # metadata for uploaded binary files
  "grocery.text"            # freeform text messages
  "grocery.json"            # generic json messages
)

echo "Waiting for broker ${BROKER}..."
for i in $(seq 1 30); do
  if kafka-broker-api-versions --bootstrap-server "$BROKER" >/dev/null 2>&1; then
    echo "Broker is up."
    break
  fi
  sleep 3
done

for t in "${TOPICS[@]}"; do
  echo "Creating topic: $t"
  kafka-topics --bootstrap-server "$BROKER" \
    --create --if-not-exists \
    --topic "$t" \
    --partitions 3 \
    --replication-factor 3
done

echo "All topics created:"
kafka-topics --bootstrap-server "$BROKER" --list
