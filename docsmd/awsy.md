# Cloud Team Leader Playbook: Supporting a Data Applications Team on AWS

**Written in plain, easy language (middle-school friendly), but with real commands and real AWS details.**

Our data team runs: **Kafka** (message pipes), **Databricks** (big data notebooks/Spark), **OpenSearch** (search + dashboards), plus **regular EC2 apps** and **EKS clusters** (Kubernetes).

---

## Part 1: The Big Picture (What Are We Building?)

Think of AWS like a big office building we rent:

| AWS Thing | Real-World Picture |
|---|---|
| **VPC** | Our own private floor in the building |
| **Subnet** | A room on our floor |
| **Public subnet** | A room with a window/door to the street (internet) |
| **Private subnet** | A room in the middle with no street door |
| **Security Group (SG)** | A bodyguard standing at each computer's door |
| **NACL** | A guard at the door of the whole room |
| **Internet Gateway (IGW)** | The building's front door to the street |
| **NAT Gateway** | A mail slot: inside people can send stuff OUT, but strangers can't come IN |
| **Route Table** | The hallway map that says "to get to X, go this way" |

**Golden rule:** Databases, Kafka, OpenSearch, and app servers live in **private rooms**. Only load balancers and bastion-type things live in **public rooms**.

---

## Part 2: Scenario — Build the VPC

### 2.1 The Plan (draw it first!)

```
VPC: 10.20.0.0/16  (65,536 addresses — plenty of room to grow)

                        INTERNET
                           |
                    [Internet Gateway]
                           |
   +---------------- PUBLIC SUBNETS ----------------+
   | 10.20.0.0/24 (AZ-a)   |  10.20.1.0/24 (AZ-b)   |
   |  - ALB (web door)     |   - NAT Gateway        |
   |  - Bastion (optional) |                        |
   +----------------------------------------------- +
                           |
   +---------------- PRIVATE APP SUBNETS -----------+
   | 10.20.10.0/24 (AZ-a)  |  10.20.11.0/24 (AZ-b)  |
   |  - EC2 apps           |   - EKS worker nodes   |
   |  - Command/Admin EC2  |                        |
   +------------------------------------------------+
                           |
   +---------------- PRIVATE DATA SUBNETS ----------+
   | 10.20.20.0/24 (AZ-a)  |  10.20.21.0/24 (AZ-b)  |
   |  - Kafka brokers      |   - OpenSearch nodes   |
   |  - Databricks ENIs    |                        |
   +------------------------------------------------+
```

Why two of everything? **Two Availability Zones (AZs)** = if one AWS data center has a bad day, our stuff in the other one keeps running.

### 2.2 The Ports We Care About (memorize-ish)

| Service | Port(s) | Who Talks To It |
|---|---|---|
| SSH | 22 | Admins only (better: use SSM, port-less!) |
| HTTPS (web) | 443 | External clients via ALB; browsers |
| HTTP | 80 | Only to redirect to 443 |
| Kafka brokers | 9092 (plain), 9093/9094 (TLS/SASL) | Apps, Databricks, EKS pods |
| Zookeeper (older Kafka) | 2181 | Kafka brokers only |
| Kafka (KRaft controller) | 9095 (custom) | Brokers only |
| OpenSearch API | 9200 | Apps, Databricks |
| OpenSearch node-to-node | 9300 | OpenSearch nodes only |
| OpenSearch Dashboards | 5601 | Internal users via browser |
| Databricks (secure cluster connectivity) | 443 outbound | Databricks control plane |
| EKS API server | 443 | kubectl users, worker nodes |
| Kubelet | 10250 | EKS control plane → nodes |
| NodePort range (EKS) | 30000–32767 | Internal load balancers |
| App servers | 8080/8443 | ALB only |

### 2.3 Internal vs External Clients

- **External clients** (customers on the internet): they may ONLY touch the **ALB on 443** in the public subnet. Never Kafka. Never OpenSearch directly.
- **Internal clients** (our apps, other VPCs, office VPN): they connect over **private IPs** to Kafka 9092/9093, OpenSearch 9200, dashboards 5601, etc.

---

## Part 3: Security Groups (The Bodyguards)

Security groups are **stateful**: if you let a request in, the answer is automatically allowed back out. Big time-saver.

**Pro trick: SGs can reference other SGs.** Instead of "allow 10.20.10.0/24," say "allow anyone wearing the `sg-app` badge." Then it works forever, even when IPs change.

### The set we create:

