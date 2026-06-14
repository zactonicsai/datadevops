#!/usr/bin/env bash
set -euo pipefail

# Creates a small Ansible + Docker Compose starter template.
# This does NOT replace the full lab. It gives you a clean practice folder.

PROJECT_NAME="${1:-ansible-kafka-nifi-starter}"

mkdir -p "$PROJECT_NAME"/{controller,servers,ansible/inventory,ansible/group_vars,ansible/playbooks,ansible/templates,scripts,docs}

cat > "$PROJECT_NAME/docker-compose.yml" <<'EOF'
services:
  ansible-controller:
    build: ./controller
    container_name: ansible-controller
    working_dir: /work/ansible
    volumes:
      - ./ansible:/work/ansible
      - ./scripts:/work/scripts
    networks:
      - ansible-lab-net
    depends_on:
      - server1
      - server2
      - server3
    command: ["sh", "-c", "sleep infinity"]

  server1:
    build: ./servers
    container_name: ansible-server1
    hostname: server1
    networks: [ansible-lab-net]

  server2:
    build: ./servers
    container_name: ansible-server2
    hostname: server2
    networks: [ansible-lab-net]

  server3:
    build: ./servers
    container_name: ansible-server3
    hostname: server3
    networks: [ansible-lab-net]

networks:
  ansible-lab-net:
    name: ansible-lab-net
EOF

cat > "$PROJECT_NAME/controller/Dockerfile" <<'EOF'
FROM python:3.12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client sshpass curl ca-certificates \
    && pip install --no-cache-dir ansible \
    && ansible-galaxy collection install community.docker \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work/ansible
EOF

cat > "$PROJECT_NAME/servers/Dockerfile" <<'EOF'
FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server sudo python3 \
    && useradd -m -s /bin/bash ansible \
    && echo 'ansible:ansible' | chpasswd \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
    && chmod 0440 /etc/sudoers.d/ansible \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]
EOF

cat > "$PROJECT_NAME/ansible/ansible.cfg" <<'EOF'
[defaults]
inventory = inventory/hosts.ini
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
interpreter_python = auto_silent

[ssh_connection]
pipelining = True
EOF

cat > "$PROJECT_NAME/ansible/inventory/hosts.ini" <<'EOF'
[app_servers]
server1 ansible_host=server1 kafka_node_id=1 kafka_external_port=19092 nifi_host_port=18443
server2 ansible_host=server2 kafka_node_id=2 kafka_external_port=29092 nifi_host_port=28443
server3 ansible_host=server3 kafka_node_id=3 kafka_external_port=39092 nifi_host_port=38443

[all:vars]
ansible_user=ansible
ansible_password=ansible
ansible_become=true
ansible_become_method=sudo
EOF

cat > "$PROJECT_NAME/ansible/group_vars/all.yml" <<'EOF'
platform_root: /opt/data-platform
kafka_image: apache/kafka:latest
nifi_image: apache/nifi:latest
nifi_username: admin
nifi_password: ChangeMeChangeMe123!
EOF

cat > "$PROJECT_NAME/ansible/playbooks/site.yml" <<'EOF'
---
- import_playbook: ping.yml
- import_playbook: practice.yml
EOF

cat > "$PROJECT_NAME/ansible/playbooks/ping.yml" <<'EOF'
---
- name: Test connection to all servers
  hosts: app_servers
  gather_facts: false

  tasks:
    - name: Ping each server through Ansible
      ansible.builtin.ping:
EOF

cat > "$PROJECT_NAME/ansible/playbooks/practice.yml" <<'EOF'
---
- name: Practice beginner Ansible tasks
  hosts: app_servers
  become: true
  gather_facts: false

  tasks:
    - name: Create platform folder
      ansible.builtin.file:
        path: "{{ platform_root }}"
        state: directory
        mode: "0755"

    - name: Write a hello file
      ansible.builtin.copy:
        dest: "{{ platform_root }}/hello.txt"
        content: "Hello from Ansible on {{ inventory_hostname }}\n"
        mode: "0644"

    - name: Read the hello file
      ansible.builtin.command: "cat {{ platform_root }}/hello.txt"
      register: hello_output
      changed_when: false

    - name: Show the hello text
      ansible.builtin.debug:
        var: hello_output.stdout
EOF

cat > "$PROJECT_NAME/ansible/templates/server-note.txt.j2" <<'EOF'
Server name: {{ inventory_hostname }}
Kafka port: {{ kafka_external_port }}
NiFi port: {{ nifi_host_port }}
EOF

cat > "$PROJECT_NAME/scripts/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker compose up -d --build
docker exec -it ansible-controller ansible-playbook playbooks/site.yml
EOF
chmod +x "$PROJECT_NAME/scripts/run.sh"

cat > "$PROJECT_NAME/README.md" <<'EOF'
# Ansible Kafka/NiFi Starter Template

This is a small practice template.

## Start

```bash
docker compose up -d --build
```

## Enter controller

```bash
docker exec -it ansible-controller bash
```

## Run Ansible

```bash
cd /work/ansible
ansible all -m ping
ansible-playbook playbooks/site.yml
```

## Login used by the lab servers

- User: `ansible`
- Password: `ansible`

This is only for local learning.
EOF

echo "Created $PROJECT_NAME"
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  docker compose up -d --build"
echo "  docker exec -it ansible-controller bash"
echo "  ansible all -m ping"
echo "  ansible-playbook playbooks/site.yml"
