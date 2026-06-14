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



## Kafka CLI send and receive helpers

A separate beginner CLI guide is included here:

```text
docs/kafka-cli-send-receive.md
```

Fast test from Linux/macOS:

```bash
./scripts/kafka-create-topic.sh demo-events
./scripts/kafka-send-message.sh demo-events "Hello Kafka"
./scripts/kafka-receive-messages.sh demo-events
```

Fast test from Windows Command Prompt:

```bat
scripts\kafka-create-topic.bat demo-events
scripts\kafka-send-message.bat demo-events "Hello Kafka"
scripts\kafka-receive-messages.bat demo-events
```

One-command demo:

```bash
./scripts/kafka-cli-demo.sh
```

Windows:

```bat
scripts\kafka-cli-demo.bat
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



## Fix for `port is already allocated` when starting Kafka or NiFi

If a deploy fails with something like:

```text
Bind for 0.0.0.0:19092 failed: port is already allocated
```

it means the host port (19092/29092/39092 for Kafka, 18443/28443/38443 for
NiFi) is already taken. There are two causes, both fixed:

1. **Stale containers from a previous run.** Because Ansible starts the
   `kafka-*` / `nifi-*` containers on the host Docker daemon (via the mounted
   socket), they keep running even after `docker compose down`. Remove them and
   re-deploy:

   ```bash
   # remove just this lab's Kafka/NiFi containers (idempotent)
   docker exec -it ansible-controller /work/scripts/stop-platform.sh
   # or directly on the host:
   docker rm -f $(docker ps -aq --filter label=managed_by=ansible) 2>/dev/null || true
   ```

2. **Double-publishing in `docker-compose.yml` (now fixed).** Earlier versions
   published the Kafka/NiFi host ports on BOTH the `server*` services AND the
   Ansible-created `kafka-*` / `nifi-*` sibling containers, so they fought over
   the same port. The `ports:` blocks have been removed from the `server*`
   services; the sibling containers are now the sole owners of those host ports.
   If you edited compose yourself, make sure `server1/2/3` have no `ports:`.

After clearing stale containers, re-run the deploy:

```bash
docker exec -it ansible-controller /work/scripts/run-playbook.sh
```


## Fix for missing `docker-compose-plugin` package

If you see this error:

```text
[ERROR]: Task failed: Module failed: No package matching 'docker-compose-plugin' is available
```

This happens because this lab does not need the Docker Compose plugin inside the three fake server containers. Docker Compose runs only on your host computer to start the lab. Ansible uses the Docker Python SDK and the mounted Docker socket to start Kafka and NiFi.

The fixed `ansible/playbooks/bootstrap.yml` installs only these target-side packages:

```yaml
- ca-certificates
- curl
- python3-docker
- python3-packaging
- netcat-openbsd
```

The playbook no longer installs these packages on the fake servers:

```yaml
- docker.io
- docker-compose-plugin
```

## Fix for removed `community.general.yaml` callback

If you see this error:

```text
[ERROR]: The 'community.general.yaml' callback plugin has been removed.
```

Use this newer Ansible config in `ansible/ansible.cfg`:

```ini
[defaults]
stdout_callback = ansible.builtin.default
callback_result_format = yaml
```

Do not use the older setting below with recent Ansible/community.general versions:

```ini
stdout_callback = yaml
```

This project ZIP has already been updated with the newer setting.

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


## Beginner Ansible Tutorial Added

This ZIP now includes a beginner tutorial written in simple language:

- `docs/ansible-beginner-tutorial.md`
- `docs/ansible-best-practices-cheatsheet.md`
- `scripts/create_ansible_lab_template.sh`
- `scripts/create_ansible_lab_template.bat`

The two template scripts create a small practice Ansible lab folder with a controller, three servers, inventory, group variables, and beginner playbooks.
