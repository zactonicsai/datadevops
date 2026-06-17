# AWS & Linux Infrastructure Administration — Master Runbook

**Scope:** Amazon Linux (AL2 / AL2023), EC2, EKS, ECS, plus application stacks — Kafka, NiFi, OpenSearch, PostgreSQL, FastAPI. Covers admin tasks, sub-tasks, key Linux + AWS CLI commands, *what / why*, troubleshooting steps, and key log locations.

**How to read each task block:** **What** (the action) → **Why** (purpose) → **Commands** → **Troubleshooting** → **Logs**.

-----

## MASTER GROUP INDEX

1. Linux OS Administration
1. YUM / DNF Package Management
1. Patching (OS + Fleet)
1. Disk, Storage & Filesystem
1. EC2 Administration
1. EKS Administration
1. ECS Administration
1. Networking & Connectivity
1. Security Groups, Firewall & TLS
1. IAM, STS & Secrets
1. Monitoring, Logging & Alerting
1. Backup & Disaster Recovery
1. Kafka Administration
1. NiFi Administration
1. OpenSearch Administration
1. PostgreSQL Administration
1. FastAPI Application Support
1. Containers & Registry (Docker/ECR)
1. Ansible (Config Management)
1. Terraform (IaC)
1. CloudFormation (IaC)
1. Key System Components Reference
1. Cross-Cutting Troubleshooting Playbook
1. Key Log Locations — Master Table

-----

# 1. LINUX OS ADMINISTRATION

## 1.1 User & Group Management

- **What:** Create/manage users, groups, sudo access.
- **Why:** Least-privilege access, separate service accounts, auditability.

```bash
useradd -m -s /bin/bash deploy
usermod -aG wheel deploy          # grant sudo (wheel group)
groupadd appteam ; gpasswd -a deploy appteam
passwd deploy
id deploy ; groups deploy
chage -l deploy                    # password/expiry policy
lastlog ; last -a | head           # login history
```

- **Troubleshooting:** “Permission denied” → check group membership (`id`), file ACLs (`getfacl`), and SELinux (`getenforce`). User can’t sudo → verify `/etc/sudoers.d/` entry + `visudo -c`.
- **Logs:** `/var/log/secure` (auth, sudo, ssh), `/var/log/audit/audit.log` (auditd).

## 1.2 Service Management (systemd)

- **What:** Start/stop/enable services and inspect units.
- **Why:** Reliable lifecycle, auto-start on boot, dependency ordering.

```bash
systemctl status nginx
systemctl enable --now kafka
systemctl restart postgresql-15
systemctl daemon-reload                 # after editing unit files
systemctl list-units --type=service --state=running
systemctl list-unit-files | grep enabled
systemctl is-failed kafka
systemctl cat fastapi                    # show effective unit file
```

- **Troubleshooting:** Service won’t start → `systemctl status <svc>` + `journalctl -u <svc> -n 50 --no-pager`; check `ExecStart` path, permissions, port conflicts (`ss -tulpn`). After unit edit failing → forgot `daemon-reload`.
- **Logs:** `journalctl -u <service> -f`, `journalctl -p err -b`.

## 1.3 Process & Resource Inspection

- **What:** Identify CPU/memory/IO hogs.
- **Why:** Diagnose load, OOM risk, runaway processes.

```bash
top -c ; htop
ps aux --sort=-%cpu | head
ps aux --sort=-%mem | head
free -h ; vmstat 2 5
iostat -xz 2 ; iotop
pidstat 2
lsof -p <pid> ; lsof -i :8080
pmap <pid>
```

- **Troubleshooting:** High load avg but low CPU → IO wait (`iostat` %iowait); memory pressure → check `free`, `dmesg | grep -i oom`; zombie/defunct → find parent (`ps -ef | grep defunct`).
- **Logs:** `/var/log/messages`, `dmesg -T`, `journalctl -k` (kernel).

## 1.4 Cron / Scheduled Jobs & systemd Timers

- **What:** Schedule recurring tasks.
- **Why:** Automation of backups, cleanup, health checks.

```bash
crontab -e ; crontab -l ; crontab -l -u deploy
ls /etc/cron.d/ /etc/cron.daily/
systemctl list-timers --all
```

- **Troubleshooting:** Cron job not running → check `/var/log/cron`, absolute paths (cron has minimal PATH), `%` must be escaped, mail output (`MAILTO`).
- **Logs:** `/var/log/cron`, `journalctl -u crond`.

## 1.5 Kernel & sysctl Tuning

- **What:** Tune kernel params (map count, file handles, network buffers).
- **Why:** Kafka/OpenSearch require higher limits; network throughput tuning.

```bash
sysctl -a | grep vm.max_map_count
sysctl -w vm.max_map_count=262144
cat >> /etc/sysctl.d/99-tuning.conf <<'EOF'
vm.max_map_count=262144
vm.swappiness=1
net.core.somaxconn=1024
fs.file-max=2097152
EOF
sysctl --system
ulimit -n ; ulimit -a
```

- File limits in `/etc/security/limits.conf` or `/etc/security/limits.d/`:

```
opensearch  -  nofile  65536
kafka       -  nofile  100000
```

- **Troubleshooting:** “Too many open files” → raise `nofile` (limits.conf + systemd `LimitNOFILE=`); OpenSearch bootstrap check fails → `vm.max_map_count` too low.
- **Logs:** service logs show bootstrap/limit errors; `dmesg` for kernel-level.

## 1.6 Time Sync (chrony)

- **What:** Keep clock accurate.
- **Why:** TLS validity, Kafka/Postgres ordering, log correlation, auth tokens.

```bash
systemctl status chronyd
chronyc sources -v ; chronyc tracking
timedatectl ; timedatectl set-timezone UTC
```

- **Troubleshooting:** Clock drift → chrony not running or blocked UDP 123; TLS “cert not yet valid” errors often = clock skew.
- **Logs:** `journalctl -u chronyd`, `/var/log/messages`.

## 1.7 SSH Access & Hardening

- **What:** Manage SSH keys/config.
- **Why:** Secure remote access; prefer SSM where possible.

```bash
ssh-keygen -t ed25519 -C "deploy@host"
ssh-copy-id -i ~/.ssh/id_ed25519.pub deploy@host
sshd -t                              # validate sshd_config
systemctl reload sshd
```

- **Troubleshooting:** Locked out → use SSM Session Manager; “Permission denied (publickey)” → check `~/.ssh` perms (700) and `authorized_keys` (600), owner, SELinux context (`restorecon -Rv ~/.ssh`).
- **Logs:** `/var/log/secure`.

-----

# 2. YUM / DNF PACKAGE MANAGEMENT

> AL2 = `yum`; AL2023 = `dnf` (yum symlinks to dnf). RPM packages, repos in `/etc/yum.repos.d/`.

## 2.1 Install / Update / Remove

- **What/Why:** Add or maintain software; keep deps consistent.

```bash
yum install -y nginx git jq
yum update -y                 # all packages
yum upgrade -y                # update + obsoletes
yum remove -y telnet
yum autoremove -y             # orphaned deps
yum reinstall -y openssl
yum downgrade postgresql15-15.4
```

- **Troubleshooting:** Conflict/dep errors → `yum deplist <pkg>`, `--allowerasing`, check enabled repos; “Nothing provides” → missing/disabled repo.
- **Logs:** `/var/log/dnf.log` (AL2023), `/var/log/yum.log` (AL2).