```
sg-alb        : IN: 443 from 0.0.0.0/0 (the world), 80 from 0.0.0.0/0
sg-app        : IN: 8080/8443 from sg-alb          <- only the ALB may knock
sg-kafka      : IN: 9092-9094 from sg-app, sg-eks-nodes, sg-databricks, sg-admin
                IN: 9092-9095 from sg-kafka         <- brokers talk to each other
sg-opensearch : IN: 9200 from sg-app, sg-eks-nodes, sg-databricks, sg-admin
                IN: 9300 from sg-opensearch         <- node gossip
                IN: 5601 from sg-admin (or internal ALB SG)
sg-eks-nodes  : IN: all traffic from sg-eks-nodes (pods chat freely)
                IN: 10250, 443 from sg-eks-control
sg-admin      : IN: 22 from your office CIDR only (or NOTHING if pure SSM)
                (attached to the Command EC2)
sg-databricks : per Databricks docs; needs 443 out to control plane,
                and self-referencing rules for cluster traffic
```

**Outbound:** default "allow all out" is common; tighten later for data subnets (e.g., only 443 to S3/updates, 9092 to Kafka SG).

### CLI example — create sg-kafka and let apps in:

```bash
aws ec2 create-security-group \
  --group-name sg-kafka --description "Kafka brokers" \
  --vpc-id vpc-0abc123

aws ec2 authorize-security-group-ingress \
  --group-id sg-0kafka111 \
  --protocol tcp --port 9092-9094 \
  --source-group sg-0app222
```

---

## Part 4: NACLs (The Room Guards)

NACLs are **stateless**: you must allow traffic **in AND the reply back out**. Replies come back on **ephemeral ports 1024–65535**.

**Team strategy: keep NACLs simple.** Use them as a coarse safety net; do the fine-grained work in Security Groups.

Example NACL for the **private data subnets**:

| Rule # | Direction | Port | Source/Dest | Action |
|---|---|---|---|---|
| 100 | IN | 9092–9094 | 10.20.0.0/16 | ALLOW |
| 110 | IN | 9200, 9300, 5601 | 10.20.0.0/16 | ALLOW |
| 120 | IN | 22 | 10.20.10.0/24 | ALLOW |
| 130 | IN | 1024–65535 | 0.0.0.0/0 | ALLOW (replies to outbound calls) |
| * | IN | all | all | DENY (built-in) |
| 100 | OUT | all | 10.20.0.0/16 | ALLOW |
| 110 | OUT | 443 | 0.0.0.0/0 | ALLOW (patches, S3, Databricks control plane) |
| 120 | OUT | 1024–65535 | 10.20.0.0/16 | ALLOW (replies) |
| * | OUT | all | all | DENY |

**Lowest rule number wins first match.** Leave gaps (100, 110, 120...) so you can insert rules later.

---

## Part 5: Route Tables (The Hallway Maps)

```
Public route table:
  10.20.0.0/16 -> local
  0.0.0.0/0    -> igw-xxxx        (street door)

Private route table:
  10.20.0.0/16 -> local
  0.0.0.0/0    -> nat-xxxx        (mail slot: out only)
  S3           -> vpce (Gateway Endpoint, FREE, saves NAT $$)
```

**Add VPC endpoints** (private tunnels, no internet needed) for: **S3 (gateway), SSM, SSMMessages, EC2Messages, ECR (api+dkr), CloudWatch Logs, STS**. This is what makes SSM work in private subnets *and* cuts NAT gateway costs a lot.

---

## Part 6: Testing! (Prove It Works)

We use a **Command EC2** (a small admin box, e.g., t3.small, Amazon Linux 2023) in a private app subnet with `sg-admin` and an **SSM instance profile** (`AmazonSSMManagedInstanceCore` policy).

### 6.1 Connect with SSM (no SSH keys, no port 22 open — the modern way)

```bash
# From your laptop (AWS CLI + Session Manager plugin installed):
aws ssm start-session --target i-0abc1234567890

# You now have a shell. No open inbound ports at all. Magic (well, VPC endpoints).
```

### 6.2 Connect with SSH (the classic way, if allowed)

```bash
ssh -i mykey.pem ec2-user@10.20.10.15        # from bastion/VPN
# Or SSH *over* SSM (best of both — no open 22):
aws ssm start-session --target i-0abc123 \
  --document-name AWS-StartSSHSession
```

### 6.3 Test each service from the Command EC2

