# 09 - SSM-Only Linux Test Runner

This folder creates an Amazon Linux 2023 EC2 instance used to test the EKS
cluster from inside the VPC.

The instance is called **SSM-only** because it has no inbound security-group
rules and does not use an SSH key. AWS Systems Manager Session Manager provides
shell access.

## Companion guides

- [SECURITY-GROUP-README.md](SECURITY-GROUP-README.md) explains `security-group.tf`.
- [IAM-ROLE-README.md](IAM-ROLE-README.md) explains `iam.tf`.
- [EKS-ACCESS-ENTRY-README.md](EKS-ACCESS-ENTRY-README.md) explains `access-entry.tf`.

## Why the test runner exists

Some EKS services are private and cannot be reached directly from a home or
office computer. The test runner sits inside the VPC, where it can:

- Reach the private EKS API endpoint
- Run `kubectl`
- Test service DNS names
- Reach pod and service IP addresses
- Produce and consume Kafka messages
- Test the two HTTP applications
- Test NiFi endpoints

## Simple picture

```text
Your computer
     |
     | AWS Systems Manager Session Manager
     v
EC2 test runner -- security-group rule --> EKS API, nodes, and pods
     |
     | EKS access entry + Kubernetes RBAC
     v
Allowed tutorial test commands
```

## Connect to the runner

From this directory:

```bash
terraform output -raw session_command
```

Run the printed command, or use the project script:

```bash
../../scripts/run-tests-ssm.sh
```

## Important security design

- No inbound rules
- No SSH port 22
- No private key file
- IMDSv2 required
- Encrypted gp3 root disk
- Narrow EKS `DescribeCluster` IAM permission
- EKS access mapped to the `tutorial-testers` Kubernetes group
