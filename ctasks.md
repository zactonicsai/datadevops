AWS & Linux Infrastructure Admin Tasks — Complete Reference

TASK GROUPS OVERVIEW

	1.	Linux OS Administration (Amazon Linux)
	2.	Patching & Package Management
	3.	Disk, Storage & Filesystem Management
	4.	EC2 Administration
	5.	EKS Administration
	6.	ECS Administration
	7.	Networking & Security
	8.	IAM & Access Management
	9.	Monitoring, Logging & Alerting
	10.	Backup & Disaster Recovery
	11.	Kafka Administration
	12.	NiFi Administration
	13.	OpenSearch Administration
	14.	PostgreSQL Administration
	15.	FastAPI Application Support
	16.	Automation & IaC

1. LINUX OS ADMINISTRATION (Amazon Linux)

	•	User & group management

useradd -m -s /bin/bash deploy
usermod -aG wheel deploy
passwd deploy
groupadd appteam
id deploy


	•	Sudo / privilege config — edit /etc/sudoers.d/deploy

echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
visudo -c


	•	Service management (systemd)

systemctl status sshd
systemctl enable --now nginx
systemctl restart kafka
journalctl -u kafka -f --since "10 min ago"


	•	Process & resource inspection

top -c ; htop
ps aux --sort=-%mem | head
free -h ; vmstat 2 5 ; iostat -xz 2
lsof -i :8080


	•	Cron / scheduled jobs

crontab -e ; crontab -l
systemctl list-timers


	•	SSH key & access

ssh-keygen -t ed25519 -C "deploy@host"
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys


	•	Kernel / sysctl tuning (Kafka/OpenSearch need vm.max_map_count, file limits)

sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.d/99-custom.conf
sysctl -p /etc/sysctl.d/99-custom.conf
ulimit -n 65536
# /etc/security/limits.conf -> "opensearch - nofile 65536"


	•	Time sync (chrony)

systemctl status chronyd
chronyc sources
timedatectl set-timezone UTC


2. PATCHING & PACKAGE MANAGEMENT

	•	DNF/YUM (Amazon Linux 2023 / AL2)

dnf check-update
dnf update -y
dnf install -y htop telnet jq git
dnf list installed | grep kernel
dnf history ; dnf history undo <id>


	•	Security-only patching

dnf update --security -y
dnf updateinfo list security


	•	Reboot management after kernel patch

needs-restarting -r ; reboot
uname -r


	•	Fleet patching via SSM Patch Manager

aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=tag:Env,Values=prod" \
  --parameters "Operation=Install"
aws ssm describe-instance-patch-states --instance-ids i-0abc123


	•	Package locking / version pinning

dnf install -y python3-dnf-plugin-versionlock
dnf versionlock add postgresql15


3. DISK, STORAGE & FILESYSTEM MANAGEMENT

	•	Inspect disk usage

