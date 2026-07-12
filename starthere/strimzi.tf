apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: broker-pool
  labels:
    strimzi.io/cluster: my-kafka-cluster
spec:
  replicas: 3
  role: broker
  storage:
    type: persistent-claim
    size: 500Gi
    class: gp3 # Ensure you have a topology-aware storage class configured
  template:
    pod:
      tolerations:
        - key: "dedicated"
          operator: "Equal"
          value: "kafka"
          effect: "NoSchedule"
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: role
                    operator: In
                    values:
                      - kafka-broker