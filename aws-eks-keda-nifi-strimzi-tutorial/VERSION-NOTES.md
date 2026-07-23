# Version Snapshot

This project pins versions so a future chart update does not silently change
the tutorial.

| Component | Tutorial version | Reason |
|---|---:|---|
| Amazon EKS Kubernetes | 1.35 | Supported compatibility baseline; not the newest EKS minor |
| AWS Terraform provider | 6.53.0 | Pinned July 2026 provider baseline |
| Kubernetes Terraform provider | 3.2.1 | Pinned July 2026 provider baseline |
| Helm Terraform provider | 3.2.0 | Pinned provider baseline |
| KEDA Helm chart | 2.20.1 | Pinned KEDA 2.20 chart baseline |
| Metrics Server Helm chart | 3.13.1 | Pinned chart baseline |
| Strimzi operator | 1.1.0 | Pinned Strimzi release baseline |
| Apache Kafka | 4.3.0 | Version supported by the pinned Strimzi release |
| Apache NiFi | 2.10.0 | Pinned Apache NiFi release baseline |

Version snapshot date: **July 23, 2026**.

Before using this in production, review each project's release notes and test
upgrades in a non-production cluster.