## 2.2 Search & Inspect

```bash
yum search postgres
yum info nginx
yum provides */kafka-topics.sh        # which pkg owns a file
yum list installed | grep python
yum list available --showduplicates postgresql15
yum deplist nginx
rpm -qa | sort
rpm -qi nginx ; rpm -ql nginx ; rpm -qf /usr/sbin/nginx
```

## 2.3 Repository Management

```bash
yum repolist all
yum-config-manager --add-repo https://repo/example.repo   # AL2
dnf config-manager --set-enabled crb                       # AL2023
yum --disablerepo=* --enablerepo=amazonlinux install -y htop
```

- Repo file `/etc/yum.repos.d/myrepo.repo`:

```ini
[myrepo]
name=My Repo
baseurl=https://repo.internal/al2023/$basearch/
enabled=1
gpgcheck=1
gpgkey=https://repo.internal/RPM-GPG-KEY
```

- **Troubleshooting:** “Cannot retrieve metalink/repodata” → DNS/proxy/network egress blocked, or stale cache (`yum clean all && yum makecache`); GPG errors → import key (`rpm --import`).

## 2.4 Amazon Linux Extras (AL2 only)

```bash
amazon-linux-extras list
amazon-linux-extras enable postgresql14
yum clean metadata && yum install -y postgresql
```

## 2.5 History & Rollback

- **Why:** Recover from a bad patch.

```bash
yum history list
yum history info <id>
yum history undo <id>
yum history redo <id>
```

## 2.6 Security Patching

```bash
yum updateinfo list security all
yum update --security -y
yum updateinfo summary
```

## 2.7 Version Locking

- **Why:** Pin Kafka/Postgres deps so a bulk update can’t break them.

```bash
yum install -y yum-plugin-versionlock           # AL2
dnf install -y python3-dnf-plugin-versionlock   # AL2023
yum versionlock add postgresql15
yum versionlock list
yum versionlock delete postgresql15
```

## 2.8 Cache, Groups, GPG, Offline

```bash
yum clean all ; yum makecache
yum grouplist ; yum groupinstall -y "Development Tools"
rpm --import https://repo/RPM-GPG-KEY ; rpm -qa gpg-pubkey*
yum install --downloadonly --downloaddir=/tmp/rpms <pkg>   # air-gapped
yum localinstall /tmp/rpms/*.rpm
```

-----

# 3. PATCHING (OS + FLEET)

## 3.1 Single-Host Patch Cycle

- **What/Why:** Apply updates, reboot if kernel changed, validate.

```bash
yum check-update
yum update --security -y
needs-restarting -r ; needs-restarting -s      # reboot needed?
reboot
uname -r ; rpm -q kernel
```

- **Troubleshooting:** Won’t boot post-kernel update → select prior kernel in GRUB; verify with `uname -r`; roll back via `yum history undo`.
- **Logs:** `/var/log/dnf.log`, `journalctl -b -1` (previous boot).

## 3.2 Fleet Patching via SSM Patch Manager

```bash
aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=tag:Env,Values=prod" \
  --parameters "Operation=Install" \
  --max-concurrency "25%" --max-errors "2"
aws ssm list-command-invocations --command-id <id> --details
aws ssm describe-instance-patch-states --instance-ids i-0abc
aws ssm describe-patch-baselines
```

- **Troubleshooting:** Instance not targeted → SSM Agent down or instance role missing `AmazonSSMManagedInstanceCore`; check `aws ssm describe-instance-information`.
- **Logs:** `/var/log/amazon/ssm/amazon-ssm-agent.log`, CloudWatch (if configured), command output in SSM console.

-----

# 4. DISK, STORAGE & FILESYSTEM

## 4.1 Inspect Usage

```bash
df -hT
du -sh /var/log/* | sort -rh | head
du -xsh /* 2>/dev/null | sort -rh | head     # per top-level dir
lsblk -f ; blkid
ncdu /                                         # interactive (if installed)
```

- **Troubleshooting:** “No space left” but `df` looks ok → inodes exhausted (`df -i`); deleted-but-open files holding space (`lsof | grep deleted`) → restart holder.

## 4.2 Increase EBS Volume (Online, No Downtime)

- **Why:** Kafka/OpenSearch/Postgres data growth; #1 routine task.

```bash
# 1) Expand the EBS volume in AWS
aws ec2 modify-volume --volume-id vol-0abc --size 200
aws ec2 describe-volumes-modifications --volume-id vol-0abc \
  --query "VolumesModifications[].[ModificationState,Progress]"
# 2) Grow the partition (note the space before partition number)
sudo growpart /dev/nvme0n1 1
# 3) Grow the filesystem
sudo xfs_growfs /                  # XFS (AL2023 default)
sudo resize2fs /dev/nvme0n1p1      # ext4
df -h /
```

- **Troubleshooting:** Size unchanged after modify → forgot growpart/resize; `growpart` “NOCHANGE” → already grown or wrong device; verify mapping with `lsblk`. Modification stuck in “optimizing” is normal (volume usable).

## 4.3 Attach & Mount New EBS Volume

```bash
aws ec2 create-volume --size 100 --volume-type gp3 --availability-zone us-east-1a
aws ec2 attach-volume --volume-id vol-0xyz --instance-id i-0abc --device /dev/sdf
lsblk                              # appears as /dev/nvme1n1 on Nitro
sudo mkfs -t xfs /dev/nvme1n1
sudo mkdir -p /data
sudo mount /dev/nvme1n1 /data
echo "UUID=$(sudo blkid -s UUID -o value /dev/nvme1n1) /data xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a                      # validate fstab (catch errors BEFORE reboot)
```

- **Troubleshooting:** Instance won’t boot after fstab edit → bad entry; always use `nofail`, and `mount -a` before rebooting. Device name mismatch → Nitro renames sdX → nvmeXn1.

## 4.4 LVM Management

```bash
pvcreate /dev/nvme1n1 ; vgcreate vg_data /dev/nvme1n1
lvcreate -L 50G -n lv_kafka vg_data
mkfs.xfs /dev/vg_data/lv_kafka
# extend later:
lvextend -L +20G /dev/vg_data/lv_kafka && xfs_growfs /dev/vg_data/lv_kafka
vgs ; lvs ; pvs
```

## 4.5 Swap

```bash
dd if=/dev/zero of=/swapfile bs=1M count=4096
chmod 600 /swapfile ; mkswap /swapfile ; swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
swapon --show ; free -h
```

- Note: disable/limit swap on Kafka/OpenSearch hosts (`vm.swappiness=1`).

## 4.6 Log Cleanup / Rotation

```bash
logrotate -f /etc/logrotate.conf
journalctl --vacuum-time=7d ; journalctl --vacuum-size=500M
find /var/log -name "*.gz" -mtime +30 -delete
```

## 4.7 EFS (Shared NFS)

```bash
dnf install -y amazon-efs-utils
mount -t efs -o tls fs-0abc:/ /mnt/efs
echo "fs-0abc:/ /mnt/efs efs _netdev,tls 0 0" >> /etc/fstab
```

- **Troubleshooting:** Mount hangs → SG must allow NFS (TCP 2049) between instance and EFS mount targets; mount target must exist in the instance’s AZ.

-----

# 5. EC2 ADMINISTRATION

## 5.1 Lifecycle & Inventory

