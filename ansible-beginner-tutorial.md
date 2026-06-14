# Ansible Tutorial for the Kafka and NiFi Docker Lab

## Who this is for

This guide is for a beginner. It explains Ansible like you are learning it for the first time.

You will use the lab in this project:

- One **Ansible controller** container
- Three Linux **server** containers
- An **inventory** file that lists the three servers
- Ansible **playbooks** that install and start Kafka and NiFi with Docker

Think of it like this:

| Lab part | Simple meaning |
|---|---|
| Ansible controller | The teacher giving instructions |
| Servers | The students doing the work |
| Inventory | The class list |
| Playbook | A recipe card |
| Task | One step in the recipe |
| Variable | A sticky note with a value on it |
| Template | A fill-in-the-blank paper |
| Docker container | A small box that runs an app |

---

## 1. What Ansible does

Ansible is a tool that tells computers what to do.

Instead of logging into three servers and typing the same commands three times, you write the steps once. Ansible runs those steps on every server you choose.

In this lab, Ansible tells each server to:

1. Install helper packages.
2. Create folders.
3. Check Docker.
4. Create a Docker network.
5. Pull Kafka and NiFi images.
6. Start Kafka and NiFi containers.
7. Check that everything is running.

Official Ansible describes playbooks and inventory as core parts of how Ansible runs automation. The official sample setup also recommends keeping inventories, group variables, playbooks, and roles organized in a clear directory structure.

---

## 2. What Docker Compose does in this lab

Docker Compose starts the lab computers for you.

In this project, Docker Compose starts:

```text
ansible-controller
ansible-server1
ansible-server2
ansible-server3
```

The controller is where you run Ansible.

The three servers are the machines Ansible controls.

Docker Compose supports service settings like ports, volumes, networks, and health checks. Compose can also start services in dependency order with `depends_on`, which is helpful for labs with several containers.

---

## 3. Folder map

Here is the main folder layout:

```text
ansible-kafka-nifi-lab/
├── docker-compose.yml
├── .env.example
├── README.md
├── controller/
│   └── Dockerfile
├── servers/
│   ├── Dockerfile
│   └── sshd_config
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.ini
│   ├── group_vars/
│   │   └── all.yml
│   ├── playbooks/
│   │   ├── site.yml
│   │   ├── bootstrap.yml
│   │   ├── deploy-kafka-nifi.yml
│   │   ├── verify.yml
│   │   └── stop.yml
│   └── templates/
│       └── README-platform-notes.md.j2
├── scripts/
│   ├── run-playbook.sh
│   ├── check-platform.sh
│   ├── stop-platform.sh
│   ├── create_ansible_lab_template.sh
│   └── create_ansible_lab_template.bat
└── docs/
    ├── production-notes.md
    ├── ansible-beginner-tutorial.md
    └── ansible-best-practices-cheatsheet.md
```

### Why this layout is good

- `docker-compose.yml` starts the lab.
- `controller/` builds the Ansible control machine.
- `servers/` builds the three Linux machines.
- `ansible/inventory/` lists the machines.
- `ansible/group_vars/` stores shared settings.
- `ansible/playbooks/` stores the steps.
- `ansible/templates/` stores fill-in-the-blank files.
- `scripts/` stores helper commands.
- `docs/` stores instructions.

This keeps the project clean. A new person can open the folder and know where to look.

---

## 4. Start the lab

Open a terminal in the project folder.

Run:

```bash
docker compose up -d --build
```

This means:

| Command part | Meaning |
|---|---|
| `docker compose` | Use Docker Compose |
| `up` | Start the lab |
| `-d` | Run in the background |
| `--build` | Build the controller and server images |

Check that the containers are running:

```bash
docker ps
```

You should see:

```text
ansible-controller
ansible-server1
ansible-server2
ansible-server3
```

---

## 5. Go inside the Ansible controller

Run:

```bash
docker exec -it ansible-controller bash
```

This opens a shell inside the controller.

A shell is a place where you type commands.

Now move to the Ansible folder:

```bash
cd /work/ansible
```

---

## 6. The inventory file

The inventory is the server list.

File:

```text
ansible/inventory/hosts.ini
```

Example:

```ini
[app_servers]
server1 ansible_host=server1 kafka_node_id=1 kafka_external_port=19092 nifi_host_port=18443
server2 ansible_host=server2 kafka_node_id=2 kafka_external_port=29092 nifi_host_port=28443
server3 ansible_host=server3 kafka_node_id=3 kafka_external_port=39092 nifi_host_port=38443

[kafka]
server1
server2
server3

[nifi]
server1
server2
server3

[all:vars]
ansible_user=ansible
ansible_password=ansible
ansible_become=true
ansible_become_method=sudo
```

