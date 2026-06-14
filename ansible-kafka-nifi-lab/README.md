# Ansible + Docker Compose Kafka and NiFi Lab

This project creates one Ansible controller and three Linux server targets. The Ansible inventory has `server1`, `server2`, and `server3`. The playbooks bootstrap each server, then deploy:

- A 3-node Apache Kafka KRaft cluster using `apache/kafka`
- One Apache NiFi standalone container per server using `apache/nifi`
- Docker network, volumes, ports, health checks, and a demo Kafka topic

## Why this design

The three server containers act like small Linux VMs. Ansible connects to them by SSH. For a local lab, each server mounts `/var/run/docker.sock`, so Ansible can use Docker to start Kafka and NiFi containers. This keeps the lab simple and fast.

For production, use real VMs or EC2 instances instead of the three server containers. Install Docker or containerd on each real server. Do not expose the Docker socket unless you fully understand the security risk.

## Current image notes

The default files use:

```text
apache/kafka:latest
apache/nifi:latest
alpine/ansible:2.20.0
ubuntu:24.04
```

For production, pin exact versions in `ansible/group_vars/all.yml` or by setting environment variables. Example:

```bash
export KAFKA_IMAGE=apache/kafka:4.1.2
export NIFI_IMAGE=apache/nifi:2.6.0
```

## Folder structure

```text
ansible-kafka-nifi-lab/
├── docker-compose.yml
├── .env.example
├── controller/
│   └── Dockerfile
├── servers/
│   ├── Dockerfile
│   └── sshd_config
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/hosts.ini
│   ├── group_vars/all.yml
│   ├── playbooks/site.yml
│   ├── playbooks/bootstrap.yml
│   ├── playbooks/deploy-kafka-nifi.yml
│   ├── playbooks/verify.yml
│   └── playbooks/stop.yml
└── scripts/
    ├── run-playbook.sh
    ├── check-platform.sh
    └── stop-platform.sh
```

## Start the lab

From this folder, run:

```bash
docker compose up -d --build
```

Open a shell in the Ansible controller:

```bash
docker exec -it ansible-controller bash
```

Run the playbook:

```bash
/work/scripts/run-playbook.sh
```

## Check the platform

From your host machine:

```bash
./scripts/check-platform.sh
```

Or from the Ansible controller:

```bash
cd /work/ansible
ansible all -m ping
ansible-playbook playbooks/verify.yml
```

## Kafka access

Internal Docker network bootstrap servers:

```text
kafka-server1:9092
kafka-server2:9092
kafka-server3:9092
```

Host machine bootstrap ports:

```text
localhost:19092
localhost:29092
localhost:39092
```

The verify playbook creates this demo topic:

```text
demo-events
```

Create a test message:

```bash
docker exec -it kafka-server1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events
```

Read messages:

```bash
docker exec -it kafka-server1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-server1:9092 \
  --topic demo-events \
  --from-beginning
```

## NiFi access

Open these URLs:

```text
https://localhost:18443/nifi
https://localhost:28443/nifi
https://localhost:38443/nifi
```

Lab login:

```text
Username: admin
Password: ChangeMeChangeMe123!
```

Your browser may warn you about the local HTTPS certificate. That is expected in this local lab.

## Stop the platform

Stop only Kafka and NiFi containers:

```bash
docker exec -it ansible-controller /work/scripts/stop-platform.sh
```

Stop the whole lab:

```bash
docker compose down
```

Remove volumes too:

```bash
docker compose down -v
```

## Best practices included

- Separate controller from managed servers
- Simple inventory groups: `app_servers`, `kafka`, and `nifi`
- Version variables for images
- Idempotent Ansible playbooks where practical
- Kafka KRaft mode, so no ZooKeeper is required
- Three Kafka replicas for internal Kafka topics
- Docker volumes for persistent state
- Clear ports for local testing
- Separate stop playbook

## Production hardening checklist

Before using this pattern outside a lab:

- Pin image versions instead of using `latest`
- Use SSH keys instead of passwords
- Use TLS/SASL for Kafka
- Use a real NiFi identity provider or TLS client certificates
- Store secrets in Ansible Vault, not plain YAML
- Do not mount `/var/run/docker.sock` into general-purpose containers
- Put Kafka and NiFi behind private networks
- Add backup and restore playbooks
- Add monitoring with Prometheus, Grafana, OpenTelemetry, and log shipping
- Add resource limits to containers
- Add CI checks with `ansible-lint` and `yamllint`
