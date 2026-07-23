# 07 - Kafka Cluster

This folder creates a three-pod Kafka KRaft cluster. Each pod acts as both a
controller and a broker, which lowers tutorial cost. Each pod receives a gp3
EBS volume. A `tutorial-topic` topic is also created.
