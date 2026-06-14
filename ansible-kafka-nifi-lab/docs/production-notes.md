# Production Notes

This lab is made for learning. It is not a secure production deployment by itself.

## Key changes for real servers

1. Replace `server1`, `server2`, and `server3` containers with real Linux hosts.
2. Update `ansible/inventory/hosts.ini` with real IP addresses or DNS names.
3. Use SSH keys and remove `ansible_password`.
4. Install Docker directly on each server.
5. Remove Docker socket mounts from Docker Compose.
6. Use fixed image versions.
7. Store secrets in Ansible Vault.
8. Configure Kafka TLS/SASL.
9. Configure NiFi secure identity and certificates.
10. Add monitoring, backups, and log retention.

## Example real inventory

```ini
[app_servers]
server1 ansible_host=10.0.1.11 kafka_node_id=1 kafka_external_port=19092 nifi_host_port=8443
server2 ansible_host=10.0.1.12 kafka_node_id=2 kafka_external_port=29092 nifi_host_port=8443
server3 ansible_host=10.0.1.13 kafka_node_id=3 kafka_external_port=39092 nifi_host_port=8443

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/data-platform.pem
ansible_become=true
```