### What this means

`[app_servers]` is a group.

The group has three servers:

```text
server1
server2
server3
```

Each server has small sticky-note values:

```text
kafka_node_id=1
kafka_external_port=19092
nifi_host_port=18443
```

Those values help Ansible give each server its own settings.

### Simple test

Run:

```bash
ansible all -m ping
```

You want to see:

```text
SUCCESS
```

This does not mean internet ping. It means Ansible can talk to the server.

---

## 7. The ansible.cfg file

File:

```text
ansible/ansible.cfg
```

Example:

```ini
[defaults]
inventory = inventory/hosts.ini
host_key_checking = False
retry_files_enabled = False
stdout_callback = yaml
interpreter_python = auto_silent
roles_path = roles
collections_path = ~/.ansible/collections:/usr/share/ansible/collections

[ssh_connection]
pipelining = True
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
```

### Simple meaning

This file tells Ansible how to behave.

| Setting | Simple meaning |
|---|---|
| `inventory` | Where the server list is |
| `host_key_checking = False` | Do not stop the lab for SSH questions |
| `stdout_callback = yaml` | Make output easier to read |
| `pipelining = True` | Make SSH work faster |

For real company servers, be more careful with SSH checks. For this local lab, turning it off keeps the tutorial simple.

---

## 8. The group_vars file

File:

```text
ansible/group_vars/all.yml
```

This file stores shared settings.

Example:

```yaml
kafka_image: "{{ lookup('env', 'KAFKA_IMAGE') | default('apache/kafka:latest', true) }}"
nifi_image: "{{ lookup('env', 'NIFI_IMAGE') | default('apache/nifi:latest', true) }}"

platform_network: data-platform-net
platform_root: /opt/data-platform

kafka_cluster_id: "MkU3OEVBNTcwNTJENDM2Qk"
kafka_internal_port: 9092
kafka_controller_port: 9093

nifi_username: admin
nifi_password: ChangeMeChangeMe123!
nifi_https_port: 8443
```

### Simple meaning

A variable is a name that holds a value.

Example:

```yaml
nifi_username: admin
```

That means Ansible can use `{{ nifi_username }}` later, and it will become `admin`.

### Best practice

For learning, this file is okay.

For real work:

- Do not store real passwords in plain text.
- Use Ansible Vault or a secret manager.
- Pin image versions instead of using `latest`.

Example:

```yaml
kafka_image: apache/kafka:4.1.2
nifi_image: apache/nifi:2.6.0
```

Pinning means you choose an exact version. This helps stop surprise changes.

---

## 9. First playbook: site.yml

File:

```text
ansible/playbooks/site.yml
```

This is the main playbook.

```yaml
---
- import_playbook: bootstrap.yml
- import_playbook: deploy-kafka-nifi.yml
- import_playbook: verify.yml
```

### Simple meaning

This playbook is like a table of contents.

It runs three playbooks in order:

1. `bootstrap.yml`
2. `deploy-kafka-nifi.yml`
3. `verify.yml`

Run it:

```bash
ansible-playbook playbooks/site.yml
```

Or use the helper script from outside the controller:

```bash
./scripts/run-playbook.sh
```

---

## 10. Bootstrap playbook

File:

```text
ansible/playbooks/bootstrap.yml
```

This playbook gets the servers ready.

Important parts:

```yaml
---
- name: Prepare all server nodes
  hosts: app_servers
  become: true
  gather_facts: true

  tasks:
    - name: Install base packages needed by Ansible Docker modules
      ansible.builtin.apt:
        name:
          - ca-certificates
          - curl
          - docker.io
          - docker-compose-plugin
          - python3-docker
          - python3-packaging
          - netcat-openbsd
        state: present
        update_cache: true
```

### Line-by-line meaning

| Line | Simple meaning |
|---|---|
| `hosts: app_servers` | Run on server1, server2, and server3 |
| `become: true` | Use admin power |
| `gather_facts: true` | Learn facts about the server |
| `ansible.builtin.apt` | Use the Ubuntu/Debian package tool |
| `state: present` | Make sure the packages are installed |
| `update_cache: true` | Refresh the package list first |

Next, it creates folders:

```yaml
    - name: Create platform directories
      ansible.builtin.file:
        path: "{{ item }}"
        state: directory
        owner: root
        group: root
        mode: "0755"
      loop:
        - "{{ platform_root }}"
        - "{{ platform_root }}/kafka"
        - "{{ platform_root }}/nifi"
        - "{{ platform_root }}/logs"
```

### What loop means

A loop is like saying:

> Do this same step for every item in this list.

So Ansible creates each folder.