```bash
aws ec2 describe-instances --filters "Name=tag:Env,Values=prod" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress,InstanceType]" --output table
aws ec2 start-instances --instance-ids i-0abc
aws ec2 stop-instances  --instance-ids i-0abc
aws ec2 reboot-instances --instance-ids i-0abc
aws ec2 terminate-instances --instance-ids i-0abc
```

- **Troubleshooting:** Stuck “stopping” → force stop (`--force`); failed status checks → see 5.6.

## 5.2 Resize Instance Type

```bash
aws ec2 stop-instances --instance-ids i-0abc
aws ec2 modify-instance-attribute --instance-id i-0abc \
  --instance-type "{\"Value\":\"m6i.2xlarge\"}"
aws ec2 start-instances --instance-ids i-0abc
```

- **Troubleshooting:** “InsufficientInstanceCapacity” → try another AZ/type; incompatible type (e.g., non-Nitro ↔ Nitro) → driver/ENA differences.

## 5.3 AMI & Snapshots

```bash
aws ec2 create-image --instance-id i-0abc --name "app-baseline-$(date +%F)" --no-reboot
aws ec2 create-snapshot --volume-id vol-0abc --description "pre-patch $(date +%F)"
aws ec2 describe-snapshots --owner-ids self --query "Snapshots[].[SnapshotId,VolumeId,State,Progress]" --output table
```

## 5.4 Tagging

```bash
aws ec2 create-tags --resources i-0abc vol-0abc \
  --tags Key=Owner,Value=cloudteam Key=Env,Value=prod Key=App,Value=kafka
aws ec2 describe-tags --filters "Name=resource-id,Values=i-0abc"
```

## 5.5 SSM Session Manager & Metadata (IMDSv2)

```bash
aws ssm start-session --target i-0abc
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

## 5.6 Status-Check Troubleshooting

- **What:** Diagnose failed system/instance checks.

```bash
aws ec2 describe-instance-status --instance-ids i-0abc
aws ec2 get-console-output --instance-id i-0abc --output text   # boot log
aws ec2 get-console-screenshot --instance-id i-0abc             # frozen screen
```

- **Troubleshooting:** System check fail = AWS host issue → stop/start (moves to new host); Instance check fail = OS issue (bad fstab, full disk, kernel panic) → read console output.
- **Logs:** EC2 console output, `/var/log/messages`, `journalctl -b`.

-----

# 6. EKS ADMINISTRATION

## 6.1 Access / kubeconfig

```bash
aws eks update-kubeconfig --name prod-cluster --region us-east-1
kubectl get nodes -o wide
kubectl cluster-info
kubectl config current-context ; kubectl config get-contexts
```

- **Troubleshooting:** “You must be logged in to the server (Unauthorized)” → identity not in `aws-auth` configmap or access entry; “Unable to connect” → kubeconfig endpoint/VPN/SG.

## 6.2 Workloads, Logs, Exec

```bash
kubectl get pods -A -o wide
kubectl describe pod <pod> -n app
kubectl logs -f <pod> -n app --tail=100
kubectl logs <pod> -n app --previous           # crashed container's prior logs
kubectl rollout restart deploy/fastapi -n app
kubectl rollout status  deploy/fastapi -n app
kubectl rollout undo    deploy/fastapi -n app
kubectl scale deploy/fastapi --replicas=4 -n app
kubectl exec -it <pod> -n app -- /bin/sh
kubectl get events -n app --sort-by='.lastTimestamp'
```

- **Pod state troubleshooting:**
  - `Pending` → unschedulable: `kubectl describe pod` events → insufficient CPU/mem, taints, no PV → check `kubectl top nodes`, node selectors.
  - `CrashLoopBackOff` → app erroring on start: `kubectl logs --previous`, check liveness probe, env/secrets.
  - `ImagePullBackOff` → bad image/tag or ECR auth → verify image, IRSA/node role ECR perms.
  - `OOMKilled` → raise memory limits; check `kubectl describe pod` Last State.
  - `Evicted` → node disk/mem pressure → check node conditions.

## 6.3 Node Group Management

```bash
aws eks describe-nodegroup --cluster-name prod-cluster --nodegroup-name ng-1
aws eks update-nodegroup-config --cluster-name prod-cluster --nodegroup-name ng-1 \
  --scaling-config minSize=3,maxSize=10,desiredSize=5
kubectl get nodes --show-labels
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>
kubectl taint nodes <node> dedicated=kafka:NoSchedule
```

- **Node troubleshooting:** `NotReady` → kubelet/CNI down: `kubectl describe node`, SSM into node, `journalctl -u kubelet -f`; check disk pressure, ENI IP exhaustion.

## 6.4 Cluster / Node Upgrades

```bash
aws eks update-cluster-version --name prod-cluster --kubernetes-version 1.30
aws eks update-nodegroup-version --cluster-name prod-cluster --nodegroup-name ng-1
kubectl version --short
```

- **Why/Order:** Upgrade control plane first, then node groups, then add-ons. Check deprecated APIs before upgrade.
- **Troubleshooting:** PodDisruptionBudget blocks drain during upgrade → adjust PDB; deprecated API removed → update manifests.

## 6.5 Autoscaling (HPA + Cluster Autoscaler/Karpenter)

```bash
kubectl autoscale deploy fastapi --cpu-percent=70 --min=2 --max=10 -n app
kubectl get hpa -n app
kubectl describe hpa fastapi -n app
```

- **Troubleshooting:** HPA shows `<unknown>` targets → metrics-server missing/broken; nodes not scaling → Cluster Autoscaler logs, ASG max reached.

## 6.6 IRSA & Service Accounts

```bash
eksctl create iamserviceaccount --cluster prod-cluster --name s3-reader \
  --namespace app --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess --approve
kubectl describe sa s3-reader -n app      # check eks.amazonaws.com/role-arn annotation
```

- **Troubleshooting:** Pod AccessDenied to AWS → SA annotation missing/wrong role ARN, or OIDC provider not associated.

## 6.7 Add-ons (VPC-CNI, CoreDNS, EBS/EFS CSI)

```bash
aws eks list-addons --cluster-name prod-cluster
aws eks create-addon --cluster-name prod-cluster --addon-name aws-ebs-csi-driver
aws eks update-addon --cluster-name prod-cluster --addon-name vpc-cni \
  --addon-version v1.18.0-eksbuild.1 --resolve-conflicts PRESERVE
kubectl -n kube-system get pods           # aws-node, coredns, kube-proxy
```

- **Troubleshooting:** DNS failures cluster-wide → CoreDNS pods/logs (`kubectl logs -n kube-system -l k8s-app=kube-dns`); pods stuck ContainerCreating → CNI/IP exhaustion (`kubectl logs -n kube-system -l k8s-app=aws-node`).

## 6.8 Storage (PVC / StorageClass)

```bash
kubectl get sc
kubectl get pvc -A ; kubectl get pv
kubectl describe pvc <pvc> -n data
```

- **Troubleshooting:** PVC `Pending` → no default StorageClass or EBS CSI driver missing/IAM; wrong AZ binding (use `WaitForFirstConsumer`).

## 6.9 Ingress / Services (AWS LB Controller)

```bash
kubectl get ingress -A
kubectl get svc -n app -o wide
kubectl describe ingress <ing> -n app
```

- **Troubleshooting:** ALB not created → LB Controller logs, subnet tags missing (`kubernetes.io/role/elb`), IAM perms; 503 → no healthy targets (check pod readiness, target group health).

-----

# 7. ECS ADMINISTRATION

## 7.1 Inspect

```bash
aws ecs list-clusters
aws ecs list-services --cluster prod
aws ecs describe-services --cluster prod --services fastapi-svc \
  --query "services[].[serviceName,runningCount,desiredCount,deployments[0].rolloutState]"
