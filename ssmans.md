AWS Systems Manager (SSM) with Ansible connects to EC2 instances without SSH or open ports, using the SSM Agent instead.

## Connection Plugin

Ansible has a built-in `aws_ssm` connection plugin (from the `amazon.aws` collection).

```bash
ansible-galaxy collection install amazon.aws
```

## Prerequisites

- SSM Agent installed on target instances (pre-installed on most Amazon Linux/Ubuntu AMIs)
- Instance IAM role with `AmazonSSMManagedInstanceCore` policy
- An S3 bucket for file transfer (the plugin uses S3 to move files)
- AWS credentials configured locally (`aws configure` or env vars)
- `boto3` installed: `pip install boto3`

## Inventory Example

```yaml
# inventory.aws_ssm.yml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
filters:
  tag:Environment: production
```

## Playbook / Config

```yaml
# group_vars or inline
ansible_connection: aws_ssm
ansible_aws_ssm_bucket_name: my-ssm-transfer-bucket
ansible_aws_ssm_region: us-east-1
```

Two options depending on whether you want dynamic discovery or a fixed list.

**Dynamic** (`inventory.aws_ssm.yml` — auto-discovers instances by tag):

```yaml
---
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
filters:
  instance-state-name: running
  "tag:AnsibleManaged": "true"
hostnames:
  - instance-id                    # SSM addresses by instance ID, not IP
keyed_groups:
  - key: tags.Role
    prefix: role                   # tag Role=web → group "role_web"
compose:
  ansible_host: instance_id
  ec2_name: tags.Name | default(instance_id)
```

**Static** (`inventory.yml` — hardcoded instance IDs):

```yaml
---
all:
  vars:
    ansible_connection: aws_ssm
    ansible_aws_ssm_region: us-east-1
    ansible_aws_ssm_bucket_name: my-org-ssm-transfer-bucket
  children:
    webservers:
      hosts:
        i-0123456789abcdef0:
        i-0abcdef1234567890:
    databases:
      hosts:
        i-0fedcba9876543210:
```

Key detail for both: hosts are **instance IDs** (`i-xxxx`), never IPs or DNS names — that's what SSM connects on.

Example playbook:

```yaml
- hosts: aws_ec2
  gather_facts: false
  vars:
    ansible_connection: aws_ssm
    ansible_aws_ssm_bucket_name: my-ssm-transfer-bucket
    ansible_aws_ssm_region: us-east-1
  tasks:
    - name: Run a command
      command: uptime

    - name: Install package
      become: true
      package:
        name: htop
        state: present
```

Run it:

```bash
ansible-playbook -i inventory.aws_ssm.yml playbook.yml
```

## Common Options

| Variable | Purpose |
|----------|---------|
| `ansible_aws_ssm_bucket_name` | S3 bucket for file transfer (required) |
| `ansible_aws_ssm_region` | AWS region |
| `ansible_aws_ssm_instance_id` | Explicit instance ID (if not from inventory) |
| `ansible_aws_ssm_s3_addressing_style` | `virtual` or `path` |
| `ansible_aws_ssm_bucket_sse_mode` | S3 encryption, e.g. `aws:kms` |
| `ansible_aws_ssm_timeout` | Connection timeout (seconds) |

## Notes

- Target the instance by `i-xxxxxxxx` ID, not IP — SSM addresses instances by instance ID.
- The Session Manager plugin must be installed on the control node: [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
- Use a bucket in the same region to avoid transfer errors, and lock down bucket permissions since files transit through it.

Want an example for a specific use case (bastionless setup, KMS encryption, or dynamic inventory with SSM)?