```bash
# Is the port open? (nc = netcat; -z just checks, -v is chatty)
nc -zv kafka-b1.internal 9092        # Kafka
nc -zv opensearch.internal 9200      # OpenSearch API
nc -zv opensearch.internal 5601      # Dashboards

# Real Kafka test (needs kafka CLI tools installed):
kafka-topics.sh --bootstrap-server kafka-b1.internal:9092 --list
kafka-console-producer.sh --bootstrap-server kafka-b1.internal:9092 --topic test
kafka-console-consumer.sh --bootstrap-server kafka-b1.internal:9092 --topic test --from-beginning

# Real OpenSearch test:
curl -s https://opensearch.internal:9200/_cluster/health?pretty -u admin -k

# EKS test:
aws eks update-kubeconfig --name data-eks --region us-east-1
kubectl get nodes
kubectl run nettest --rm -it --image=busybox -- nc -zv kafka-b1.internal 9092
```

If `nc` **times out** → security group or NACL or route problem.
If `nc` says **connection refused** → network is FINE, but the app isn't listening (service down or wrong port).
That one sentence solves half your tickets.

### 6.4 Test from a browser

- **External:** open `https://app.example.com` → hits ALB (443) → ALB forwards to app on 8080. If it loads: public path works.
- **Internal (OpenSearch Dashboards on 5601):** use **SSM port forwarding** — a private tunnel to your laptop:

```bash
aws ssm start-session --target i-0abc123 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["opensearch.internal"],"portNumber":["5601"],"localPortNumber":["5601"]}'

# Now open http://localhost:5601 in your browser. Done!
```

Same trick works for any internal web UI (Kafka UI, Grafana, Spark UI, etc.).

---

## Part 7: Review Checklist (Before We Call It Done)

