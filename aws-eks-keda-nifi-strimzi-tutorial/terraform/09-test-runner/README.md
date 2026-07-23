# 09 - SSM-Only Linux Test Runner

This folder creates an Amazon Linux 2023 EC2 instance. Its security group has no
inbound rules. Session Manager provides shell access. The instance role is
mapped to the Kubernetes group `tutorial-testers` through an EKS access entry.