aws ecs list-tasks --cluster prod --service-name fastapi-svc
aws ecs describe-tasks --cluster prod --tasks <taskId>
```

## 7.2 Deploy / Scale

```bash
aws ecs register-task-definition --cli-input-json file://taskdef.json
aws ecs update-service --cluster prod --service fastapi-svc \
  --task-definition fastapi:42 --force-new-deployment
aws ecs update-service --cluster prod --service fastapi-svc --desired-count 4
```

- **Troubleshooting:** Tasks stuck PROVISIONING → no capacity / ENI limit / subnet IPs; tasks cycling → failing health checks or container exit (`describe-tasks` → `stoppedReason`, `exitCode`).

## 7.3 Exec & Logs

```bash
aws ecs execute-command --cluster prod --task <id> --container app \
  --interactive --command "/bin/sh"
aws logs tail /ecs/fastapi --follow
```

- **Troubleshooting:** ECS Exec fails → enableExecuteCommand on service, SSM perms on task role, `amazon-ssm-agent` in image; pull errors → ECR auth/task execution role.
- **Logs:** CloudWatch log group from task def `logConfiguration`; `stoppedReason` field.

-----

# 8. NETWORKING & CONNECTIVITY

## 8.1 Connectivity Diagnostics

```bash
ping -c4 10.0.2.20
nc -zv kafka-broker 9092               # TCP port reachability
ss -tulpn ; netstat -tulpn             # listening sockets
curl -v telnet://opensearch:9200
dig postgres.internal +short ; nslookup host
traceroute target ; mtr target
ip a ; ip r ; ip route get 8.8.8.8
tcpdump -ni any port 9092 -c 20        # packet capture
```

- **Troubleshooting matrix:**
  - DNS fails → `/etc/resolv.conf`, Route 53 resolver, VPC DNS settings.
  - TCP refused → service not listening (`ss -tulpn`) or SG/NACL block.
  - TCP timeout → SG/NACL/route/NAT issue (refused ≠ timeout; timeout usually = firewall/route).
  - Intermittent → MTU, NAT exhaustion, ENI limits.
- **Logs:** VPC Flow Logs (ACCEPT/REJECT), app logs, `/var/log/messages`.

## 8.2 VPC / Route / Endpoint Inspection

```bash
aws ec2 describe-route-tables --query "RouteTables[].Routes"
aws ec2 describe-network-acls
aws ec2 describe-vpc-endpoints
aws ec2 describe-nat-gateways
aws ec2 describe-subnets --filters "Name=vpc-id,Values=vpc-0abc" \
  --query "Subnets[].[SubnetId,CidrBlock,AvailabilityZone,AvailableIpAddressCount]" --output table
```

- **Troubleshooting:** Private subnet can’t reach internet → missing NAT route; can’t reach S3/ECR privately → missing VPC endpoint; low `AvailableIpAddressCount` → subnet exhaustion (affects EKS pods/ENIs).

-----

# 9. SECURITY GROUPS, FIREWALL & TLS

## 9.1 Security Groups

```bash
aws ec2 describe-security-groups --group-ids sg-0abc
aws ec2 authorize-security-group-ingress --group-id sg-0abc \
  --protocol tcp --port 9092 --cidr 10.0.0.0/16
aws ec2 authorize-security-group-ingress --group-id sg-0abc \
  --protocol tcp --port 5432 --source-group sg-app    # SG-to-SG ref
aws ec2 revoke-security-group-ingress --group-id sg-0abc \
  --protocol tcp --port 22 --cidr 0.0.0.0/0
```

- **Troubleshooting:** Connection blocked → confirm both SG (stateful) and NACL (stateless, needs return rule); check you edited the SG actually attached to the ENI.

## 9.2 Host Firewall (firewalld)

```bash
firewall-cmd --state
firewall-cmd --list-all
firewall-cmd --add-port=8000/tcp --permanent ; firewall-cmd --reload
```

## 9.3 TLS / Certificates

```bash
openssl s_client -connect host:9200 -showcerts </dev/null
echo | openssl x509 -in cert.pem -noout -dates -subject -issuer
openssl verify -CAfile ca.pem cert.pem
keytool -list -keystore kafka.keystore.jks                    # Java keystores
keytool -importcert -file ca.crt -keystore truststore.jks
aws acm list-certificates
aws acm describe-certificate --certificate-arn <arn> --query "Certificate.NotAfter"
```

- **Troubleshooting:** “certificate expired/not yet valid” → cert dates or clock skew (check chrony); “unable to find valid certification path” (Java) → CA missing from truststore; hostname mismatch → SAN/CN.
- **Logs:** app-specific (Kafka/NiFi/OpenSearch security logs).

-----

# 10. IAM, STS & SECRETS

## 10.1 Roles & Policies

```bash
aws iam list-roles
aws iam get-role --role-name eks-node-role
aws iam list-attached-role-policies --role-name app-role
aws iam attach-role-policy --role-name app-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
aws iam simulate-principal-policy --policy-source-arn <role-arn> \
  --action-names s3:GetObject --resource-arns arn:aws:s3:::bucket/key
```

- **Troubleshooting:** AccessDenied → use `simulate-principal-policy`; check explicit deny, SCPs, permission boundaries, resource policy, trust policy.

## 10.2 STS / Identity

```bash
aws sts get-caller-identity
aws sts assume-role --role-arn arn:aws:iam::123:role/admin --role-session-name ops
```

- **Troubleshooting:** “not authorized to perform sts:AssumeRole” → trust policy missing principal; expired creds → refresh/rotate.

## 10.3 Secrets & Parameters

```bash
aws secretsmanager get-secret-value --secret-id prod/postgres \
  --query SecretString --output text
aws secretsmanager rotate-secret --secret-id prod/postgres
aws ssm get-parameter --name /app/db/password --with-decryption \
  --query Parameter.Value --output text
aws ssm put-parameter --name /app/feature/flag --value on --type String --overwrite
```

- **Logs:** CloudTrail records every secret access (audit).

-----

# 11. MONITORING, LOGGING & ALERTING

## 11.1 CloudWatch Metrics & Alarms

```bash
aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0abc \
  --start-time 2026-06-17T00:00:00Z --end-time 2026-06-17T12:00:00Z \
  --period 300 --statistics Average
aws cloudwatch put-metric-alarm --alarm-name high-cpu \
  --namespace AWS/EC2 --metric-name CPUUtilization --statistic Average \
  --period 300 --threshold 80 --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 --dimensions Name=InstanceId,Value=i-0abc \
  --alarm-actions arn:aws:sns:us-east-1:123:ops-alerts
aws cloudwatch describe-alarms --state-value ALARM
```

## 11.2 CloudWatch Logs

```bash
aws logs tail /aws/eks/prod-cluster --follow --since 30m
aws logs filter-log-events --log-group-name /app/fastapi \
  --filter-pattern "ERROR" --start-time $(date -d '1 hour ago' +%s000)