- [ ] Nothing in data subnets has a public IP
- [ ] No security group has `0.0.0.0/0` except `sg-alb` on 80/443
- [ ] SGs reference SGs, not hard-coded IPs
- [ ] VPC endpoints exist for SSM/S3/ECR/Logs
- [ ] VPC Flow Logs turned ON (they're our security camera footage)
- [ ] Two AZs for everything important
- [ ] Everything is tagged: `Team`, `Env`, `App`, `CostCenter`
- [ ] IMDSv2 required on all EC2 (`HttpTokens=required`)
- [ ] Tested: SSM session, nc to every port, browser via ALB, browser via port-forward

---

## Part 8: Multi-VPC Strategy (Keeping It Simple)

As we grow: **dev VPC, staging VPC, prod VPC**, maybe a **shared-services VPC** (CI/CD, monitoring, DNS).

**Rules that save your sanity:**
1. **Never overlap CIDRs.** Keep a spreadsheet/IPAM: dev=10.10/16, staging=10.20/16, prod=10.30/16, shared=10.0/16.
2. **Use Transit Gateway (TGW)** as the central train station once you pass ~3 VPCs. VPC peering is fine for 2–3, but peering doesn't scale (no transitive routing — A↔B and B↔C does NOT give you A↔C).
3. **Route 53 private hosted zones** shared across VPCs so `kafka.prod.internal` works everywhere.
4. **Prod cannot talk to dev.** Ever. Use separate TGW route tables to enforce it.
5. **PrivateLink** for exposing one service (like an internal API) to another VPC without opening the whole network.
6. Same subnet layout pattern in every VPC → everyone always knows where things live.

---

## Part 9: Infrastructure as Code (CloudFormation, Terraform, Ansible)

**Who does what:**
- **Terraform / CloudFormation** = *build the building* (VPC, subnets, SGs, EKS, MSK, OpenSearch domains).
- **Ansible** = *furnish the rooms* (install Kafka on EC2, tune configs, deploy app files, patch).
- Team rule: **pick Terraform OR CloudFormation as primary** (not both for the same resources), keep state safe, and NO console click-ops in prod.

### 9.1 Terraform snippet (VPC + one SG)

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  name    = "data-prod"
  cidr    = "10.20.0.0/16"
  azs     = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnets = ["10.20.10.0/24", "10.20.11.0/24",
                     "10.20.20.0/24", "10.20.21.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = false   # one per AZ in prod
  enable_flow_log    = true
}

resource "aws_security_group" "kafka" {
  name   = "sg-kafka"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port       = 9092
    to_port         = 9094
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
}
```

Keep state in **S3 + DynamoDB lock**, one state per env, plan in PR, apply via pipeline.

### 9.2 CloudFormation snippet (same idea)

```yaml
Resources:
  KafkaSG:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Kafka brokers
      VpcId: !Ref DataVPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 9092
          ToPort: 9094
          SourceSecurityGroupId: !Ref AppSG
```

Use **StackSets** to stamp the same baseline into every account.

### 9.3 Ansible snippet (configure Kafka on EC2)

```yaml
- hosts: kafka_brokers
  become: yes
  tasks:
    - name: Install Java
      dnf: { name: java-17-amazon-corretto, state: present }
    - name: Push broker config
      template:
        src: server.properties.j2
        dest: /opt/kafka/config/server.properties
      notify: restart kafka
  handlers:
    - name: restart kafka
      systemd: { name: kafka, state: restarted }
```

Use **dynamic inventory** (`amazon.aws.aws_ec2` plugin, grouped by tags) so Ansible finds brokers automatically. Bonus: run Ansible **through SSM** (`community.aws.aws_ssm` connection) — no SSH needed at all.

---

## Part 10: Base AMIs (Prerequisites Before Apps Install)

Build **golden AMIs** with **EC2 Image Builder** or **Packer**, monthly + on CVEs.

**Layer cake:**
1. **Base AMI (everyone):** Amazon Linux 2023 (or Ubuntu 22.04 LTS) + latest patches + SSM agent + CloudWatch agent + our CA certs + security hardening (CIS-ish) + IMDSv2 enforced + admin users/groups + chrony (time sync).
2. **Java AMI** (base + Corretto 17): for **Kafka**, and Java apps. Kafka also wants: XFS data volume, `vm.swappiness=1`, raised file limits (`nofile=100000`), tuned network sysctls.
3. **OpenSearch AMI** (Java AMI +): `vm.max_map_count=262144`, `bootstrap.memory_lock` support, heap = 50% of RAM (max ~31GB), dedicated data volume. (Or skip and use the **managed OpenSearch Service**.)
4. **EKS nodes:** use the **AWS EKS-optimized AMI** — don't hand-roll unless forced.
5. **Databricks:** control plane is managed; workers use Databricks' images in *our* VPC subnets — we just supply subnets + SGs + endpoints.
6. **Python/tooling AMI:** for the Command EC2 and generic apps — python3, docker, git, kafka CLI tools, jq, htop, nc.

**Team lean-manager note:** prefer **MSK** (managed Kafka) and **OpenSearch Service** when possible — AWS runs the servers, we run the data. Self-managed EC2 clusters only when we need special versions/configs.

---

## Part 11: Common Tasks & Work Goals (The Team's To-Do Universe)

### Daily / Weekly Operations
- Check dashboards: Kafka consumer lag, OpenSearch cluster health (green/yellow/red), EKS pod restarts, disk %, CPU/mem
- Review CloudWatch alarms + PagerDuty/on-call handoffs
- Patch cycle status (SSM Patch Manager compliance report)
- Certificate expiry check (ACM auto-renews; self-managed certs don't!)
- Cost check: NAT data charges, idle EC2, oversized nodes
- Backup verification: EBS snapshots ran, OpenSearch snapshots to S3 succeeded

### Regular Work Goals (sprint-sized)
- Onboard a new app: subnet placement → SG rules → IAM role → DNS record → monitoring → runbook
- Add a Kafka topic (partitions, replication=3, retention) + ACLs
- Scale: add Kafka broker / OpenSearch data node / EKS node group; resize instances
- Upgrade: Kafka version rolling upgrade, EKS version (control plane → node groups → addons), OpenSearch rolling upgrade
- Rotate secrets/keys (Secrets Manager rotation), rotate certs
- DR drill: restore from snapshot into a scratch VPC, time it
- IaC hygiene: eliminate drift (`terraform plan` clean), module upgrades
- Access reviews: who can SSM to prod? Trim it.

### Ad-hoc / Ticket-driven
- "Open port X from app Y to service Z" → add SG rule **in Terraform**, not console
- "Give team read access to OpenSearch Dashboards"
- "Whitelist partner IP on the ALB / WAF"
- "Copy prod topic data to staging" (MirrorMaker2 / scripts)
- "Why is my job slow?" (usually: consumer lag, disk, or undersized cluster)

---

## Part 12: Debugging & Troubleshooting Runbook

### 12.1 "I can't connect!" — the ladder (climb one rung at a time)

```bash
# 1. DNS: does the name resolve?
dig kafka-b1.internal +short

# 2. Route: can we even reach the subnet?
ping 10.20.20.11            # (if ICMP allowed)
traceroute 10.20.20.11

# 3. Port: is the door open?
nc -zv 10.20.20.11 9092
#   timeout            -> SG / NACL / route blocking
#   connection refused -> network OK, app not listening

# 4. Is the app listening on the box? (SSM in and check)
sudo ss -tlnp | grep 9092

# 5. What do the SGs actually say?
aws ec2 describe-security-groups --group-ids sg-0kafka111 \
  --query 'SecurityGroups[].IpPermissions'

# 6. Ask AWS to referee (this tool is GOLD — it tells you exactly what blocked it):
aws ec2 create-network-insights-path \
  --source i-0app --destination i-0kafka --destination-port 9092 --protocol tcp
# then start-network-insights-analysis and read the verdict

# 7. VPC Flow Logs: look for REJECT lines
#    (CloudWatch Logs Insights)
fields @timestamp, srcAddr, dstAddr, dstPort, action
| filter dstPort = 9092 and action = "REJECT"
| sort @timestamp desc | limit 50
```

### 12.2 Disk space full / reconfigure disk (very common!)

```bash
# Find the pig:
df -h                                   # which filesystem is full?
sudo du -xh / --max-depth=2 | sort -rh | head -20
sudo journalctl --vacuum-size=200M      # shrink system logs

# Grow an EBS volume WITHOUT downtime:
# 1) Resize the volume (console or CLI):
aws ec2 modify-volume --volume-id vol-0abc123 --size 500

# 2) On the instance, grow the partition:
lsblk                                   # see disks & partitions
sudo growpart /dev/nvme1n1 1            # grow partition 1

# 3) Grow the filesystem:
sudo xfs_growfs /data                   # XFS (Kafka/OpenSearch standard)
sudo resize2fs /dev/nvme1n1p1           # ext4

df -h                                   # confirm. Done — no reboot!
```

Kafka-specific disk pressure: shorten `retention.ms`/`retention.bytes` on fat topics, check for stuck compaction. OpenSearch: delete old indices via **ISM policies** (auto-delete after N days), watch the **85% watermark** (node stops accepting shards) and **95% flood stage** (indices go read-only — fix disk, then clear the read-only block).

### 12.3 Quick service triage

```bash
# Kafka
kafka-consumer-groups.sh --bootstrap-server b1:9092 --describe --group mygroup   # LAG column!
kafka-topics.sh --bootstrap-server b1:9092 --describe --under-replicated-partitions

# OpenSearch
curl -s https://os:9200/_cluster/health?pretty          # red? yellow?
curl -s https://os:9200/_cat/allocation?v               # disk per node
curl -s https://os:9200/_cluster/allocation/explain?pretty   # WHY is a shard unassigned

# EKS
kubectl get pods -A | grep -v Running
kubectl describe pod <p>            # read Events at the bottom — the answer is usually there
kubectl logs <p> --previous         # logs from the crashed run
kubectl top nodes                   # out of CPU/mem?

# EC2 app
systemctl status myapp; journalctl -u myapp -n 100
top; free -h; df -h                 # the classic trio
```

### 12.4 SSM broken? ("instance not showing in Session Manager")
Check the big four: (1) SSM agent running (`systemctl status amazon-ssm-agent`), (2) instance profile has `AmazonSSMManagedInstanceCore`, (3) VPC endpoints for ssm/ssmmessages/ec2messages exist (private subnets), (4) SG on the endpoints allows 443 from the VPC.

---

## Part 13: Strategy Summary (The Poster on the Wall)

1. **Private by default.** Public subnet = ALB + NAT only.
2. **SGs do the precise work; NACLs stay simple.**
3. **SSM over SSH.** No keys to lose, everything audited.
4. **Everything is code** (Terraform builds, Ansible configures, pipelines apply).
5. **Golden AMIs**, rebuilt monthly, apps assume the base is ready.
6. **Managed services first** (MSK, OpenSearch Service, EKS) — we manage data, not servers.
7. **Two AZs minimum. Tags on everything. Flow logs on.**
8. **CIDR plan owned by one spreadsheet/IPAM; TGW for multi-VPC; prod isolated.**
9. **Runbooks for the top 10 tickets** — new teammates fix things on day one.
10. **"Timeout = network, refused = app."** Teach it to everyone.

---

## Part 14: Testing with AWS CLI + Python + Lambda (Hands-On Lab)

Three ways to test the same things:
1. **AWS CLI** = quick questions from your terminal ("hey AWS, what's the setup?")
2. **Python (boto3 + sockets)** = repeatable test scripts you can run anytime
3. **Lambda** = a robot INSIDE the VPC that tests connectivity for you, on a schedule

### 14.1 AWS CLI: Inspect the Network (read-only, always safe)

```bash
# Find your VPC and everything in it
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=data-prod" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' --output table

# List subnets with their type tags
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-0abc123" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# What rules does the Kafka SG really have right now?
aws ec2 describe-security-groups --group-ids sg-0kafka111 \
  --query 'SecurityGroups[].IpPermissions[].{Ports:join(`-`,[to_string(FromPort),to_string(ToPort)]),From:IpRanges[].CidrIp,FromSG:UserIdGroupPairs[].GroupId}' \
  --output table

# Which instances are wearing the app SG badge?
aws ec2 describe-instances \
  --filters "Name=instance.group-id,Values=sg-0app222" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{ID:InstanceId,IP:PrivateIpAddress,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# NACLs on the data subnet
aws ec2 describe-network-acls \
  --filters "Name=association.subnet-id,Values=subnet-0data111" \
  --query 'NetworkAcls[].Entries[?Egress==`false`]' --output table
```

### 14.2 AWS CLI: Run a Test Command on a Server WITHOUT Logging In

SSM `send-command` = "hey server, run this and tell me what happened."

```bash
# Test Kafka port from the app server, remotely:
aws ssm send-command \
  --instance-ids i-0app12345 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["nc -zv kafka-b1.internal 9092 2>&1","curl -sk https://opensearch.internal:9200/_cluster/health | head -c 300"]' \
  --query 'Command.CommandId' --output text
# Returns a CommandId, e.g. 1a2b3c4d-...

# Get the answer:
aws ssm get-command-invocation \
  --command-id 1a2b3c4d-... \
  --instance-id i-0app12345 \
  --query '{Status:Status,Output:StandardOutputContent,Errors:StandardErrorContent}'
```

This is HUGE for a team lead: you can test connectivity from **any** instance's point of view without SSH keys or sessions.

### 14.3 AWS CLI: Reachability Analyzer (AWS referees the argument)

```bash
# "Can the app instance reach the Kafka instance on 9092?"
PATH_ID=$(aws ec2 create-network-insights-path \
  --source i-0app12345 --destination i-0kafka678 \
  --protocol tcp --destination-port 9092 \
  --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)

ANALYSIS_ID=$(aws ec2 start-network-insights-analysis \
  --network-insights-path-id $PATH_ID \
  --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text)

sleep 30   # give it a moment to think

aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids $ANALYSIS_ID \
  --query 'NetworkInsightsAnalyses[].{Reachable:NetworkPathFound,Blocker:Explanations[0].ExplanationCode}'
# Reachable: false + Blocker: "ENI_SG_RULES_MISMATCH" -> it literally names the guilty SG!
```

### 14.4 Python: The Team's Connectivity Test Script

Runs on the Command EC2 (or your laptop over VPN). Pure sockets + boto3. Save as `nettest.py`:

```python
#!/usr/bin/env python3
"""Team connectivity smoke test. Usage: python3 nettest.py"""
import socket, json, boto3

TARGETS = [
    ("kafka-b1.internal",     9092, "Kafka plaintext"),
    ("kafka-b1.internal",     9093, "Kafka TLS"),
    ("opensearch.internal",   9200, "OpenSearch API"),
    ("opensearch.internal",   5601, "OS Dashboards"),
    ("app1.internal",         8080, "App server"),
]

def check_port(host, port, timeout=3):
    """Returns 'OPEN', 'REFUSED' (app down), or 'TIMEOUT' (network block)."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return "OPEN"
    except ConnectionRefusedError:
        return "REFUSED (network OK, app not listening!)"
    except (socket.timeout, TimeoutError):
        return "TIMEOUT (check SG / NACL / route)"
    except socket.gaierror:
        return "DNS FAIL (check Route 53 / resolver)"

print(f"{'Service':<22}{'Target':<32}{'Result'}")
print("-" * 75)
ok = True
for host, port, name in TARGETS:
    result = check_port(host, port)
    if result != "OPEN":
        ok = False
    print(f"{name:<22}{host+':'+str(port):<32}{result}")

# Bonus: ask AWS if any SG is wide open to the world (bad!)
ec2 = boto3.client("ec2")
sgs = ec2.describe_security_groups()["SecurityGroups"]
for sg in sgs:
    for rule in sg["IpPermissions"]:
        for r in rule.get("IpRanges", []):
            if r.get("CidrIp") == "0.0.0.0/0" and rule.get("FromPort") not in (80, 443, None):
                print(f"\nWARNING: {sg['GroupId']} ({sg['GroupName']}) "
                      f"open to WORLD on port {rule.get('FromPort')}")

exit(0 if ok else 1)   # exit code -> usable in CI pipelines!
```

Run it:

```bash
pip3 install boto3
python3 nettest.py
echo $?     # 0 = all green, 1 = something failed
```

### 14.5 Python: Real Kafka Produce/Consume Test

```python
#!/usr/bin/env python3
"""End-to-end Kafka test: send a message, read it back. pip3 install kafka-python"""
import time, uuid
from kafka import KafkaProducer, KafkaConsumer

BROKERS = ["kafka-b1.internal:9092"]
TOPIC   = "team-smoketest"
marker  = f"smoke-{uuid.uuid4()}"

# 1. Send
producer = KafkaProducer(bootstrap_servers=BROKERS)
producer.send(TOPIC, marker.encode())
producer.flush()
print(f"Sent: {marker}")

# 2. Read it back
consumer = KafkaConsumer(
    TOPIC, bootstrap_servers=BROKERS,
    auto_offset_reset="latest", consumer_timeout_ms=10000,
    group_id=f"smoketest-{uuid.uuid4()}",
)
found = any(msg.value.decode() == marker for msg in consumer)
print("Kafka round-trip: PASS" if found else "Kafka round-trip: FAIL")
```

### 14.6 Python: OpenSearch Health Test

```python
#!/usr/bin/env python3
"""OpenSearch health + write/read test. pip3 install requests"""
import requests, uuid
requests.packages.urllib3.disable_warnings()

OS = "https://opensearch.internal:9200"
AUTH = ("admin", "CHANGE_ME")          # better: pull from Secrets Manager (see 14.7)

h = requests.get(f"{OS}/_cluster/health", auth=AUTH, verify=False).json()
print(f"Cluster: {h['status'].upper()}  nodes={h['number_of_nodes']} "
      f"unassigned_shards={h['unassigned_shards']}")

# Write one doc, read it back, delete it:
doc_id = str(uuid.uuid4())
requests.put(f"{OS}/smoketest/_doc/{doc_id}?refresh=true",
             json={"msg": "hello"}, auth=AUTH, verify=False)
r = requests.get(f"{OS}/smoketest/_doc/{doc_id}", auth=AUTH, verify=False)
print("Write/read: PASS" if r.json().get("found") else "Write/read: FAIL")
requests.delete(f"{OS}/smoketest/_doc/{doc_id}", auth=AUTH, verify=False)
```

### 14.7 Python: Pull Passwords the Right Way (Secrets Manager)

Never hard-code passwords. One tiny function fixes it:

```python
import boto3, json

def get_secret(name, region="us-east-1"):
    sm = boto3.client("secretsmanager", region_name=region)
    return json.loads(sm.get_secret_value(SecretId=name)["SecretString"])

creds = get_secret("prod/opensearch/admin")
AUTH = (creds["username"], creds["password"])
```

The instance's **IAM role** grants access — no keys on disk, ever.

### 14.8 Lambda: A Connectivity Robot That Lives Inside the VPC

Why Lambda? It runs **inside your private subnets**, so it tests connectivity exactly like your apps experience it — and it can run **every 5 minutes forever** for pennies.

**The function** (`lambda_function.py`, Python 3.12 runtime):

```python
import socket, json, os, boto3

TARGETS = json.loads(os.environ.get("TARGETS", """
[
  {"host": "kafka-b1.internal",   "port": 9092, "name": "Kafka"},
  {"host": "opensearch.internal", "port": 9200, "name": "OpenSearch"},
  {"host": "app1.internal",       "port": 8080, "name": "App"}
]"""))

cloudwatch = boto3.client("cloudwatch")

def check(host, port, timeout=3):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return "OPEN"
    except ConnectionRefusedError:
        return "REFUSED"
    except Exception:
        return "TIMEOUT"

def lambda_handler(event, context):
    results, failures = [], []
    for t in TARGETS:
        status = check(t["host"], t["port"])
        results.append({**t, "status": status})
        # Publish 1 (up) or 0 (down) as a custom CloudWatch metric
        cloudwatch.put_metric_data(
            Namespace="Team/Connectivity",
            MetricData=[{
                "MetricName": "PortReachable",
                "Dimensions": [{"Name": "Service", "Value": t["name"]}],
                "Value": 1 if status == "OPEN" else 0,
            }])
        if status != "OPEN":
            failures.append(f"{t['name']} {t['host']}:{t['port']} = {status}")

    print(json.dumps(results))               # lands in CloudWatch Logs
    if failures:
        raise Exception("Connectivity failures: " + "; ".join(failures))
    return {"statusCode": 200, "body": json.dumps(results)}
```

**Deploy it all with the CLI:**

```bash
# 1. Zip the code
zip function.zip lambda_function.py

# 2. Create an IAM role for it (trust policy file first)
cat > trust.json << 'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
aws iam create-role --role-name lambda-nettest --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name lambda-nettest \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole
aws iam attach-role-policy --role-name lambda-nettest \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchFullAccessV2   # tighten in prod

# 3. Create the function INSIDE the VPC (this is the key part!)
aws lambda create-function \
  --function-name vpc-nettest \
  --runtime python3.12 --handler lambda_function.lambda_handler \
  --zip-file fileb://function.zip \
  --role arn:aws:iam::111122223333:role/lambda-nettest \
  --timeout 30 \
  --vpc-config SubnetIds=subnet-0app111,subnet-0app222,SecurityGroupIds=sg-0admin333

# NOTE: sg-0admin333 (the Lambda's SG) must be ALLOWED as a source
# in sg-kafka (9092), sg-opensearch (9200), sg-app (8080). Same badge rules!

# 4. Test it right now:
aws lambda invoke --function-name vpc-nettest --log-type Tail out.json \
  --query 'LogResult' --output text | base64 -d
cat out.json

# 5. Schedule it every 5 minutes (EventBridge):
aws events put-rule --name nettest-5min --schedule-expression "rate(5 minutes)"
aws lambda add-permission --function-name vpc-nettest \
  --statement-id evb --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn arn:aws:events:us-east-1:111122223333:rule/nettest-5min
aws events put-targets --rule nettest-5min \
  --targets "Id=1,Arn=arn:aws:lambda:us-east-1:111122223333:function:vpc-nettest"

# 6. Alarm when anything goes down:
aws cloudwatch put-metric-alarm \
  --alarm-name kafka-unreachable \
  --namespace Team/Connectivity --metric-name PortReachable \
  --dimensions Name=Service,Value=Kafka \
  --statistic Minimum --period 300 --evaluation-periods 2 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:111122223333:team-alerts
```

Now you have a **24/7 monitoring robot** built from ~50 lines of Python. If Kafka's port stops answering, the team gets paged within ~10 minutes — often before users notice.

### 14.9 Lambda: Disk-Space Watchdog (ties into Part 12.2)

CloudWatch agent on each instance publishes `disk_used_percent`. This Lambda checks it and warns the team:

```python
import boto3, datetime

def lambda_handler(event, context):
    cw, sns = boto3.client("cloudwatch"), boto3.client("sns")
    now = datetime.datetime.utcnow()
    resp = cw.get_metric_data(
        StartTime=now - datetime.timedelta(minutes=15), EndTime=now,
        MetricDataQueries=[{
            "Id": "disk",
            "Expression": 'SELECT MAX(disk_used_percent) FROM CWAgent GROUP BY InstanceId',
            "Period": 300,
        }])
    warnings = []
    for series in resp["MetricDataResults"]:
        if series["Values"] and max(series["Values"]) > 85:
            warnings.append(f"{series['Label']}: {max(series['Values']):.0f}% full")
    if warnings:
        sns.publish(
            TopicArn="arn:aws:sns:us-east-1:111122223333:team-alerts",
            Subject="DISK WARNING - over 85%",
            Message="\n".join(warnings) + "\n\nRunbook: Part 12.2 (grow EBS, no downtime)")
    return {"checked": len(resp["MetricDataResults"]), "warnings": warnings}
```

Schedule it hourly with the same EventBridge pattern as 14.8.

### 14.10 CLI + Lambda Testing Cheat Sheet

| I want to... | Use |
|---|---|
| Quickly see SG/subnet/route config | `aws ec2 describe-*` commands (14.1) |
| Test a port from ANOTHER server's viewpoint | `aws ssm send-command` + `nc` (14.2) |
| Get AWS to tell me exactly WHAT is blocking | Reachability Analyzer (14.3) |
| Repeatable smoke test I can run anytime / in CI | `nettest.py` (14.4) |
| Prove Kafka actually works end-to-end | produce/consume script (14.5) |
| Prove OpenSearch works end-to-end | health + write/read script (14.6) |
| Continuous 24/7 checks + paging | VPC Lambda + EventBridge + Alarm (14.8) |
| Catch full disks before they hurt | disk watchdog Lambda (14.9) |

**Lambda-in-VPC gotchas (learn them once):**
- A VPC Lambda has **no internet** unless its subnet routes to a NAT — use **VPC endpoints** for AWS APIs (CloudWatch, SNS, Secrets Manager) instead.
- The Lambda's **security group must be added as a source** in the target SGs (Kafka, OpenSearch, apps) — same badge rule as everything else.
- Put it in **two subnets (two AZs)** just like real apps.
- Keep timeout small (30s) — a hung connectivity test should fail fast.