df -hT ; du -sh /var/log/* | sort -rh | head
lsblk ; blkid


	•	Increase EBS volume size (online, no downtime)

# 1. Modify volume in AWS
aws ec2 modify-volume --volume-id vol-0abc --size 200
aws ec2 describe-volumes-modifications --volume-id vol-0abc
# 2. Grow partition
sudo growpart /dev/nvme0n1 1
# 3. Resize filesystem
sudo xfs_growfs /          # XFS
sudo resize2fs /dev/nvme0n1p1   # ext4


	•	Attach & mount new EBS volume

aws ec2 attach-volume --volume-id vol-0xyz --instance-id i-0abc --device /dev/sdf
mkfs -t xfs /dev/nvme1n1
mkdir /data && mount /dev/nvme1n1 /data
echo "UUID=$(blkid -s UUID -o value /dev/nvme1n1) /data xfs defaults,nofail 0 2" >> /etc/fstab
mount -a


	•	LVM management

pvcreate /dev/nvme1n1 ; vgcreate vg_data /dev/nvme1n1
lvcreate -L 50G -n lv_kafka vg_data
lvextend -L +20G /dev/vg_data/lv_kafka && xfs_growfs /dev/vg_data/lv_kafka


	•	Swap configuration

dd if=/dev/zero of=/swapfile bs=1M count=4096
chmod 600 /swapfile ; mkswap /swapfile ; swapon /swapfile


	•	Log rotation / cleanup

logrotate -f /etc/logrotate.conf
journalctl --vacuum-time=7d ; journalctl --vacuum-size=500M


	•	EFS mount (shared storage)

dnf install -y amazon-efs-utils
mount -t efs -o tls fs-0abc:/ /mnt/efs


4. EC2 ADMINISTRATION

	•	Instance lifecycle

aws ec2 describe-instances --filters "Name=tag:Env,Values=prod" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress]" --output table
aws ec2 start-instances --instance-ids i-0abc
aws ec2 stop-instances --instance-ids i-0abc
aws ec2 reboot-instances --instance-ids i-0abc


	•	Resize instance type

aws ec2 stop-instances --instance-ids i-0abc
aws ec2 modify-instance-attribute --instance-id i-0abc --instance-type "{\"Value\":\"m6i.2xlarge\"}"
aws ec2 start-instances --instance-ids i-0abc


	•	AMI / snapshot creation

aws ec2 create-image --instance-id i-0abc --name "app-baseline-$(date +%F)" --no-reboot
aws ec2 create-snapshot --volume-id vol-0abc --description "pre-patch"


	•	Tagging

aws ec2 create-tags --resources i-0abc --tags Key=Owner,Value=cloudteam Key=Env,Value=prod


	•	SSM Session Manager (keyless access)

aws ssm start-session --target i-0abc


	•	User data / metadata (IMDSv2)

TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id


5. EKS ADMINISTRATION

	•	Cluster access / kubeconfig

aws eks update-kubeconfig --name prod-cluster --region us-east-1
kubectl get nodes -o wide
kubectl cluster-info


	•	Node group management

aws eks describe-nodegroup --cluster-name prod-cluster --nodegroup-name ng-1
aws eks update-nodegroup-config --cluster-name prod-cluster --nodegroup-name ng-1 \
  --scaling-config minSize=3,maxSize=10,desiredSize=5


	•	Cluster / node version upgrade

aws eks update-cluster-version --name prod-cluster --kubernetes-version 1.30
aws eks update-nodegroup-version --cluster-name prod-cluster --nodegroup-name ng-1


	•	Workload management

kubectl get pods -A
kubectl describe pod <pod> -n app
kubectl logs -f <pod> -n app --tail=100
kubectl rollout restart deployment/fastapi -n app
kubectl rollout status deployment/fastapi -n app
kubectl scale deployment/fastapi --replicas=4 -n app
kubectl exec -it <pod> -n app -- /bin/sh


	•	Resource & scheduling config

kubectl top nodes ; kubectl top pods -n app
kubectl taint nodes <node> dedicated=kafka:NoSchedule
kubectl label nodes <node> workload=opensearch
kubectl cordon <node> ; kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>


	•	HPA / autoscaling

kubectl autoscale deployment fastapi --cpu-percent=70 --min=2 --max=10 -n app
kubectl get hpa -n app


	•	Cluster Autoscaler / Karpenter — deployed via Helm, scales nodes on pending pods.
	•	IRSA (IAM Roles for Service Accounts)

eksctl create iamserviceaccount --cluster prod-cluster --name s3-reader \
  --namespace app --attach-policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess --approve


	•	Add-ons (CNI, CoreDNS, EBS CSI)

aws eks create-addon --cluster-name prod-cluster --addon-name aws-ebs-csi-driver
aws eks update-addon --cluster-name prod-cluster --addon-name vpc-cni --addon-version v1.18.0-eksbuild.1


	•	PVC / storage classes — EBS gp3 for stateful sets (Kafka, OpenSearch, Postgres).

kubectl get pvc -A ; kubectl get sc


	•	Ingress / LoadBalancer (AWS LB Controller)

kubectl get ingress -A
kubectl get svc -n app


	•	Debugging / events

kubectl get events -n app --sort-by='.lastTimestamp'
kubectl describe node <node>


6. ECS ADMINISTRATION

	•	Cluster & service inspection

aws ecs list-clusters
aws ecs describe-services --cluster prod --services fastapi-svc
aws ecs list-tasks --cluster prod --service-name fastapi-svc


	•	Deploy / update service

aws ecs update-service --cluster prod --service fastapi-svc \
  --task-definition fastapi:42 --force-new-deployment
aws ecs update-service --cluster prod --service fastapi-svc --desired-count 4


	•	Task definitions

aws ecs register-task-definition --cli-input-json file://taskdef.json
aws ecs describe-task-definition --task-definition fastapi:42


	•	ECS Exec (shell into container)

aws ecs execute-command --cluster prod --task <id> --container app --interactive --command "/bin/sh"


	•	Logs (CloudWatch)

aws logs tail /ecs/fastapi --follow


7. NETWORKING & SECURITY

	•	Security groups

aws ec2 authorize-security-group-ingress --group-id sg-0abc \
  --protocol tcp --port 9092 --cidr 10.0.0.0/16
aws ec2 revoke-security-group-ingress --group-id sg-0abc --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 describe-security-groups --group-ids sg-0abc


	•	Connectivity troubleshooting

nc -zv kafka-broker 9092
ss -tulpn ; netstat -tulpn
curl -v telnet://opensearch:9200
dig postgres.internal ; nslookup
traceroute target ; mtr target


	•	TLS / certs

openssl s_client -connect host:9200 -showcerts
openssl x509 -in cert.pem -noout -dates -text
keytool -list -keystore kafka.keystore.jks


	•	VPC / route / NACL inspection

aws ec2 describe-route-tables ; aws ec2 describe-network-acls
aws ec2 describe-vpc-endpoints


8. IAM & ACCESS MANAGEMENT

	•	Roles / policies

aws iam list-roles ; aws iam get-role --role-name eks-node-role
aws iam attach-role-policy --role-name app-role --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam simulate-principal-policy --policy-source-arn <arn> --action-names s3:GetObject


	•	Access keys / rotation

aws iam create-access-key --user-name deploy
aws iam update-access-key --user-name deploy --access-key-id AKIA... --status Inactive


	•	STS / assume role

aws sts get-caller-identity
aws sts assume-role --role-arn arn:aws:iam::123:role/admin --role-session-name ops


	•	Secrets

aws secretsmanager get-secret-value --secret-id prod/postgres --query SecretString --output text
aws ssm get-parameter --name /app/db/password --with-decryption


9. MONITORING, LOGGING & ALERTING

	•	CloudWatch metrics & alarms

aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0abc --start-time 2026-06-17T00:00:00Z \
  --end-time 2026-06-17T12:00:00Z --period 300 --statistics Average
aws cloudwatch put-metric-alarm --alarm-name high-cpu --metric-name CPUUtilization \
  --namespace AWS/EC2 --threshold 80 --comparison-operator GreaterThanThreshold \
  --evaluation-periods 2 --period 300 --statistic Average


	•	CloudWatch Logs

aws logs tail /aws/eks/prod-cluster --follow
aws logs filter-log-events --log-group-name /app/fastapi --filter-pattern "ERROR"


	•	CloudWatch agent install (custom metrics: disk, mem)

dnf install -y amazon-cloudwatch-agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s


	•	Local log inspection

tail -f /var/log/messages
grep -i error /var/log/messages | tail -50
journalctl -p err -b


	•	Prometheus/Grafana (EKS) — service monitors scrape Kafka/JMX, Postgres exporter, node-exporter.

10. BACKUP & DISASTER RECOVERY

	•	EBS snapshots / DLM lifecycle

aws ec2 create-snapshot --volume-id vol-0abc --description "daily"
aws dlm get-lifecycle-policies


	•	AWS Backup

aws backup start-backup-job --backup-vault-name prod-vault \
  --resource-arn arn:aws:ec2:...:volume/vol-0abc --iam-role-arn <role>


	•	S3 sync (config/data offload)

aws s3 sync /data/backups s3://my-backups/$(date +%F)/ --storage-class STANDARD_IA
aws s3 cp dump.sql.gz s3://my-backups/postgres/


11. KAFKA ADMINISTRATION

	•	Service & broker health

systemctl status kafka
/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092


	•	Topic management

kafka-topics.sh --bootstrap-server localhost:9092 --list
kafka-topics.sh --bootstrap-server localhost:9092 --create --topic orders \
  --partitions 6 --replication-factor 3
kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic orders
kafka-topics.sh --bootstrap-server localhost:9092 --alter --topic orders --partitions 12


	•	Consumer groups & lag (key monitoring task)

kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group app-cg
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --reset-offsets \
  --group app-cg --topic orders --to-earliest --execute


	•	Produce / consume test

kafka-console-producer.sh --bootstrap-server localhost:9092 --topic orders
kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic orders --from-beginning


	•	Config & retention

kafka-configs.sh --bootstrap-server localhost:9092 --entity-type topics --entity-name orders \
  --alter --add-config retention.ms=604800000


	•	Partition reassignment / rebalance

kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file reassign.json --execute


	•	Disk pressure — monitor log.dirs; expand EBS (see §3); watch du -sh /var/lib/kafka.
	•	Common ops: rolling restart broker-by-broker, JVM heap tuning (KAFKA_HEAP_OPTS), ZooKeeper/KRaft health.

12. NIFI ADMINISTRATION

	•	Service control

/opt/nifi/bin/nifi.sh status
/opt/nifi/bin/nifi.sh start | stop | restart
systemctl status nifi


	•	Logs

tail -f /opt/nifi/logs/nifi-app.log
tail -f /opt/nifi/logs/nifi-bootstrap.log


	•	Config files — conf/nifi.properties (ports, repos), conf/bootstrap.conf (JVM heap), authorizers.xml, login-identity-providers.xml.
	•	JVM heap tuning (bootstrap.conf): java.arg.2=-Xms4g, java.arg.3=-Xmx4g.
	•	Repository disk management — flowfile/content/provenance repos fill disk fastest; place on dedicated EBS, monitor:

du -sh /opt/nifi/*_repository


	•	Cluster / ZooKeeper — check node status in UI, ensure ZK quorum.
	•	Certs / TLS — tls-toolkit for keystore/truststore; rotate before expiry.
	•	Backup flow — back up flow.json.gz / flow.xml.gz and conf directory.

13. OPENSEARCH ADMINISTRATION

	•	Cluster health (primary task)

curl -s localhost:9200/_cluster/health?pretty
curl -s localhost:9200/_cat/nodes?v
curl -s localhost:9200/_cat/indices?v
curl -s localhost:9200/_cat/shards?v | grep UNASSIGNED


	•	Index management

curl -X PUT localhost:9200/logs-2026.06
curl -X DELETE localhost:9200/logs-2026.05
curl -s localhost:9200/_cat/allocation?v


	•	Shard / allocation troubleshooting

curl -s localhost:9200/_cluster/allocation/explain?pretty
curl -X PUT localhost:9200/_cluster/settings -H 'Content-Type: application/json' \
  -d '{"transient":{"cluster.routing.allocation.enable":"all"}}'


	•	Disk watermark issues (very common) — adjust or expand disk:

curl -X PUT localhost:9200/_cluster/settings -H 'Content-Type: application/json' -d '
{"transient":{"cluster.routing.allocation.disk.watermark.low":"85%",
 "cluster.routing.allocation.disk.watermark.high":"90%"}}'


	•	ISM / lifecycle policies — automate rollover & deletion of old indices.
	•	Snapshots (S3 repo)

curl -X PUT "localhost:9200/_snapshot/s3_repo/snap_$(date +%F)?wait_for_completion=false"


	•	JVM heap — set to 50% of RAM, max ~31g (jvm.options); requires vm.max_map_count=262144 (see §1).
	•	Managed OpenSearch Service

aws opensearch describe-domain --domain-name prod-search
aws opensearch update-domain-config --domain-name prod-search --cluster-config InstanceCount=4


14. POSTGRESQL ADMINISTRATION

	•	Service & connection

systemctl status postgresql-15
psql -h localhost -U postgres -d appdb
pg_isready -h localhost -p 5432


	•	User / role / DB management

CREATE ROLE appuser LOGIN PASSWORD 'xxx';
CREATE DATABASE appdb OWNER appuser;
GRANT ALL PRIVILEGES ON DATABASE appdb TO appuser;
\du   \l   \dt


	•	Monitoring (key tasks)

SELECT * FROM pg_stat_activity WHERE state='active';
SELECT pid, age(clock_timestamp(), query_start), query FROM pg_stat_activity
  WHERE state != 'idle' ORDER BY 2 DESC;
SELECT pg_size_pretty(pg_database_size('appdb'));
SELECT * FROM pg_stat_user_tables ORDER BY n_dead_tup DESC;


	•	Kill long-running / blocking queries

SELECT pg_terminate_backend(<pid>);
SELECT * FROM pg_locks WHERE NOT granted;


	•	Maintenance (vacuum / analyze / reindex)

VACUUM (VERBOSE, ANALYZE) orders;
REINDEX TABLE orders;


	•	Config tuning — postgresql.conf: shared_buffers, work_mem, max_connections, effective_cache_size. Reload:

SELECT pg_reload_conf();


	•	Access control — pg_hba.conf (host rules), then reload.
	•	Backup & restore

pg_dump -h localhost -U postgres -Fc appdb > appdb.dump
pg_restore -h localhost -U postgres -d appdb appdb.dump
pg_dumpall -U postgres > full.sql


	•	Replication / WAL — monitor:

SELECT * FROM pg_stat_replication;
SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;


	•	RDS / Aurora

aws rds describe-db-instances --db-instance-identifier prod-pg
aws rds modify-db-instance --db-instance-identifier prod-pg --allocated-storage 500 --apply-immediately
aws rds create-db-snapshot --db-instance-identifier prod-pg --db-snapshot-identifier pre-deploy


15. FASTAPI APPLICATION SUPPORT

	•	Service management (systemd + uvicorn/gunicorn)

systemctl status fastapi
systemctl restart fastapi
journalctl -u fastapi -f
# ExecStart: gunicorn -k uvicorn.workers.UvicornWorker app:app -b 0.0.0.0:8000 -w 4


	•	Health & endpoint checks

curl -s localhost:8000/health
curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" localhost:8000/api


	•	Dependency / venv management

python3 -m venv /opt/app/venv
source /opt/app/venv/bin/activate
pip install -r requirements.txt
pip list --outdated


	•	Worker / performance tuning — scale gunicorn workers (2*cores+1), tune timeouts, async pool.
	•	Log inspection / errors

tail -f /var/log/fastapi/app.log
grep -i "500\|traceback" /var/log/fastapi/app.log


	•	Reverse proxy (nginx) — config in /etc/nginx/conf.d/, then nginx -t && systemctl reload nginx.
	•	Container deploy — build image, push to ECR, deploy via EKS/ECS (see §5/§6).

aws ecr get-login-password | docker login --username AWS --password-stdin <acct>.dkr.ecr.us-east-1.amazonaws.com
docker build -t fastapi:latest . && docker push <acct>.dkr.ecr.us-east-1.amazonaws.com/fastapi:latest


16. AUTOMATION & IaC

	•	Terraform

terraform init ; terraform plan ; terraform apply
terraform state list ; terraform import aws_instance.web i-0abc


	•	Ansible (fleet config/patching)

ansible all -i inventory -m ping
ansible-playbook -i inventory patch.yml --limit prod


	•	SSM automation / run command (see §2, §4) for agentless fleet ops.
	•	Helm (EKS app deploy)

helm install kafka bitnami/kafka -n data
helm upgrade opensearch opensearch/opensearch -n data -f values.yaml
helm list -A


	•	CI/CD — image build → ECR → kubectl set image / aws ecs update-service --force-new-deployment.

Quick cross-cutting reminders: always snapshot before patching/resizing, use SSM over SSH where possible, tag everything, monitor disk watermarks on Kafka/OpenSearch/NiFi (their #1 failure mode), and keep JVM heap tuning consistent with vm.max_map_count and ulimit settings.