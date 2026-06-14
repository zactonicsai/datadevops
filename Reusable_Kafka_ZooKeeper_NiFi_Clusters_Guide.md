# Reusable AWS Clusters Guide: Kafka, ZooKeeper, NiFi with Terraform & Ansible

## Overview
Step-by-step guide for building clean, reusable AWS Linux servers with security patches. Use Terraform for infrastructure, Ansible for configuration, GitLab pipelines for CI/CD. Supports dev/test/staging and airgapped environments.

**Goal**: Create base AMIs with company patches, deploy software via Ansible, manage clusters simply.

## Prerequisites
- AWS account with admin access
- Terraform installed
- Ansible installed
- GitLab access (dev and airgapped instances)
- Basic AWS knowledge (IAM, VPC, EC2)

## Section 1: AWS Setup - IAM Roles, Subnets, VPC
1. **Create IAM Role for EC2**
   - Role name: `EC2BaseRole`
   - Policies: AmazonSSMManagedInstanceCore, custom read-only for S3/SSM
   - Trust: EC2 service

2. **VPC and Subnets**
   - Private subnets only for security.
   - Use VPC module in Terraform.
   - Example: 3 AZs, private subnets for Kafka/Zoo/NiFi.

**Best Practice**: Least privilege IAM. Avoid public IPs.

**Gotcha**: Subnet CIDR overlaps - check VPC CIDR.

**Troubleshoot**: `aws ec2 describe-subnets`

## Section 2: Base AMI Creation with Patches
Use Packer or Terraform to build AMIs from AWS Linux 2/2023.

1. Launch base EC2 from latest Amazon Linux.
2. Run Ansible playbook for security patches from internal team.
3. Create AMI: `aws ec2 create-image`
4. Automate with pipeline.

**Middle School Example**: Like baking a cake base, then adding frosting (patches) and saving the recipe (AMI).

Update process: New patch -> rebuild AMI -> version it (e.g., base-ami-v20260614).

## Section 3: Terraform for Infrastructure
Directory structure:
```
gitlab-repo/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── modules/
│   │   ├── base-ec2/
│   │   ├── kafka-cluster/
│   │   ├── zookeeper/
│   │   └── nifi/
├── ansible/
│   ├── playbooks/
│   └── inventory/
```

**Terraform Example (main.tf snippet)**:
```hcl
module "base_ec2" {
  source = "./modules/base-ec2"
  ami_id = "ami-base-patched"
  instance_type = "t3.medium"
  subnet_id = var.private_subnet
  iam_role = "EC2BaseRole"
}
```

For Kafka cluster (with/without Strimzi - note: Strimzi is K8s, here use native):
- Without Strimzi: 3+ EC2 nodes.
- With: Deploy on EKS (separate guide).

**Reusable**: Use modules, variables for count, size.

**Best Practices**: State in S3 backend. Remote state locking.

**Gotchas**: AMI ID changes - use data source or param.

**Troubleshoot**: `terraform plan -out=plan.tfplan`

## Section 4: Ansible for Software Installation
Playbooks load Kafka, ZooKeeper, NiFi on base instances.

**Example Playbook**:
```yaml
- name: Install Kafka Cluster
  hosts: kafka_nodes
  tasks:
    - name: Download Kafka
      get_url: url=https://archive.apache.org/... dest=/opt/
    - name: Configure
      template: src=kafka.properties.j2 dest=/opt/kafka/config/
    - name: Start service
      systemd: name=kafka state=started
```

Run via: `ansible-playbook -i inventory playbooks/kafka.yml`

**With Strimzi**: Use Helm on K8s instead of bare metal Ansible.

## Section 5: GitLab Pipelines and Directory Structure
**Dev Area Structure**:
- `dev/` branch for testing
- `.gitlab-ci.yml` stages: lint, test, deploy-dev, promote-test, promote-staging

**Airgapped Sync**:
1. Dev GitLab: commit/push
2. Export artifacts
3. Secure transfer (e.g., USB, approved tool) to airgapped GitLab
4. Import and run pipeline

**Pipeline Example**:
```yaml
stages:
  - validate
  - deploy
deploy:
  script:
    - terraform apply
    - ansible-playbook ...
```

## Section 6: Kafka Cluster Setup (With/Without Strimzi)
**Without Strimzi (Native)**:
- 3 ZooKeeper nodes
- 3+ Kafka brokers
- Use Terraform for instances, Ansible for config (zookeeper.properties, server.properties)

**With Strimzi**: Deploy Kafka operator on EKS via Terraform Helm provider + Ansible for extras.

**Simple Example**: ZooKeeper like a phone book for Kafka brokers to find each other.

## Best Practices & Gotchas (All Steps)
- Version everything (Terraform, AMIs)
- Immutable infrastructure
- Monitoring: CloudWatch + Prometheus
- Security: Security groups, encryption
- Scaling: Auto Scaling Groups
- Cost: Use t3 instances, stop when idle

**Troubleshooting Common**:
- SSH fails: Check SG, key pair
- Ansible connection: Verify inventory, SSH keys via SSM
- Terraform errors: Check AWS quotas, region

## Extending the Guide
Add modules easily. Fork repo for new services.

**Contact**: Your Cloud Team Lead
```

**MD file created: Reusable_Kafka_ZooKeeper_NiFi_Clusters_Guide.md** (plain, clean, black/white equivalent in MD). Ready for use.