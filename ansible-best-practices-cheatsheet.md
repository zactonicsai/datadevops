# Ansible Best Practices Cheat Sheet for the Kafka/NiFi Lab

## Simple rules

| Rule | Why it matters |
|---|---|
| Keep inventory in `inventory/` | Easy to find server lists |
| Keep shared settings in `group_vars/` | Easy to change settings once |
| Keep steps in `playbooks/` | Easy to run and review automation |
| Use clear task names | Output becomes easier to understand |
| Use variables | Avoid copying the same value everywhere |
| Use exact image versions in production | Avoid surprise changes |
| Do not commit real passwords | Protect your team and systems |
| Make tasks safe to run again | Re-running should not break things |
| Verify after deploy | Starting is not the same as working |
| Use logs when stuck | Logs usually explain the problem |

## Best beginner command list

```bash
# Start lab
docker compose up -d --build

# Enter controller
docker exec -it ansible-controller bash

# Go to Ansible folder
cd /work/ansible

# Test Ansible connection
ansible all -m ping

# Run everything
ansible-playbook playbooks/site.yml

# Verify only
ansible-playbook playbooks/verify.yml

# Stop Kafka and NiFi
ansible-playbook playbooks/stop.yml

# Run only one server
ansible-playbook playbooks/verify.yml --limit server1

# Show more error detail
ansible-playbook playbooks/site.yml -vvv
```

## Common Ansible words

| Word | Simple meaning |
|---|---|
| Controller | Machine where Ansible runs |
| Managed node | Machine Ansible controls |
| Inventory | Server list |
| Playbook | Recipe file |
| Play | A group of tasks for a group of servers |
| Task | One step |
| Module | Tool used by a task |
| Variable | Named value |
| Template | File with fill-in-the-blank values |
| Handler | Special task usually run after a change |
| Role | Organized bundle of tasks, files, vars, and templates |
| Collection | Package of Ansible modules and plugins |

## Good task example

```yaml
- name: Create platform directory
  ansible.builtin.file:
    path: /opt/data-platform
    state: directory
    owner: root
    group: root
    mode: "0755"
```

Why this is good:

- It has a clear name.
- It uses a built-in Ansible module.
- It says the desired final state.
- It sets owner and permissions.

## Good Docker container task example

```yaml
- name: Start NiFi container
  community.docker.docker_container:
    name: "nifi-{{ inventory_hostname }}"
    image: "{{ nifi_image }}"
    state: started
    restart_policy: unless-stopped
    published_ports:
      - "{{ nifi_host_port }}:8443"
```

Why this is good:

- The name includes the server name.
- The image is a variable.
- The container restarts unless stopped.
- Ports are controlled from inventory.

## What not to do

Avoid this:

```yaml
- name: Run big mystery command
  ansible.builtin.shell: curl something | bash
```

Why:

- It is hard to read.
- It may not be safe.
- It may change every time.
- It may hide errors.

Better:

- Use Ansible modules when possible.
- Break big steps into small named tasks.
- Register output and check it.

## Lab versus production

This lab is for learning.

For production:

- Use real servers or cloud instances.
- Use TLS for Kafka and NiFi.
- Use strong passwords or SSO.
- Store secrets outside Git.
- Scan container images.
- Pin image versions.
- Add monitoring and alerts.
- Add backups.
- Do not mount the Docker socket unless you fully understand the risk.