aws logs describe-log-groups
```

## 11.3 CloudWatch Agent (OS metrics: mem, disk)

- **Why:** EC2 default metrics lack memory & disk; agent fills the gap.

```bash
dnf install -y amazon-cloudwatch-agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
```

- **Troubleshooting:** No custom metrics → agent not running, bad config JSON, or role missing `CloudWatchAgentServerPolicy`.
- **Logs:** `/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log`.

## 11.4 Local Log Inspection

```bash
tail -f /var/log/messages
grep -i error /var/log/messages | tail -50
journalctl -p err -b ; journalctl --since "1 hour ago"
dmesg -T | grep -i -E "oom|error|fail"
```

-----

# 12. BACKUP & DISASTER RECOVERY

```bash
aws ec2 create-snapshot --volume-id vol-0abc --description "daily"
aws dlm get-lifecycle-policies                       # automated snapshot lifecycle
aws backup start-backup-job --backup-vault-name prod-vault \
  --resource-arn arn:aws:ec2:...:volume/vol-0abc --iam-role-arn <role>
aws backup list-backup-jobs --by-state COMPLETED
aws s3 sync /data/backups s3://my-backups/$(date +%F)/ --storage-class STANDARD_IA
aws s3 cp dump.sql.gz s3://my-backups/postgres/
```

- **Why:** RPO/RTO compliance; pre-change safety net.
- **Troubleshooting:** Backup job fails → role permissions, vault access policy, resource locked; restore test regularly (a backup never restored = no backup).

-----

# 13. KAFKA ADMINISTRATION

## 13.1 Health & Brokers

- **Why:** Confirm cluster availability before/after changes.

```bash
systemctl status kafka
/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092
/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status  # KRaft
```

- **Logs:** `/opt/kafka/logs/server.log`, `controller.log`, `state-change.log`, `kafkaServer-gc.log`.

## 13.2 Topics

```bash
kafka-topics.sh --bootstrap-server localhost:9092 --list
kafka-topics.sh --bootstrap-server localhost:9092 --create --topic orders \
  --partitions 6 --replication-factor 3
kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic orders
kafka-topics.sh --bootstrap-server localhost:9092 --alter --topic orders --partitions 12
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --under-replicated-partitions      # health check
```

- **Troubleshooting:** Under-replicated partitions → broker down/slow disk/network; check `server.log`, ISR shrink/expand messages.

## 13.3 Consumer Groups & Lag (key monitoring)

- **Why:** Lag = consumers falling behind = data delay.

```bash
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group app-cg
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --reset-offsets \
  --group app-cg --topic orders --to-earliest --execute
```

- **Troubleshooting:** Growing LAG → slow/dead consumer, rebalancing loop, or insufficient partitions; CURRENT-OFFSET stuck → consumer not committing.

## 13.4 Produce/Consume Test & Config

```bash
kafka-console-producer.sh --bootstrap-server localhost:9092 --topic orders
kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic orders --from-beginning --max-messages 5
kafka-configs.sh --bootstrap-server localhost:9092 --entity-type topics --entity-name orders \
  --alter --add-config retention.ms=604800000
