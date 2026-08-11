# Apache NiFi Admin Guide: Install, Configure, and Monitor on AWS

*A complete tutorial for admin teams — written in plain, easy-to-follow language.*

---

## Table of Contents

1. [What Is NiFi (In Simple Terms)](#1-what-is-nifi-in-simple-terms)
2. [AWS Background: The Building Blocks](#2-aws-background-the-building-blocks)
3. [Prerequisites Checklist](#3-prerequisites-checklist)
4. [Networking, Security Groups, and Roles Explained](#4-networking-security-groups-and-roles-explained)
5. [Installing NiFi](#5-installing-nifi)
6. [Configuring NiFi](#6-configuring-nifi)
7. [Securing NiFi (HTTPS + Login)](#7-securing-nifi-https--login)
8. [Command-Line Health Checks](#8-command-line-health-checks)
9. [Monitoring for Issues](#9-monitoring-for-issues)
10. [Terraform Examples](#10-terraform-examples)
11. [Ansible Examples](#11-ansible-examples)
12. [Monitoring Tools Setup](#12-monitoring-tools-setup)
13. [Best Practices Cheat Sheet](#13-best-practices-cheat-sheet)
14. [Troubleshooting Common Problems](#14-troubleshooting-common-problems)

---

## 1. What Is NiFi (In Simple Terms)

Imagine a system of **water pipes**. Water comes in from one place, flows through pipes, gets filtered and sorted, and comes out somewhere useful. **Apache NiFi is like that — but for data instead of water.**

- Data comes in (from files, databases, sensors, apps).
- NiFi moves it, cleans it, changes its shape, and routes it.
- Data comes out where you need it (a database, another app, storage).

You build these "pipes" by dragging boxes (called **processors**) onto a screen and connecting them with arrows. Each box does one job, like "read a file" or "convert to JSON."

**Key words you'll hear:**

| Word | Plain meaning |
|---|---|
| **FlowFile** | One piece of data traveling through the pipes (like one drop of water). |
| **Processor** | A box that does one job to the data. |
| **Connection** | The arrow (a queue) that holds data between boxes. |
| **Flow Controller** | The "brain" that schedules and runs everything. |
| **Repository** | Where NiFi saves its data and history on disk. |
| **NiFi Cluster** | Several NiFi computers working together as one team. |

---

## 2. AWS Background: The Building Blocks

AWS (Amazon Web Services) is a giant set of rental computers and tools on the internet. Here are the pieces we care about, explained simply.

| AWS Thing | What it really is | Kid-friendly comparison |
|---|---|---|
| **EC2 instance** | A rented computer in the cloud. | Renting a desk in a huge office building. |
| **VPC** | Your own private section of AWS. | Your own fenced-in yard inside a giant park. |
| **Subnet** | A smaller area inside your VPC. | A single room inside your fenced yard. |
| **Security Group** | A firewall — rules for who can talk to your computer. | A bouncer at a door with a guest list. |
| **IAM Role** | A permission badge for a computer or service. | A hall pass that says what doors you can open. |
| **EBS Volume** | A hard drive attached to your EC2 computer. | A backpack that holds your stuff. |
| **S3 Bucket** | Cloud storage for files. | A giant locker you can reach from anywhere. |
| **Key Pair** | A digital key to log in to your computer. | The physical key to your front door. |
| **CloudWatch** | AWS's monitoring and alarm service. | A smoke detector that beeps when something's wrong. |

---

## 3. Prerequisites Checklist

Before installing NiFi, make sure you have all of this ready.

### On the AWS side

- [ ] An **AWS account** with permission to make EC2, VPC, and IAM changes.
- [ ] A **VPC** with at least one subnet (public or private — see Section 4).
- [ ] A **Key Pair** downloaded so you can SSH (log in) to the server.
- [ ] A **Security Group** (we'll build one in Section 4).
- [ ] An **IAM Role** for the EC2 instance (for logs and S3 access).
- [ ] Enough EC2 size. **Recommended starting point:**
  - Small/testing: `t3.large` (2 CPU, 8 GB RAM)
  - Production single node: `m5.2xlarge` (8 CPU, 32 GB RAM)
  - Production cluster: 3+ nodes of `m5.2xlarge` or bigger
- [ ] **Storage:** At least 100 GB of EBS. NiFi's repositories grow fast.

### On the software side

- [ ] **Java** — NiFi 2.x needs **Java 21**. NiFi 1.x needs Java 8 or 11. *Always check your NiFi version's docs.*
- [ ] A **Linux** server. This guide assumes **Amazon Linux 2023** or **Ubuntu 22.04**.
- [ ] Terraform and/or Ansible installed on your laptop (for the automation sections).

### Quick version check commands

```bash
# Check your Java version (must match your NiFi version's requirement)
java -version

# Check available disk space
df -h

# Check available memory
free -h

# Check number of CPU cores
nproc
```

---

## 4. Networking, Security Groups, and Roles Explained

This is the part people find confusing, so we'll go slow and use simple pictures.

### 4.1 The VPC and Subnets — Your Fenced Yard

Think of your **VPC** as a big fenced-in yard. Inside it, you split the space into **rooms** called **subnets**.

- **Public subnet** = a room with a door to the street (the internet). Things here can be reached from outside.
- **Private subnet** = a room with **no** street door. Safer, but harder to reach directly.

**Best practice:** Put NiFi in a **private subnet** and reach it through a secure jump box (bastion) or a load balancer. This keeps NiFi hidden from random people on the internet.

```
                    INTERNET
                       |
                 [ Load Balancer ]   <- lives in public subnet
                       |
              +--------+--------+
              |   PRIVATE SUBNET |
              |   [ NiFi Server ]|   <- hidden and safe
              +------------------+
```

### 4.2 Security Groups — The Bouncer With a Guest List

A **Security Group** is a list of rules that says *who is allowed to talk to your server, and on which door (port)*.

A **port** is like a numbered door on your computer. Different programs use different doors.

**Ports NiFi uses:**

| Port | Door for... | Who should be allowed in |
|---|---|---|
| `8443` | NiFi web page (secure HTTPS) | Your team's IP addresses only |
| `8080` | NiFi web page (unsecure HTTP) | **Avoid in production** — use 8443 |
| `22` | SSH (admin login) | Admin team IPs / bastion only |
| `11443` | Cluster node-to-node talk | Other NiFi nodes only |
| `6342` | Cluster load balancing | Other NiFi nodes only |
| `2181` | ZooKeeper (cluster coordination) | Other NiFi nodes only |

**Golden rule:** Only open the doors you actually need, and only to the people who actually need them. Never open a door to "everyone" (`0.0.0.0/0`) unless you have a very good reason.

**Example guest list (in plain words):**

> - Allow port 8443 FROM the office network only.
> - Allow port 22 FROM the bastion server only.
> - Allow ports 11443, 6342, 2181 FROM other NiFi nodes only.
> - Block everything else.

### 4.3 IAM Roles — The Hall Pass

Your NiFi server sometimes needs to do AWS things, like:

- Save log files to **CloudWatch**.
- Read or write files in an **S3 bucket**.

Instead of putting a password on the server (risky!), you attach an **IAM Role**. The role is a **hall pass** that says exactly what the server is allowed to do — nothing more.

**Best practice:** Give the role the **least privilege** — only the exact permissions it needs. If NiFi only reads from one S3 bucket, don't give it access to *all* buckets.

**Example permissions a NiFi role might need:**

- Write logs to CloudWatch Logs.
- Read/write to `s3://my-company-nifi-data/*` (one specific bucket).
- Read secrets from AWS Secrets Manager (for passwords).

### 4.4 Putting It Together

```
[ IAM Role ]  ---- attached to ---->  [ EC2: NiFi ]
   (hall pass)                          |
                                        | protected by
                                        v
                                 [ Security Group ]
                                   (the bouncer)
                                        |
                                    lives inside
                                        v
                                 [ Private Subnet ]
                                        |
                                    inside the
                                        v
                                     [ VPC ]
                                  (fenced yard)
```

---

## 5. Installing NiFi

We'll show two ways: the **manual way** (to understand it) and the **automated way** (Terraform + Ansible, later).

### 5.1 Step-by-Step Manual Install

**Step 1 — Log in to your server:**

```bash
ssh -i my-key.pem ec2-user@<your-server-ip>
```

**Step 2 — Install Java 21:**

```bash
# Amazon Linux 2023
sudo dnf install -y java-21-amazon-corretto-headless

# Ubuntu 22.04
sudo apt update && sudo apt install -y openjdk-21-jdk

# Verify
java -version
```

**Step 3 — Create a dedicated NiFi user (never run NiFi as root):**

```bash
sudo useradd -m -s /bin/bash nifi
```

**Step 4 — Download and unpack NiFi:**

```bash
# Set the version you want
NIFI_VERSION=2.0.0

# Download (check nifi.apache.org for the latest official mirror link)
cd /opt
sudo curl -O https://dlcdn.apache.org/nifi/${NIFI_VERSION}/nifi-${NIFI_VERSION}-bin.zip

# Unzip
sudo unzip nifi-${NIFI_VERSION}-bin.zip
sudo mv nifi-${NIFI_VERSION} nifi
sudo chown -R nifi:nifi /opt/nifi
```

**Step 5 — Set up NiFi as a service** so it starts automatically. Create the file `/etc/systemd/system/nifi.service`:

```ini
[Unit]
Description=Apache NiFi
After=network.target

[Service]
Type=forking
User=nifi
Group=nifi
ExecStart=/opt/nifi/bin/nifi.sh start
ExecStop=/opt/nifi/bin/nifi.sh stop
ExecReload=/opt/nifi/bin/nifi.sh restart
Restart=on-failure
LimitNOFILE=50000

[Install]
WantedBy=multi-user.target
```

**Step 6 — Start NiFi:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable nifi     # start on boot
sudo systemctl start nifi      # start now
sudo systemctl status nifi     # check it's running
```

NiFi takes **1–2 minutes** to fully start. Be patient!

---

## 6. Configuring NiFi

NiFi's settings live in the `/opt/nifi/conf/` folder. The most important files:

| File | What it controls |
|---|---|
| `nifi.properties` | The main settings (ports, security, repositories). |
| `bootstrap.conf` | Java memory settings. |
| `authorizers.xml` | Who is allowed to do what. |
| `login-identity-providers.xml` | How people log in. |
| `logback.xml` | Logging settings. |

### 6.1 Set Java Memory (bootstrap.conf)

Open `/opt/nifi/conf/bootstrap.conf` and set memory. A good rule: give NiFi about **half** the server's RAM to start.

```properties
# For a server with 32 GB RAM, give NiFi 16 GB
java.arg.2=-Xms16g
java.arg.3=-Xmx16g
```

> `-Xms` is the starting memory, `-Xmx` is the maximum. Setting them equal avoids slowdowns.

### 6.2 Key Settings in nifi.properties

```properties
# --- Web settings ---
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443

# Turn OFF the old unsecure HTTP port in production
nifi.web.http.port=

# --- Repository locations (put these on fast, big disks) ---
nifi.flowfile.repository.directory=/data/flowfile_repository
nifi.content.repository.directory.default=/data/content_repository
nifi.provenance.repository.directory.default=/data/provenance_repository

# --- Cluster settings (only if clustering) ---
nifi.cluster.is.node=true
nifi.cluster.node.address=<this-node-hostname>
nifi.cluster.node.protocol.port=11443
```

> **Best practice:** Put the three repositories on **separate disks** if you can. It's like having separate lanes on a highway — less traffic jam.

### 6.3 Apply Changes

Every time you change a config file, restart NiFi:

```bash
sudo systemctl restart nifi
```

---

## 7. Securing NiFi (HTTPS + Login)

**Never run production NiFi without security.** Modern NiFi (1.14+) turns on HTTPS automatically and creates a random admin username and password on first start.

### 7.1 Find the Auto-Generated Login

On first startup, NiFi prints a one-time username and password to the logs:

```bash
# Look for the generated credentials
grep -i "generated" /opt/nifi/logs/nifi-app.log
```

You'll see lines like "Generated Username" and "Generated Password." **Save these** — you need them to log in the first time.

### 7.2 Set Your Own Username and Password

```bash
sudo -u nifi /opt/nifi/bin/nifi.sh set-single-user-credentials <username> <password>
```

> Password must be at least 12 characters.

### 7.3 Using Real Certificates

The auto-generated setup uses a **self-signed certificate** (your browser will warn you). For production:

- Use a certificate from your company's certificate authority, **or**
- Use AWS Certificate Manager (ACM) on a load balancer in front of NiFi.

### 7.4 Best Practices for Security

- Always use **port 8443 (HTTPS)**, never 8080 (HTTP) in production.
- Restrict who can reach NiFi using the **Security Group** (Section 4).
- Store passwords in **AWS Secrets Manager**, not in plain text files.
- Turn on **audit logging** so you know who did what.
- Keep NiFi in a **private subnet**.

---

## 8. Command-Line Health Checks

These are the commands your admin team should know by heart. Keep this section handy.

### 8.1 Is NiFi Running?

```bash
# Check the service status
sudo systemctl status nifi

# Check using NiFi's own script (shows the process ID)
sudo -u nifi /opt/nifi/bin/nifi.sh status

# See if NiFi's port is listening
sudo ss -tlnp | grep 8443
```

### 8.2 Start / Stop / Restart

```bash
sudo systemctl start nifi      # start
sudo systemctl stop nifi       # stop
sudo systemctl restart nifi    # restart
```

### 8.3 Check the Logs

NiFi has three main log files in `/opt/nifi/logs/`:

| Log file | What's in it |
|---|---|
| `nifi-app.log` | The main log — errors, warnings, activity. |
| `nifi-user.log` | Who logged in and what they did. |
| `nifi-bootstrap.log` | Startup and shutdown messages. |

```bash
# Watch the main log live (Ctrl+C to stop)
tail -f /opt/nifi/logs/nifi-app.log

# Search for errors
grep -i "error" /opt/nifi/logs/nifi-app.log

# Search for out-of-memory problems
grep -i "OutOfMemory" /opt/nifi/logs/nifi-app.log

# See the last 100 lines
tail -n 100 /opt/nifi/logs/nifi-app.log
```

### 8.4 Check System Resources

```bash
# Memory usage
free -h

# Disk usage — watch the repository disks closely!
df -h

# See which disks are filling up
du -sh /data/*_repository

# CPU and memory of the NiFi process, live
top -u nifi

# How much of each repository disk is used
df -h /data/content_repository /data/flowfile_repository /data/provenance_repository
```

### 8.5 Check Java

```bash
# Find the NiFi Java process
jps -l | grep nifi

# Check Java memory usage of the running process (use the PID from jps)
jstat -gcutil <PID> 1000 5
```

### 8.6 Check the API (Is NiFi Really Healthy?)

NiFi has a web API you can ask for its status. Replace `<host>` with your server.

```bash
# Get overall system diagnostics (needs an auth token in secured mode)
curl -k https://<host>:8443/nifi-api/system-diagnostics

# Check cluster status (clustered setups)
curl -k https://<host>:8443/nifi-api/controller/cluster
```

> The `-k` flag tells curl to accept the self-signed certificate. Remove it once you have real certificates.

---

## 9. Monitoring for Issues

Monitoring means **watching for problems before they become emergencies.** Here's what to watch and why.

### 9.1 The Big Four to Watch

| What to watch | Why it matters | Warning sign |
|---|---|---|
| **Disk space** | Full repository = NiFi stops. | Any repo disk over 80% full. |
| **Memory (heap)** | Too full = crashes/slowdowns. | Heap consistently over 80%. |
| **Back pressure** | Queues too full = data stops flowing. | Connections turning red / full. |
| **Node health** | A down node breaks the cluster. | Node "disconnected" in the UI. |

### 9.2 Back Pressure (Explained Simply)

Imagine a sink filling faster than it drains. Eventually it overflows. NiFi prevents overflow with **back pressure** — when a queue gets too full, NiFi tells the upstream box to *stop sending* until things clear.

- A queue **thermometer turning red** in the UI = back pressure is on.
- This is NiFi protecting itself, but it means data is **backing up**.
- Investigate the slow box downstream.

### 9.3 What "Bulletins" Are

NiFi shows **bulletins** — little pop-up warnings in the top-right of the screen — when something goes wrong. Red bulletins need attention. You can also pull bulletins from the API for automated alerting.

### 9.4 Set Up Automated Alerts

Don't rely on humans staring at screens. Set up alerts (covered in Section 12) so you get a message when:

- Disk usage crosses 80%.
- Heap memory crosses 80%.
- A cluster node disconnects.
- NiFi stops responding.

---

## 10. Terraform Examples

**Terraform** is a tool that builds your AWS setup from a text file, so it's repeatable and reliable. Think of it as a **LEGO instruction sheet** — anyone can follow it and get the same result.

> These are teaching examples. Adjust names, CIDR blocks, and IDs for your environment. Never hard-code secrets.

### 10.1 Security Group for NiFi

```hcl
# security_group.tf

resource "aws_security_group" "nifi_sg" {
  name        = "nifi-security-group"
  description = "Controls access to NiFi servers"
  vpc_id      = var.vpc_id

  # Allow HTTPS (NiFi UI) only from the office network
  ingress {
    description = "NiFi UI (HTTPS)"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.office_cidr]   # e.g. "203.0.113.0/24"
  }

  # Allow SSH only from the bastion host
  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }

  # Cluster ports — only NiFi nodes talk to each other
  ingress {
    description = "Cluster node protocol"
    from_port   = 11443
    to_port     = 11443
    protocol    = "tcp"
    self        = true   # only members of this same SG
  }

  ingress {
    description = "Cluster load balancing"
    from_port   = 6342
    to_port     = 6342
    protocol    = "tcp"
    self        = true
  }

  # Allow all outbound (NiFi needs to reach data sources)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nifi-sg"
    Team = "data-admin"
  }
}
```

### 10.2 IAM Role for NiFi

```hcl
# iam_role.tf

# The trust policy: lets EC2 use this role
data "aws_iam_policy_document" "nifi_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nifi_role" {
  name               = "nifi-instance-role"
  assume_role_policy = data.aws_iam_policy_document.nifi_assume.json
}

# The permissions: least privilege — only what NiFi needs
data "aws_iam_policy_document" "nifi_permissions" {
  # Write logs to CloudWatch
  statement {
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:log-group:/nifi/*"]
  }

  # Access ONE specific S3 bucket only
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::my-company-nifi-data",
      "arn:aws:s3:::my-company-nifi-data/*"
    ]
  }

  # Read secrets (passwords) from Secrets Manager
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:*:*:secret:nifi/*"]
  }
}

resource "aws_iam_role_policy" "nifi_policy" {
  name   = "nifi-permissions"
  role   = aws_iam_role.nifi_role.id
  policy = data.aws_iam_policy_document.nifi_permissions.json
}

# The instance profile connects the role to EC2
resource "aws_iam_instance_profile" "nifi_profile" {
  name = "nifi-instance-profile"
  role = aws_iam_role.nifi_role.name
}
```

### 10.3 The EC2 Instance and Its Disk

```hcl
# ec2.tf

resource "aws_instance" "nifi" {
  ami                    = var.nifi_ami_id        # your Linux AMI
  instance_type          = "m5.2xlarge"
  subnet_id              = var.private_subnet_id  # keep it private!
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.nifi_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.nifi_profile.name

  # Root disk for the OS
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "nifi-node-1"
    Role = "nifi"
  }
}

# Separate big disk for NiFi repositories
resource "aws_ebs_volume" "nifi_data" {
  availability_zone = aws_instance.nifi.availability_zone
  size              = 500
  type              = "gp3"
  encrypted         = true
  tags = { Name = "nifi-data-volume" }
}

resource "aws_volume_attachment" "nifi_data_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.nifi_data.id
  instance_id = aws_instance.nifi.id
}
```

### 10.4 CloudWatch Alarm for Disk

```hcl
# cloudwatch.tf

resource "aws_cloudwatch_metric_alarm" "nifi_disk_high" {
  alarm_name          = "nifi-disk-usage-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "NiFi disk usage above 80%"
  alarm_actions       = [var.sns_topic_arn]   # sends an alert
  dimensions = {
    InstanceId = aws_instance.nifi.id
  }
}
```

### 10.5 Running Terraform

```bash
terraform init      # download providers, get ready
terraform fmt       # tidy up your files
terraform validate  # check for mistakes
terraform plan      # PREVIEW what will change (always do this!)
terraform apply     # actually build it
terraform destroy   # tear it all down (careful!)
```

> **Best practice:** Always run `terraform plan` first and read it. It shows exactly what will be created, changed, or destroyed.

---

## 11. Ansible Examples

**Ansible** installs and configures software on servers automatically. If Terraform *builds the house*, Ansible *furnishes the rooms* — installs Java, sets up NiFi, and applies your config.

> Ansible uses YAML files called **playbooks**. Indentation matters — use spaces, not tabs.

### 11.1 Inventory File (Which Servers?)

```ini
# inventory.ini
[nifi_nodes]
nifi-node-1 ansible_host=10.0.1.10
nifi-node-2 ansible_host=10.0.1.11
nifi-node-3 ansible_host=10.0.1.12

[nifi_nodes:vars]
ansible_user=ec2-user
ansible_ssh_private_key_file=~/.ssh/my-key.pem
```

### 11.2 Main Playbook (Install NiFi)

```yaml
# install_nifi.yml
---
- name: Install and configure Apache NiFi
  hosts: nifi_nodes
  become: true          # run as admin (sudo)

  vars:
    nifi_version: "2.0.0"
    nifi_home: "/opt/nifi"
    java_package: "java-21-amazon-corretto-headless"
    nifi_user: "nifi"

  tasks:
    - name: Install Java
      ansible.builtin.package:
        name: "{{ java_package }}"
        state: present

    - name: Create nifi user
      ansible.builtin.user:
        name: "{{ nifi_user }}"
        shell: /bin/bash
        create_home: true

    - name: Download NiFi
      ansible.builtin.get_url:
        url: "https://dlcdn.apache.org/nifi/{{ nifi_version }}/nifi-{{ nifi_version }}-bin.zip"
        dest: "/tmp/nifi-{{ nifi_version }}-bin.zip"
        mode: "0644"

    - name: Unzip NiFi
      ansible.builtin.unarchive:
        src: "/tmp/nifi-{{ nifi_version }}-bin.zip"
        dest: "/opt"
        remote_src: true
        creates: "/opt/nifi-{{ nifi_version }}"

    - name: Create symlink to nifi home
      ansible.builtin.file:
        src: "/opt/nifi-{{ nifi_version }}"
        dest: "{{ nifi_home }}"
        state: link

    - name: Set ownership of NiFi files
      ansible.builtin.file:
        path: "/opt/nifi-{{ nifi_version }}"
        owner: "{{ nifi_user }}"
        group: "{{ nifi_user }}"
        recurse: true

    - name: Deploy nifi.properties from template
      ansible.builtin.template:
        src: templates/nifi.properties.j2
        dest: "{{ nifi_home }}/conf/nifi.properties"
        owner: "{{ nifi_user }}"
        group: "{{ nifi_user }}"
      notify: Restart NiFi

    - name: Install NiFi systemd service
      ansible.builtin.template:
        src: templates/nifi.service.j2
        dest: /etc/systemd/system/nifi.service
      notify: Restart NiFi

    - name: Enable and start NiFi
      ansible.builtin.systemd:
        name: nifi
        enabled: true
        state: started
        daemon_reload: true

  handlers:
    - name: Restart NiFi
      ansible.builtin.systemd:
        name: nifi
        state: restarted
        daemon_reload: true
```

### 11.3 A Config Template (templates/nifi.properties.j2)

```jinja
# This file is managed by Ansible. Do not edit by hand.
nifi.web.https.host=0.0.0.0
nifi.web.https.port=8443
nifi.web.http.port=

nifi.flowfile.repository.directory=/data/flowfile_repository
nifi.content.repository.directory.default=/data/content_repository
nifi.provenance.repository.directory.default=/data/provenance_repository

{% if groups['nifi_nodes'] | length > 1 %}
nifi.cluster.is.node=true
nifi.cluster.node.address={{ ansible_host }}
nifi.cluster.node.protocol.port=11443
{% endif %}
```

### 11.4 Running Ansible

```bash
# Test connection to all servers
ansible -i inventory.ini nifi_nodes -m ping

# Preview changes without applying (dry run)
ansible-playbook -i inventory.ini install_nifi.yml --check

# Actually run it
ansible-playbook -i inventory.ini install_nifi.yml

# Run with detailed output for debugging
ansible-playbook -i inventory.ini install_nifi.yml -vvv
```

> **Best practice:** Use `--check` (dry run) first. Store secrets with **Ansible Vault**, never in plain playbooks:
> ```bash
> ansible-vault encrypt secrets.yml
> ansible-playbook -i inventory.ini install_nifi.yml --ask-vault-pass
> ```

---

## 12. Monitoring Tools Setup

Here's how to actually *watch* NiFi automatically. We'll cover three common tools.

### 12.1 CloudWatch Agent (AWS Native)

The CloudWatch Agent sends disk, memory, and CPU stats from your server to AWS, where you can set alarms.

**Install and configure:**

```bash
# Amazon Linux 2023
sudo dnf install -y amazon-cloudwatch-agent
```

**Config file** (`/opt/aws/amazon-cloudwatch-agent/etc/config.json`):

```json
{
  "metrics": {
    "namespace": "CWAgent",
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/", "/data"],
        "metrics_collection_interval": 60
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/opt/nifi/logs/nifi-app.log",
            "log_group_name": "/nifi/app",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
```

**Start the agent:**

```bash
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
```

### 12.2 Prometheus + Grafana (Popular Open-Source Combo)

- **Prometheus** collects numbers (metrics) over time.
- **Grafana** draws pretty dashboards and graphs from them.

NiFi can publish metrics that Prometheus reads. In NiFi, add a **PrometheusReportingTask** (via the UI: Controller Settings → Reporting Tasks). It exposes metrics on a port (default `9092`).

**Prometheus config** (`prometheus.yml`):

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'nifi'
    scheme: https
    tls_config:
      insecure_skip_verify: true   # only for self-signed; use real certs in prod
    static_configs:
      - targets: ['nifi-node-1:9092', 'nifi-node-2:9092', 'nifi-node-3:9092']
```

**What to graph in Grafana:**

- JVM heap usage over time.
- FlowFiles queued per connection.
- Bytes read/written per processor.
- Active thread count.
- Back pressure events.

### 12.3 A Simple Health-Check Script (Cron Job)

For a lightweight approach, run a script every 5 minutes that checks NiFi and alerts if it's down.

```bash
#!/bin/bash
# nifi_healthcheck.sh — basic health check with alert

NIFI_URL="https://localhost:8443/nifi-api/system-diagnostics"
SNS_TOPIC="arn:aws:sns:us-east-1:123456789012:nifi-alerts"

# Check if NiFi answers
if ! curl -k -s -f "$NIFI_URL" > /dev/null; then
    aws sns publish --topic-arn "$SNS_TOPIC" \
      --subject "NiFi DOWN on $(hostname)" \
      --message "NiFi is not responding on $(hostname) at $(date)"
    echo "ALERT SENT: NiFi is down"
    exit 1
fi

# Check disk usage on the data volume
DISK_USE=$(df /data | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_USE" -gt 80 ]; then
    aws sns publish --topic-arn "$SNS_TOPIC" \
      --subject "NiFi disk HIGH on $(hostname)" \
      --message "Disk on /data is ${DISK_USE}% full on $(hostname)"
    echo "ALERT SENT: Disk high"
fi

echo "Health check complete."
```

**Schedule it with cron:**

```bash
# Edit the nifi user's crontab
sudo -u nifi crontab -e

# Add this line — runs every 5 minutes
*/5 * * * * /opt/nifi/scripts/nifi_healthcheck.sh >> /var/log/nifi_healthcheck.log 2>&1
```

---

## 13. Best Practices Cheat Sheet

Pin this to the wall.

### Security

- Keep NiFi in a **private subnet**.
- Open only the **ports you need**, to only the **people who need them**.
- Use **HTTPS (8443)**, never plain HTTP in production.
- Store passwords in **Secrets Manager** or **Ansible Vault** — never in plain files.
- Give IAM roles **least privilege**.
- **Encrypt** all EBS volumes and S3 buckets.

### Reliability

- Run NiFi as a **dedicated user**, never as root.
- Put the **three repositories on separate disks**.
- Give NiFi about **half the server's RAM** as heap (tune from there).
- Set up a **cluster of 3+ nodes** for production so one failure doesn't stop everything.
- **Back up** your `conf/` folder and flow definitions regularly.

### Operations

- **Automate** everything with Terraform + Ansible so setups are repeatable.
- Always **preview** changes: `terraform plan` and `ansible-playbook --check`.
- Set up **alerts** for disk, memory, back pressure, and node health.
- Keep NiFi **updated** — apply security patches promptly.
- **Document** your flows and label processors clearly.
- Watch the **logs** and **bulletins** daily.

### Capacity

- Watch disk usage — **never let repositories fill past 80%**.
- Watch heap — sustained **over 80%** means you need more memory or tuning.
- Watch back pressure — red queues mean a bottleneck to fix.

---

## 14. Troubleshooting Common Problems

| Problem | Likely cause | What to check / do |
|---|---|---|
| NiFi won't start | Java wrong version, or bad config | `java -version`; check `nifi-app.log` and `nifi-bootstrap.log` |
| Can't reach the UI | Security Group or wrong port | Confirm port 8443 open to your IP; `ss -tlnp \| grep 8443` |
| "OutOfMemory" errors | Heap too small | Increase `-Xmx` in `bootstrap.conf`, restart |
| Disk full, NiFi frozen | Repository disk at 100% | `df -h`; clear space; move repos to bigger disk |
| Queues turning red | Back pressure — slow downstream box | Find the slow processor; tune or scale it |
| Node "disconnected" | Network or cluster port blocked | Check ports 11443, 6342, 2181 between nodes |
| Forgot admin password | Credentials not saved | Re-run `set-single-user-credentials` |
| Browser security warning | Self-signed certificate | Expected — use real certs / ACM for production |
| Slow performance | Disks too slow or one shared disk | Use `gp3`/faster disks; separate the repositories |

### First Steps for ANY Problem

1. **Check if it's running:** `sudo systemctl status nifi`
2. **Read the main log:** `tail -n 100 /opt/nifi/logs/nifi-app.log`
3. **Check disk:** `df -h`
4. **Check memory:** `free -h`
5. **Check the specific error** — search the log for the word "ERROR" or "WARN".

---

*End of guide. Keep this document with your team's runbook and update it as your environment changes.*