Then it checks the Docker socket:

```yaml
    - name: Confirm Docker socket is available
      ansible.builtin.stat:
        path: /var/run/docker.sock
      register: docker_socket
```

`register` saves the answer in a variable named `docker_socket`.

Then it fails if Docker is missing:

```yaml
    - name: Fail if Docker socket is missing
      ansible.builtin.fail:
        msg: "Docker socket not found."
      when: not docker_socket.stat.exists
```

`when` means only run this task if the condition is true.

---

## 11. Deploy playbook

File:

```text
ansible/playbooks/deploy-kafka-nifi.yml
```

This playbook starts Kafka and NiFi.

The playbook uses Docker modules from the `community.docker` collection.

### Pull images

```yaml
    - name: Pull Kafka image
      community.docker.docker_image:
        name: "{{ kafka_image }}"
        source: pull
        force_source: false

    - name: Pull NiFi image
      community.docker.docker_image:
        name: "{{ nifi_image }}"
        source: pull
        force_source: false
```

Simple meaning:

> Download the Kafka and NiFi container images if needed.

Apache Kafka publishes Docker images such as `apache/kafka`. Apache NiFi also provides a Docker image named `apache/nifi`.

### Create volumes

```yaml
    - name: Create Kafka data volume
      community.docker.docker_volume:
        name: "kafka-data-{{ inventory_hostname }}"
        state: present
```

A volume is storage for a container.

If a container is removed, the volume can keep the data.

### Start Kafka

```yaml
    - name: Start Kafka broker/controller in KRaft mode
      community.docker.docker_container:
        name: "kafka-{{ inventory_hostname }}"
        image: "{{ kafka_image }}"
        state: started
        restart_policy: unless-stopped
```

Simple meaning:

> Start one Kafka container on this server.

`{{ inventory_hostname }}` becomes the server name.

So on server1, the container is named:

```text
kafka-server1
```

### Kafka KRaft note

KRaft is Kafka's built-in way to manage cluster metadata without ZooKeeper.

This lab uses three Kafka nodes. Each node is both a broker and controller.

That is useful for learning because you do not need a separate ZooKeeper service.

### Start NiFi

```yaml
    - name: Start NiFi standalone node
      community.docker.docker_container:
        name: "nifi-{{ inventory_hostname }}"
        image: "{{ nifi_image }}"
        state: started
        restart_policy: unless-stopped
```

Simple meaning:

> Start one NiFi container on this server.

This lab starts three standalone NiFi nodes. They are not a NiFi cluster yet.

That is easier for a beginner.

---

## 12. Verify playbook

File:

```text
ansible/playbooks/verify.yml
```

This playbook checks that the work happened.

Example task:

```yaml
- name: Check running platform containers
  community.docker.docker_container_info:
    name: "kafka-{{ inventory_hostname }}"
  register: kafka_info
```

Simple meaning:

> Ask Docker if the Kafka container is running.

Another example:

```yaml
- name: Show Kafka status
  ansible.builtin.debug:
    msg: "Kafka on {{ inventory_hostname }} is running: {{ kafka_info.exists }}"
```

`debug` prints a message.

That helps you learn what Ansible sees.

---

## 13. Stop playbook

File:

```text
ansible/playbooks/stop.yml
```

This playbook stops the containers.

Run:

```bash
ansible-playbook playbooks/stop.yml
```

Or from the project folder:

```bash
./scripts/stop-platform.sh
```

---

## 14. Basic Ansible commands

Run these from inside the controller in `/work/ansible`.

### Check all servers

```bash
ansible all -m ping
```

### Run one command on all servers

```bash
ansible all -m command -a "hostname"
```

### Run a playbook

```bash
ansible-playbook playbooks/site.yml
```

### Run only one playbook

```bash
ansible-playbook playbooks/bootstrap.yml
```

### Check what would happen without changing things

```bash
ansible-playbook playbooks/site.yml --check
```

Note: not every Docker task can fully support check mode.

### Run only on server1

```bash
ansible-playbook playbooks/verify.yml --limit server1
```

---

## 15. Create a simple practice playbook

Create this file:

```text
ansible/playbooks/practice.yml
```

Add:

```yaml
---
- name: Practice simple Ansible tasks
  hosts: app_servers
  become: true
  gather_facts: false

  tasks:
    - name: Create a practice folder
      ansible.builtin.file:
        path: /tmp/ansible-practice
        state: directory
        mode: "0755"

    - name: Add a note file
      ansible.builtin.copy:
        dest: /tmp/ansible-practice/hello.txt
        content: "Hello from Ansible on {{ inventory_hostname }}\n"
        mode: "0644"

    - name: Read the note file
      ansible.builtin.command: cat /tmp/ansible-practice/hello.txt
      register: note_output
      changed_when: false

    - name: Show the note
      ansible.builtin.debug:
        var: note_output.stdout
```

