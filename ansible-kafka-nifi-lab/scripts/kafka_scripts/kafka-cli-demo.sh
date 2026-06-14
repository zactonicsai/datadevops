#!/usr/bin/env bash
set -euo pipefail

TOPIC="${1:-demo-events}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/kafka-create-topic.sh" "${TOPIC}"
"${SCRIPT_DIR}/kafka-send-message.sh" "${TOPIC}" "Hello Kafka from the CLI demo"
"${SCRIPT_DIR}/kafka-send-sample-messages.sh" "${TOPIC}"
"${SCRIPT_DIR}/kafka-describe-topic.sh" "${TOPIC}"
"${SCRIPT_DIR}/kafka-receive-messages.sh" "${TOPIC}"
