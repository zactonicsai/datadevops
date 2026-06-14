#!/usr/bin/env bash
set -euo pipefail

echo "Containers managed by this lab:"
docker ps --filter label=managed_by=ansible --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo
echo "Kafka topics from server1:"
docker exec kafka-server1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-server1:9092 --list || true

echo
echo "NiFi URLs:"
echo "server1: https://localhost:18443/nifi"
echo "server2: https://localhost:28443/nifi"
echo "server3: https://localhost:38443/nifi"
