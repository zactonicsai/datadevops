#!/usr/bin/env bash
# =============================================================================
# 11-launch-kafka.sh  —  ONE JOB: launch Kafka.
#
# WHAT KAFKA IS: a conveyor belt for messages. Producers put messages on it,
# consumers take them off. Messages stay for a while, so a slow consumer can
# catch up later without losing anything. That "buffer" property is why it
# sits between our web app and NiFi.
#
# WHY NOT AMAZON MSK? MSK is the managed version and costs roughly $150/month
# minimum. One Kafka pod costs us nothing extra. For learning, the pod wins.
#
# KRaft MODE: modern Kafka (3.3+) no longer needs a separate ZooKeeper cluster.
# One container does everything. Much simpler for a lab.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/00-config.sh"
need_tool kubectl
require NS_APPS

banner "Launch Kafka (single broker, KRaft mode)"

log "Applying the Kafka manifest..."
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: ${NS_APPS}
spec:
  # A "headless" service (clusterIP: None) gives each pod a stable DNS name
  # like kafka-0.kafka.lab.svc.cluster.local — which Kafka needs to advertise
  # a consistent address to its clients.
  clusterIP: None
  selector: { app: kafka }
  ports:
    - { name: client, port: 9092 }
    - { name: controller, port: 9093 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: ${NS_APPS}
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels: { app: kafka }
  template:
    metadata:
      labels: { app: kafka }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
      containers:
        - name: kafka
          image: ${IMG_KAFKA}
          env:
            # --- KRaft: this one node is both broker and controller ---
            - name: KAFKA_NODE_ID
              value: "1"
            - name: KAFKA_PROCESS_ROLES
              value: "broker,controller"
            - name: KAFKA_CONTROLLER_QUORUM_VOTERS
              value: "1@kafka-0.kafka.${NS_APPS}.svc.cluster.local:9093"
            - name: KAFKA_LISTENERS
              value: "PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093"
            # ADVERTISED_LISTENERS is the address Kafka TELLS clients to use.
            # Get this wrong and clients connect once, then fail forever with
            # a confusing timeout. It must be reachable from inside the cluster.
            - name: KAFKA_ADVERTISED_LISTENERS
              value: "PLAINTEXT://kafka-0.kafka.${NS_APPS}.svc.cluster.local:9092"
            - name: KAFKA_CONTROLLER_LISTENER_NAMES
              value: "CONTROLLER"
            - name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP
              value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"
            # With one broker you cannot have more than one copy of anything.
            - name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR
              value: "1"
            - name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR
              value: "1"
            - name: KAFKA_AUTO_CREATE_TOPICS_ENABLE
              value: "true"
            - name: KAFKA_LOG_DIRS
              value: "/var/lib/kafka/data"
            - name: CLUSTER_ID
              value: "5L6g3nShT-eMCtK--X86sw"
            - name: KAFKA_HEAP_OPTS
              value: "-Xms256m -Xmx512m"
          ports:
            - { containerPort: 9092, name: client }
            - { containerPort: 9093, name: controller }
          volumeMounts:
            - { name: data, mountPath: /var/lib/kafka }
          resources:
            requests: { cpu: "200m", memory: "768Mi" }
            limits:   { cpu: "1",    memory: "1536Mi" }
          readinessProbe:
            tcpSocket: { port: 9092 }
            initialDelaySeconds: 20
            periodSeconds: 10
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources: { requests: { storage: 5Gi } }
YAML

log "Waiting for Kafka..."
kubectl -n "$NS_APPS" rollout status statefulset/kafka --timeout=300s

log "Creating topic '${KAFKA_TOPIC}' ..."
kubectl -n "$NS_APPS" exec kafka-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --if-not-exists --topic "$KAFKA_TOPIC" --partitions 1 --replication-factor 1

echo
kubectl -n "$NS_APPS" exec kafka-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
echo
ok "Kafka bootstrap address (for other pods): kafka-0.kafka.${NS_APPS}.svc.cluster.local:9092"
save KAFKA_BOOTSTRAP "kafka-0.kafka.${NS_APPS}.svc.cluster.local:9092"
echo
log "Watch messages arrive later with:"
echo "  kubectl -n ${NS_APPS} exec -it kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh \\"
echo "    --bootstrap-server localhost:9092 --topic ${KAFKA_TOPIC} --from-beginning"
echo
log "Next: ./12-launch-nifi.sh"