kafka-configs.sh --bootstrap-server localhost:9092 --entity-type brokers --entity-name 1 --describe --all
```

## 13.5 Partition Reassignment / Rolling Restart

```bash
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file reassign.json --execute
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file reassign.json --verify
# Rolling restart: stop one broker, wait for URP=0, then next.
```

- **Disk pressure:** Kafka’s #1 failure. Monitor `log.dirs`; expand EBS (§4.2); `du -sh /var/lib/kafka`. Broker dies on full disk → free space / expand → restart.
- **JVM:** tune `KAFKA_HEAP_OPTS="-Xms6g -Xmx6g"`; watch GC log for long pauses.

-----

# 14. NIFI ADMINISTRATION

## 14.1 Service Control & Config

```bash
/opt/nifi/bin/nifi.sh status
/opt/nifi/bin/nifi.sh start|stop|restart
systemctl status nifi
```

- **Config files:** `conf/nifi.properties` (ports, repo paths, cluster), `conf/bootstrap.conf` (JVM heap: `java.arg.2=-Xms4g`, `java.arg.3=-Xmx4g`), `authorizers.xml`, `login-identity-providers.xml`.
- **Logs:** `/opt/nifi/logs/nifi-app.log` (main), `nifi-bootstrap.log` (startup/JVM), `nifi-user.log` (auth).

## 14.2 Repository Disk Management (key)

- **Why:** Flowfile/content/provenance repos fill disk fastest → flow stops.

```bash
du -sh /opt/nifi/*_repository
df -h /opt/nifi
```

- **Troubleshooting:** “back pressure” / flow stalls → content repo full or downstream slow; provenance repo huge → reduce retention in `nifi.properties`. Place each repo on dedicated EBS.

## 14.3 Cluster, TLS, Backup

```bash
# Cluster: verify node status in UI; ensure ZooKeeper quorum (if used).
# TLS: use tls-toolkit / nifi-toolkit to generate keystore/truststore; rotate before expiry.
# Backup flow definition + conf:
cp /opt/nifi/conf/flow.json.gz /backup/nifi/flow-$(date +%F).json.gz
tar czf /backup/nifi/conf-$(date +%F).tgz /opt/nifi/conf
```

- **Troubleshooting:** Node won’t join cluster → ZK connectivity, cert mismatch, clock skew; UI 403 → authorizer/policy config.

-----

# 15. OPENSEARCH ADMINISTRATION

## 15.1 Cluster Health (primary task)

```bash
curl -s localhost:9200/_cluster/health?pretty
curl -s localhost:9200/_cat/nodes?v
curl -s localhost:9200/_cat/indices?v&health=red
curl -s "localhost:9200/_cat/shards?v" | grep -E "UNASSIGNED|INITIALIZING"
curl -s localhost:9200/_cat/thread_pool?v
```

- **Status meaning:** Green = all shards assigned; Yellow = replicas unassigned; Red = primary unassigned (data unavailable).
- **Logs:** `/var/log/opensearch/<cluster>.log`, `*_deprecation.log`, GC logs.

## 15.2 Shard / Allocation Troubleshooting

```bash
curl -s localhost:9200/_cluster/allocation/explain?pretty      # why shard unassigned
curl -X PUT localhost:9200/_cluster/settings -H 'Content-Type: application/json' \
  -d '{"transient":{"cluster.routing.allocation.enable":"all"}}'
curl -s localhost:9200/_cat/recovery?v&active_only=true
```

- **Troubleshooting:** Red/unassigned after restart → allocation disabled, disk watermark exceeded, or node left; use allocation/explain to pinpoint.

## 15.3 Disk Watermark (very common)

- **Why:** OpenSearch stops allocating/relocates shards as disks fill.

```bash
curl -X PUT localhost:9200/_cluster/settings -H 'Content-Type: application/json' -d '
{"transient":{
  "cluster.routing.allocation.disk.watermark.low":"85%",
  "cluster.routing.allocation.disk.watermark.high":"90%",
  "cluster.routing.allocation.disk.watermark.flood_stage":"95%"}}'
# Real fix: delete old indices / expand EBS (§4.2). Clear read-only block after:
curl -X PUT "localhost:9200/_all/_settings" -H 'Content-Type: application/json' \
  -d '{"index.blocks.read_only_allow_delete":null}'
```

## 15.4 Index & Snapshot Management

```bash
curl -X PUT localhost:9200/logs-2026.06
curl -X DELETE localhost:9200/logs-2026.05
curl -s localhost:9200/_cat/allocation?v
curl -X PUT "localhost:9200/_snapshot/s3_repo/snap_$(date +%F)?wait_for_completion=false"
curl -s localhost:9200/_snapshot/s3_repo/_all?pretty
```

- **JVM/OS:** heap = 50% RAM, max ~31g (`jvm.options`); requires `vm.max_map_count=262144` and high `nofile` (§1.5).

## 15.5 Managed OpenSearch Service

```bash
aws opensearch describe-domain --domain-name prod-search
aws opensearch update-domain-config --domain-name prod-search \
  --cluster-config InstanceCount=4
```

-----

# 16. POSTGRESQL ADMINISTRATION

## 16.1 Service & Connectivity

```bash
systemctl status postgresql-15
pg_isready -h localhost -p 5432
psql -h localhost -U postgres -d appdb
```

- **Logs:** `/var/lib/pgsql/15/data/log/` (or `log_directory`), check `postgresql.conf` `log_*` settings.

## 16.2 Roles / DB / Permissions

```sql
CREATE ROLE appuser LOGIN PASSWORD 'xxx';
CREATE DATABASE appdb OWNER appuser;
GRANT ALL PRIVILEGES ON DATABASE appdb TO appuser;
\du   \l   \dt+   \conninfo
```

## 16.3 Monitoring (key)

```sql
SELECT pid, usename, state, query FROM pg_stat_activity WHERE state='active';
SELECT pid, now()-query_start AS dur, query FROM pg_stat_activity
  WHERE state!='idle' ORDER BY dur DESC;
SELECT pg_size_pretty(pg_database_size('appdb'));
SELECT relname, n_dead_tup FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;
SELECT * FROM pg_stat_replication;
```

- **Troubleshooting:** “too many connections” → raise `max_connections` or add PgBouncer; bloat/slow → dead tuples high → VACUUM; check `pg_stat_statements` for slow queries.

## 16.4 Locks & Killing Queries

```sql
SELECT * FROM pg_locks WHERE NOT granted;
SELECT pg_cancel_backend(<pid>);      -- gentle
SELECT pg_terminate_backend(<pid>);   -- force
```

- **Troubleshooting:** Query hangs → blocked by lock; find blocker via pg_locks/pg_stat_activity join; long idle-in-transaction → terminate, fix app commit.

## 16.5 Maintenance

```sql
VACUUM (VERBOSE, ANALYZE) orders;
REINDEX TABLE orders;
ANALYZE;
SELECT pg_reload_conf();              -- after pg_hba/postgresql.conf change
```

- **Config:** `shared_buffers` (~25% RAM), `work_mem`, `effective_cache_size`, `max_connections`. Access in `pg_hba.conf` (then reload).

## 16.6 Backup & Restore

```bash
pg_dump -h localhost -U postgres -Fc appdb > appdb.dump
pg_restore -h localhost -U postgres -d appdb appdb.dump
pg_dumpall -U postgres > full.sql
```

## 16.7 Replication / WAL

```sql
SELECT client_addr, state, sync_state,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

- **Troubleshooting:** Replica lag growing → replica IO/CPU, network, long queries holding WAL; check `pg_stat_replication`, replica logs.

## 16.8 RDS / Aurora

```bash
aws rds describe-db-instances --db-instance-identifier prod-pg \
  --query "DBInstances[].[DBInstanceStatus,AllocatedStorage,Endpoint.Address]"
aws rds modify-db-instance --db-instance-identifier prod-pg \
  --allocated-storage 500 --apply-immediately
aws rds create-db-snapshot --db-instance-identifier prod-pg --db-snapshot-identifier pre-deploy
aws rds describe-events --source-identifier prod-pg --source-type db-instance
```

- **Logs:** `aws rds describe-db-log-files` + `download-db-log-file-portion`; CloudWatch + Performance Insights.

-----

# 17. FASTAPI APPLICATION SUPPORT

## 17.1 Service (systemd + gunicorn/uvicorn)

```bash
systemctl status fastapi
systemctl restart fastapi
journalctl -u fastapi -f
# ExecStart example:
# gunicorn -k uvicorn.workers.UvicornWorker app:app -b 0.0.0.0:8000 -w 4 --timeout 60
```

## 17.2 Health & Performance Checks

```bash
curl -s localhost:8000/health
curl -s -o /dev/null -w "HTTP %{http_code} in %{time_total}s\n" localhost:8000/api
ss -tnp | grep :8000          # connection count
```

- **Troubleshooting:** 502/504 behind nginx/ALB → app down, worker timeout, or slow upstream; high latency → too few workers, blocking sync code in async path, DB pool exhaustion; 500 → check app traceback.

## 17.3 Dependencies / venv

```bash
python3 -m venv /opt/app/venv && source /opt/app/venv/bin/activate
pip install -r requirements.txt
pip list --outdated
pip check                      # dependency conflicts
```

## 17.4 Reverse Proxy (nginx)

```bash
nginx -t                       # validate config
systemctl reload nginx
tail -f /var/log/nginx/error.log /var/log/nginx/access.log
```

- **Logs:** app: `/var/log/fastapi/app.log` or `journalctl -u fastapi`; nginx: `/var/log/nginx/{access,error}.log`.

-----

# 18. CONTAINERS & REGISTRY (Docker / ECR)

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <acct>.dkr.ecr.us-east-1.amazonaws.com
docker build -t fastapi:latest .
docker tag fastapi:latest <acct>.dkr.ecr.us-east-1.amazonaws.com/fastapi:latest
docker push <acct>.dkr.ecr.us-east-1.amazonaws.com/fastapi:latest
aws ecr describe-images --repository-name fastapi
aws ecr list-images --repository-name fastapi --filter tagStatus=UNTAGGED
docker ps ; docker logs <id> ; docker exec -it <id> /bin/sh
docker system df ; docker system prune -af      # reclaim disk
```

- **Troubleshooting:** Push denied → ECR perms / not logged in / repo missing; disk full on build host → `docker system prune`; image won’t run → check entrypoint, arch (arm64 vs amd64).

-----

# 19. ANSIBLE (Configuration Management)

- **What/Why:** Agentless, push-based config over SSH — patch/install/tune existing hosts consistently.

```bash
ansible all -i inventory.ini -m ping
ansible webservers -i inventory.ini -m yum -a "name=nginx state=latest" --become
ansible all -i inventory.ini -m shell -a "df -h" --become
ansible-playbook -i inventory.ini patch.yml --limit prod --check --diff
ansible-playbook patch.yml --tags patch
ansible-galaxy init roles/kafka
ansible-galaxy collection install amazon.aws community.postgresql
ansible-vault encrypt group_vars/prod/secrets.yml
ansible-vault edit group_vars/prod/secrets.yml
```

- **Inventory** (`inventory.ini`):

```ini
[webservers]
10.0.1.10
10.0.1.11
[databases]
10.0.2.20 ansible_user=ec2-user
[all:vars]
ansible_ssh_private_key_file=~/.ssh/deploy.pem
```

- **Playbook** (`patch.yml`):

```yaml
---
- name: Baseline patch and configure
  hosts: webservers
  become: true
  tasks:
    - name: Security updates
      ansible.builtin.yum: { name: '*', state: latest, security: true }
    - name: Sysctl for OpenSearch
      ansible.posix.sysctl:
        name: vm.max_map_count
        value: '262144'
        state: present
        reload: true
    - name: Install packages
      ansible.builtin.yum:
        name: [nginx, python3-pip]
        state: present
    - name: Deploy FastAPI unit
      ansible.builtin.template:
        src: fastapi.service.j2
        dest: /etc/systemd/system/fastapi.service
      notify: restart fastapi
  handlers:
    - name: restart fastapi
      ansible.builtin.systemd:
        name: fastapi
        state: restarted
        daemon_reload: true
```

- **Troubleshooting:** “unreachable” → SSH key/SG/host; “permission denied” → need `--become`; module not found → install collection; idempotency surprises → run `--check --diff` first.
- **Role layout:** `roles/<name>/{tasks,handlers,templates,vars,defaults,files}/`.

-----

# 20. TERRAFORM (IaC)

- **What/Why:** Declarative, multi-cloud provisioning with explicit state and `plan` preview.

```bash
terraform init
terraform fmt ; terraform validate
terraform plan -out=tf.plan
terraform apply tf.plan
terraform destroy
terraform state list ; terraform show
terraform output db_endpoint
terraform import aws_instance.web i-0abc123
terraform workspace new staging ; terraform workspace select staging
terraform force-unlock <LOCK_ID>          # if state lock stuck
```

- **Provider + remote state** (`provider.tf`):

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
  backend "s3" {
    bucket         = "my-tf-state"
    key            = "prod/infra.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-locks"
    encrypt        = true
  }
}
provider "aws" { region = var.region }
```

- **Resource** (`main.tf`) — EC2 + sized/encrypted EBS + SG:

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name = "name", values = ["al2023-ami-*-x86_64"] }
}
resource "aws_security_group" "app" {
  name_prefix = "${var.env}-app-"
  vpc_id      = var.vpc_id
  ingress { from_port = 8000, to_port = 8000, protocol = "tcp", cidr_blocks = ["10.0.0.0/16"] }
  egress  { from_port = 0,    to_port = 0,    protocol = "-1",  cidr_blocks = ["0.0.0.0/0"] }
}
resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]
  root_block_device { volume_size = var.ebs_size_gb, volume_type = "gp3", encrypted = true }
  tags = { Name = "${var.env}-fastapi", Env = var.env, Owner = "cloudteam" }
}
output "app_private_ip" { value = aws_instance.app.private_ip }
```

- **Modules:**

```hcl
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.0"
  cluster_name    = "${var.env}-cluster"
  cluster_version = "1.30"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
  eks_managed_node_groups = {
    default = { min_size = 3, max_size = 10, desired_size = 5, instance_types = ["m6i.large"] }
  }
}
```

- **Troubleshooting:** State lock error → another run in progress or stale lock (`force-unlock`); drift → `plan` shows diffs (someone changed it manually); “resource already exists” → `import`; provider auth → `aws sts get-caller-identity`.

-----

# 21. CLOUDFORMATION (IaC)

- **What/Why:** AWS-native templates as stacks; AWS manages state, rollback, drift.

```bash
aws cloudformation validate-template --template-body file://stack.yaml
aws cloudformation create-stack --stack-name prod-app \
  --template-body file://stack.yaml \
  --parameters ParameterKey=Env,ParameterValue=prod \
  --capabilities CAPABILITY_NAMED_IAM
aws cloudformation update-stack --stack-name prod-app --template-body file://stack.yaml
aws cloudformation describe-stacks --stack-name prod-app
aws cloudformation describe-stack-events --stack-name prod-app \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED']"
aws cloudformation detect-stack-drift --stack-name prod-app
aws cloudformation delete-stack --stack-name prod-app
# Change sets (preview before apply):
aws cloudformation create-change-set --stack-name prod-app \
  --change-set-name cs1 --template-body file://stack.yaml
aws cloudformation describe-change-set --change-set-name cs1 --stack-name prod-app
aws cloudformation execute-change-set --change-set-name cs1 --stack-name prod-app
```

- **Template** (`stack.yaml`):

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: FastAPI app server baseline
Parameters:
  Env: { Type: String, Default: prod }
  InstanceType: { Type: String, Default: m6i.large }
  EbsSize: { Type: Number, Default: 100 }
  VpcId: { Type: AWS::EC2::VPC::Id }
  SubnetId: { Type: AWS::EC2::Subnet::Id }
Resources:
  AppSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Allow app port
      VpcId: !Ref VpcId
      SecurityGroupIngress:
        - { IpProtocol: tcp, FromPort: 8000, ToPort: 8000, CidrIp: 10.0.0.0/16 }
  AppInstance:
    Type: AWS::EC2::Instance
    Properties:
      InstanceType: !Ref InstanceType
      SubnetId: !Ref SubnetId
      SecurityGroupIds: [ !Ref AppSecurityGroup ]
      BlockDeviceMappings:
        - DeviceName: /dev/xvda
          Ebs: { VolumeSize: !Ref EbsSize, VolumeType: gp3, Encrypted: true }
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          dnf update -y
          dnf install -y nginx python3-pip
          systemctl enable --now nginx
      Tags: [ { Key: Name, Value: !Sub "${Env}-fastapi" } ]
Outputs:
  PrivateIp:
    Value: !GetAtt AppInstance.PrivateIp
    Export: { Name: !Sub "${Env}-app-ip" }
```

- **Troubleshooting:** Stack `ROLLBACK_COMPLETE` → read `describe-stack-events` for first `CREATE_FAILED` reason; can’t update rolled-back stack → delete and recreate; drift → `detect-stack-drift`; cross-stack delete blocked → exported value still imported elsewhere.
- **Scale-out:** Nested stacks + `Export`/`Fn::ImportValue`; **StackSets** for multi-account/region.

-----

# 22. KEY SYSTEM COMPONENTS REFERENCE

**Storage**

- **EBS** — network block storage = a virtual disk for ONE instance (gp3 default, io2 for high-IOPS DBs). Persists past instance stop. Shows as `/dev/nvme*` on Nitro. Resize online: modify-volume → growpart → xfs_growfs.
- **EFS** — managed elastic **NFS**; mounts to MANY instances/pods at once (ReadWriteMany). For shared config, NiFi staging, content repos. Pay per GB. Needs SG allowing TCP 2049.
- **Instance Store** — ephemeral local NVMe; fast but **wiped on stop/terminate**. Scratch/cache only.
- **S3** — object storage (not a filesystem). Backups, dumps, TF state, artifacts.
- **FSx** — managed Windows/Lustre FS (Lustre for HPC/ML scratch).

**Compute**

- **EC2** — virtual server. Family = purpose: t(burst), m(general), c(compute), r/x(memory — good for Kafka/OpenSearch/Postgres). Nitro hypervisor → NVMe disks, ENA networking.
- **AMI** — boot template (OS+software+config). Golden AMIs standardize fleets.
- **ASG** — keeps desired instance count, replaces unhealthy, scales on metrics. Backs EKS managed node groups.
- **Launch Template** — versioned blueprint (AMI, type, SG, user-data) for ASGs/node groups.

**Networking**

- **VPC** — isolated virtual network (subnets, routes, gateways).
- **Subnet** — IP range in ONE AZ; public (IGW route) vs private (NAT for egress).
- **ENI** — virtual NIC (IP/MAC/SG). EKS VPC-CNI assigns pod IPs from ENIs → instance type caps max pods.
- **Security Group** — stateful instance firewall (return traffic auto-allowed); default-deny inbound.
- **NACL** — stateless subnet firewall (must allow both directions). Secondary control.
- **IGW / NAT GW** — IGW = public bidirectional internet; NAT = private subnets outbound only.
- **Route 53** — managed DNS; private hosted zones resolve internal names.
- **ALB/NLB** — L7 HTTP (FastAPI ingress) / L4 TCP (Kafka). Used by EKS LB Controller.
- **VPC Endpoints** — private access to S3/ECR/SSM without internet.

**Identity**

- **IAM Role** — assumed identity (no static keys) for EC2/Lambda/pods (IRSA). Preferred.
- **Instance Profile** — attaches an IAM role to an EC2 instance.
- **IRSA** — maps K8s ServiceAccount → IAM role via OIDC for per-pod permissions.
- **IMDS** — `169.254.169.254` metadata + temp role creds. Enforce **IMDSv2** (token) to block SSRF.
- **Secrets Manager / SSM Parameter Store** — encrypted secrets/config (KMS-backed); Secrets Manager adds rotation.
- **KMS** — encryption keys behind EBS/EFS/S3/RDS/secrets.

**OS (Amazon Linux)**

- **systemd** — init: units/targets/timers; `systemctl` + `journalctl`.
- **cloud-init / user-data** — first-boot bootstrap scripts.
- **SSM Agent** — Session Manager, Run Command, Patch Manager.
- **chrony** — NTP time sync (critical for TLS/Kafka/logs).
- **firewalld/nftables** — host firewall (secondary to SGs).
- **SELinux** — mandatory access control (`getenforce`).
- **LVM** — flexible disk pooling/resizing.
- **journald/rsyslog/logrotate** — logging + rotation (prevents disk-fill).

**Containers**

- **EKS** — managed K8s control plane; you run nodes (managed/self/Fargate).
- **ECS** — AWS-native orchestrator (simpler than EKS).
- **Fargate** — serverless capacity (no nodes to patch) for EKS/ECS.
- **ECR** — private Docker registry, IAM-integrated.
- **EKS Add-ons** — VPC-CNI (pod net), CoreDNS (DNS), kube-proxy, EBS/EFS CSI (PVCs).

**Observability**

- **CloudWatch** — metrics/logs/alarms/dashboards; agent adds mem/disk metrics.
- **CloudTrail** — API audit log (who did what).
- **AWS Config** — config drift/compliance tracking.
- **AWS Backup / DLM** — scheduled snapshot lifecycle.

-----

# 23. CROSS-CUTTING TROUBLESHOOTING PLAYBOOK

**“Disk full” (any host)**

1. `df -h` and `df -i` (space vs inodes). 2. `du -xsh /* | sort -rh`. 3. Check deleted-open files `lsof | grep deleted`. 4. Rotate/vacuum logs, `docker system prune`. 5. If data volume → expand EBS (§4.2). For Kafka/OpenSearch/NiFi this is the top incident.

**“Can’t connect to service”**

1. Is it listening? `ss -tulpn`. 2. Refused vs timeout (refused=not listening/local; timeout=SG/NACL/route). 3. `nc -zv host port`. 4. SG attached to the right ENI + NACL return rule. 5. DNS (`dig`). 6. VPC Flow Logs for ACCEPT/REJECT.

**“High latency / load”**

1. `top`/`htop`, `vmstat`, `iostat -xz` (CPU vs IO wait). 2. `free -h`, `dmesg | grep -i oom`. 3. App: worker count, DB pool, GC pauses (JVM apps). 4. Network: `mtr`. 5. Downstream dependency health.

**“Service won’t start”**

1. `systemctl status` + `journalctl -u <svc> -n 50`. 2. Config syntax (`nginx -t`, `sshd -t`, `terraform validate`). 3. Port conflict (`ss -tulpn`). 4. Permissions/SELinux (`getenforce`, `restorecon`). 5. Disk/inode full. 6. Dependency (DB/broker) down.

**“AWS API AccessDenied”**

1. `aws sts get-caller-identity`. 2. `aws iam simulate-principal-policy`. 3. Explicit deny / SCP / permission boundary / resource policy. 4. For pods: IRSA SA annotation + OIDC.

**“Post-patch boot failure”**

1. EC2 console output/screenshot. 2. Boot prior kernel via GRUB. 3. `yum history undo`. 4. Bad fstab → recovery (always `mount -a` before reboot).

-----

# 24. KEY LOG LOCATIONS — MASTER TABLE

|Area             |Location / Command                                                        |
|-----------------|--------------------------------------------------------------------------|
|System (general) |`/var/log/messages`, `journalctl -xe`, `dmesg -T`                         |
|Auth / sudo / SSH|`/var/log/secure`, `/var/log/audit/audit.log`                             |
|Boot / kernel    |`journalctl -k`, `journalctl -b`, EC2 console output                      |
|Cron             |`/var/log/cron`                                                           |
|Package (yum/dnf)|`/var/log/dnf.log` (AL2023), `/var/log/yum.log` (AL2)                     |
|Service (any)    |`journalctl -u <service> -f`                                              |
|SSM Agent        |`/var/log/amazon/ssm/amazon-ssm-agent.log`                                |
|CloudWatch Agent |`/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log`       |
|Kafka            |`/opt/kafka/logs/server.log`, `controller.log`, `state-change.log`, GC log|
|NiFi             |`/opt/nifi/logs/nifi-app.log`, `nifi-bootstrap.log`, `nifi-user.log`      |
|OpenSearch       |`/var/log/opensearch/<cluster>.log`, `*_deprecation.log`, GC log          |
|PostgreSQL       |`/var/lib/pgsql/15/data/log/` (per `log_directory`)                       |
|FastAPI          |`journalctl -u fastapi`, `/var/log/fastapi/app.log`                       |
|nginx            |`/var/log/nginx/access.log`, `/var/log/nginx/error.log`                   |
|Docker           |`docker logs <id>`, `journalctl -u docker`                                |
|EKS pods         |`kubectl logs -f <pod> -n <ns>` (+ `--previous`)                          |
|EKS node         |SSM into node → `journalctl -u kubelet -f`                                |
|ECS tasks        |CloudWatch group from task def; `describe-tasks` `stoppedReason`          |
|RDS              |`aws rds describe-db-log-files` + `download-db-log-file-portion`          |
|VPC traffic      |VPC Flow Logs (CloudWatch / S3)                                           |
|AWS API audit    |CloudTrail                                                                |
|AWS metrics      |CloudWatch (EC2/EKS/ECS/RDS namespaces)                                   |

-----

## GOLDEN RULES (apply to every task)

- Snapshot/AMI before patching, resizing, or risky changes.
- `mount -a` after any fstab edit, before rebooting.
- Enforce IMDSv2; prefer SSM Session Manager over SSH.
- Store IaC state + secrets encrypted (S3+KMS, Secrets Manager); never in git.
- Tag everything (Env, Owner, App).
- Watch disk watermarks on Kafka / OpenSearch / NiFi — their #1 failure mode.
- Test restores; an untested backup is not a backup.
- Use `--check`/`plan`/change-sets to preview before applying.
- Keep `vm.max_map_count`, `nofile`, and JVM heap consistent for Kafka/OpenSearch.