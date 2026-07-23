# 08 - Two-Node NiFi Cluster

This folder creates a two-pod NiFi StatefulSet. Each pod has its own EBS disk.
An init container copies the official NiFi configuration and changes the
cluster, repository, HTTP, and Kubernetes leader-election settings.

NiFi uses Kubernetes Lease objects instead of ZooKeeper for leader election.
The UI is internal HTTP for tutorial use only.
