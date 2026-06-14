#!/usr/bin/env bash
set -euo pipefail
cd /work/ansible
ansible all -m ping
ansible-playbook playbooks/site.yml