Run it:

```bash
ansible-playbook playbooks/practice.yml
```

This is a good first playbook because it shows four common things:

1. Make a folder.
2. Copy text into a file.
3. Run a command.
4. Print the answer.

---

## 16. Create a template example

A template is a file with blanks Ansible can fill in.

Create:

```text
ansible/templates/server-note.txt.j2
```

Add:

```jinja2
This server is {{ inventory_hostname }}.
Kafka port is {{ kafka_external_port }}.
NiFi port is {{ nifi_host_port }}.
```

Create:

```text
ansible/playbooks/template-practice.yml
```

Add:

```yaml
---
- name: Practice using a template
  hosts: app_servers
  become: true
  gather_facts: false

  tasks:
    - name: Write server note from template
      ansible.builtin.template:
        src: server-note.txt.j2
        dest: /tmp/server-note.txt
        mode: "0644"
```

Run:

```bash
ansible-playbook playbooks/template-practice.yml
```

Then check:

```bash
ansible all -m command -a "cat /tmp/server-note.txt"
```

Each server will have its own values.

---

## 17. Best practices for this lab

### Keep files organized

Use folders like this:

```text
inventory/
group_vars/
playbooks/
templates/
roles/
scripts/
docs/
```

### Use clear names

Good:

```text
deploy-kafka-nifi.yml
verify.yml
stop.yml
```

Not as good:

```text
stuff.yml
do-things.yml
new-file-final2.yml
```

### Make playbooks safe to run again

A good playbook should be safe to run more than once.

This is called **idempotent**.

Simple meaning:

> If the thing is already correct, do not change it again.

Example:

```yaml
state: present
```

That means:

> Make sure it exists.

It does not mean:

> Install it again every time.

### Use variables

Do this:

```yaml
nifi_https_port: 8443
```

Then use:

```yaml
"{{ nifi_https_port }}"
```

This is better than typing `8443` in many places.

### Keep secrets out of normal files

For real systems, do not store passwords in plain text.

Use one of these:

- Ansible Vault
- AWS Secrets Manager
- Azure Key Vault
- HashiCorp Vault
- GitLab CI/CD protected variables

### Pin versions for production

For learning, `latest` is easy.

For production, use exact versions:

```yaml
kafka_image: apache/kafka:4.1.2
nifi_image: apache/nifi:2.6.0
```

This helps your team avoid surprise upgrades.

### Add health checks

Docker Compose and Docker containers can use health checks.

A health check is like asking:

> Are you really working, not just started?

This is better than only checking that a container exists.

### Separate lab from production

This lab uses Docker socket mounts so containers can start other containers.

That is okay for learning.

For production, use real servers, locked-down Docker access, limited users, TLS, monitoring, backups, and secrets management.

---

## 18. Troubleshooting

### Problem: Ansible cannot connect

Try:

```bash
ansible all -m ping -vvv
```

`-vvv` means show more details.

Check:

```bash
docker ps
```

Make sure the server containers are running.

### Problem: Kafka or NiFi did not start

Check containers:

```bash
docker ps -a
```

Check logs:

```bash
docker logs kafka-server1
```

```bash
docker logs nifi-server1
```

### Problem: NiFi login does not work

Check the username and password in:

```text
ansible/group_vars/all.yml
```

Default lab values:

```text
username: admin
password: ChangeMeChangeMe123!
```

### Problem: Port already in use

Another app may already be using a port.

Check ports:

```bash
docker ps
```

You can change ports in:

```text
ansible/inventory/hosts.ini
```

---

## 19. What to learn next

After this lab, learn these topics:

1. Ansible roles
2. Ansible Vault
3. Docker health checks
4. Kafka topics and producers
5. NiFi processors and flow files
6. Monitoring with Prometheus and Grafana
7. CI/CD with GitLab pipelines
8. Running the same idea on AWS EC2

---

## 20. Official references

- Ansible documentation: https://docs.ansible.com/
- Ansible sample setup: https://docs.ansible.com/projects/ansible/latest/tips_tricks/sample_setup.html
- Ansible inventory guide: https://docs.ansible.com/projects/ansible/latest/inventory_guide/intro_inventory.html
- Docker Compose services reference: https://docs.docker.com/reference/compose-file/services/
- Docker Compose startup order: https://docs.docker.com/compose/how-tos/startup-order/
- Apache Kafka Docker guide: https://kafka.apache.org/41/getting-started/docker/
- Apache NiFi Docker image: https://hub.docker.com/r/apache/nifi
