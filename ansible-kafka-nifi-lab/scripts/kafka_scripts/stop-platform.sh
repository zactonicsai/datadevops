#!/usr/bin/env bash
set -euo pipefail
cd /work/ansible
ansible-playbook playbooks/stop.yml
