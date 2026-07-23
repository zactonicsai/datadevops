# Architecture Map

```text
Your computer
  |
  | Terraform, AWS CLI, kubectl, Helm
  v
AWS VPC
  +-- Two public subnets
  |     +-- NAT Gateway
  |     +-- SSM-only Linux test runner (no inbound security-group rules)
  |
  +-- Two private subnets
        +-- Amazon EKS control-plane network interfaces
        +-- Managed EKS worker-node group
              +-- metrics-server
              +-- KEDA operator
              +-- hello-server-a Deployment (KEDA scaled)
              +-- hello-server-b Deployment (KEDA scaled)
              +-- Strimzi operator
              +-- Kafka KRaft cluster with three combined broker/controller pods
              +-- Apache NiFi cluster with two StatefulSet pods
              +-- test-tools toolbox pod

Storage
  +-- gp3 EBS volumes created through the Amazon EBS CSI driver
        +-- Kafka persistent data
        +-- NiFi repositories and state
```

## Why the folders are separate

Each numbered Terraform folder has its own local state file. Think of each
folder as one small LEGO instruction booklet. The numbered order prevents a
later booklet from trying to use a resource that has not been built yet.
