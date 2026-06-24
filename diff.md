Switching to Ansible — this turns the audit into a repeatable playbook you can run across a fleet, with results collected back to your control node. Here's the full setup.

## Inventory

```ini
# inventory.ini
[rhel_app_hosts]
kafka-01 ansible_host=10.0.1.10
nifi-01  ansible_host=10.0.1.20

[rhel_app_hosts:vars]
ansible_user=ec2-user
ansible_ssh_private_key_file=~/.ssh/your-key.pem
ansible_become=true
```

## Playbook

```yaml
# audit-baseline.yml
---
- name: Audit changes since base AMI
  hosts: rhel_app_hosts
  gather_facts: true

  vars:
    baseline_ref: /etc/machine-id        # proxy for image build time
    scan_dirs: "/opt /usr/local /etc /var/lib /var/opt"
    exclude_re: '^/(proc|sys|tmp|run|var/log|var/cache|dev)'
    report_dir: ./audit-reports

  tasks:
    - name: Ensure report dir exists on control node
      delegate_to: localhost
      become: false
      run_once: true
      ansible.builtin.file:
        path: "{{ report_dir }}"
        state: directory
        mode: "0755"

    # 1. Packages added after the AMI build (txn 1 = base)
    - name: Capture dnf transaction history
      ansible.builtin.command: dnf history list
      changed_when: false
      register: dnf_history

    # 2. Files newer than the baseline reference
    - name: Find files newer than baseline
      ansible.builtin.shell: >
        find / -xdev -type f -newer {{ baseline_ref }} 2>/dev/null
        | grep -vE '{{ exclude_re }}' || true
      changed_when: false
      register: newer_files

    # 3. Files owned by NO rpm package (manual / tarball installs)
    - name: Find unowned files in app dirs
      ansible.builtin.shell: |
        for f in $(find {{ scan_dirs }} -type f 2>/dev/null); do
          rpm -qf "$f" &>/dev/null || echo "$f"
        done
      args:
        executable: /bin/bash
      changed_when: false
      register: unowned_files

    # 4. Custom systemd units (not shipped by a package)
    - name: Find custom systemd unit files
      ansible.builtin.shell: |
        for u in /etc/systemd/system/*.service; do
          [ -e "$u" ] || continue
          rpm -qf "$u" &>/dev/null || echo "$u"
        done
      args:
        executable: /bin/bash
      changed_when: false
      register: custom_units

    # 5. Enabled services
    - name: List enabled unit files
      ansible.builtin.command: systemctl list-unit-files --state=enabled --no-legend
      changed_when: false
      register: enabled_units

    # 6. Listening ports → maps services to exposure
    - name: Capture listening sockets
      ansible.builtin.command: ss -tlnp
      changed_when: false
      register: listening_ports

    # 7. Modified packaged files (verify)
    - name: Run rpm verify
      ansible.builtin.shell: rpm -Va 2>/dev/null || true
      changed_when: false
      register: rpm_verify

    # Assemble per-host report on the control node
    - name: Write report
      delegate_to: localhost
      become: false
      ansible.builtin.copy:
        dest: "{{ report_dir }}/{{ inventory_hostname }}-audit.txt"
        mode: "0644"
        content: |
          ================================================================
          BASELINE AUDIT — {{ inventory_hostname }}
          Generated: {{ ansible_date_time.iso8601 }}
          OS: {{ ansible_distribution }} {{ ansible_distribution_version }}
          Baseline ref: {{ baseline_ref }}
          ================================================================

          ---------- [1] DNF TRANSACTION HISTORY -------------------------
          (transaction 1 = base AMI; everything after = additions)
          {{ dnf_history.stdout }}

          ---------- [2] FILES NEWER THAN BASELINE -----------------------
          {{ newer_files.stdout | default('(none)') }}

          ---------- [3] UNOWNED FILES (manual/tarball installs) ---------
          {{ unowned_files.stdout | default('(none)') }}

          ---------- [4] CUSTOM SYSTEMD UNITS ----------------------------
          {{ custom_units.stdout | default('(none)') }}

          ---------- [5] ENABLED SERVICES --------------------------------
          {{ enabled_units.stdout }}

          ---------- [6] LISTENING PORTS ---------------------------------
          {{ listening_ports.stdout }}

          ---------- [7] MODIFIED PACKAGED FILES (rpm -Va) ---------------
          {{ rpm_verify.stdout | default('(none)') }}
```

## Run it

```bash
ansible-playbook -i inventory.ini audit-baseline.yml
```

You get one `<host>-audit.txt` per machine under `./audit-reports/`, each containing the seven sections — added packages, newer files, unowned files, custom services, enabled units, open ports, and modified packaged files.

## Notes worth flagging

The `register` + `delegate_to: localhost` pattern is what pulls everything back to your control node, so the audit scales to a whole fleet without SSHing into each box. All scan tasks use `changed_when: false` because they're read-only — the playbook reports, it doesn't modify.

For a *precise* diff rather than the timestamp heuristic, add a play that runs the same `find / -xdev -type f | sort` manifest against a freshly launched base AMI, fetch both manifests, and `diff` them locally — same approach as before, just orchestrated.

Two practical upgrades if you want them: emit the report as **JSON** (swap the `content` block for a `to_nice_json` of a dict) so it's machine-parseable, or convert the unowned-file and port findings into an **Ansible assertion** that fails the run when unexpected services appear — turning this from an audit into a compliance gate.

Want either of those?