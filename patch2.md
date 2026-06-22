

Below is a complete, production-grade Ansible solution for patching an AL2023 AMI. The flow is: pre-checks → snapshot → patch → verify → bake new AMI → rollback path.

## Directory Structure

```
ami-patching/
├── ansible.cfg
├── inventory/
│   └── hosts.yml
├── group_vars/
│   └── all.yml
├── playbooks/
│   ├── patch-ami.yml          # main orchestrator
│   └── rollback.yml           # rollback playbook
├── roles/
│   ├── prechecks/
│   │   └── tasks/main.yml
│   ├── snapshot/
│   │   └── tasks/main.yml
│   ├── patch/
│   │   ├── tasks/main.yml
│   │   └── handlers/main.yml
│   ├── verify/
│   │   └── tasks/main.yml
│   └── bake_ami/
│       └── tasks/main.yml
├── logs/                       # patch run logs (gitignored)
└── requirements.yml            # collections
```

**Why this layout:** roles isolate each phase so failures are localized and re-runnable. Separating `snapshot` and `bake_ami` lets you roll back at the EBS-snapshot level (fast, granular) *or* the AMI level (full, immutable). Logs are kept out of the repo.

---

## Core Pattern: Launch → Patch → Bake

The correct AL2023 AMI-patching pattern is **not** patching a static AMI in place. You launch a temporary EC2 instance from the source AMI, patch the running instance, verify, snapshot, then create a new AMI from it and terminate the temp instance. This is the AWS-recommended "golden AMI pipeline."

### `requirements.yml`
```yaml
collections:
  - name: amazon.aws
    version: ">=7.0.0"
  - name: community.general
```
Install: `ansible-galaxy collection install -r requirements.yml`

### `ansible.cfg`
```ini
[defaults]
inventory = inventory/hosts.yml
roles_path = roles
host_key_checking = False
log_path = logs/ansible-run.log
stdout_callback = yaml
retry_files_enabled = False
```
`host_key_checking=False` because the temp instance is ephemeral with an unknown host key. `log_path` captures every run.

### `group_vars/all.yml`
```yaml
# Source AMI — resolved dynamically to "latest AL2023"
source_ami_ssm_param: "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
aws_region: us-east-1
instance_type: t3.medium
subnet_id: subnet-xxxxxxxx
security_group_id: sg-xxxxxxxx
key_name: ami-bakery-key
iam_instance_profile: ssm-managed-instance     # for SSM patching/no-SSH option

# Tagging policy (internal)
ami_name_prefix: "al2023-hardened"
owner_tag: "platform-team"
compliance_tag: "cis-baseline-1.0"

# Patching policy
security_only: true            # internal policy: security patches only by default
reboot_if_required: true
patch_exclusions: []           # e.g. ["kernel*"] if you pin kernels

# Safety
create_snapshot: true
keep_temp_instance_on_failure: true   # leave box up for debugging
```

---

## Main Playbook: `playbooks/patch-ami.yml`

```yaml
---
- name: Resolve source AMI and launch temp instance
  hosts: localhost
  gather_facts: false
  vars_files:
    - ../group_vars/all.yml
  tasks:
    - name: Resolve latest AL2023 AMI from SSM Parameter Store
      amazon.aws.ssm_parameter_info:
        name: "{{ source_ami_ssm_param }}"
        region: "{{ aws_region }}"
      register: ami_param
      # WHY: SSM always points to the newest AL2023 AMI — no hardcoding stale IDs.

    - name: Set source AMI fact
      ansible.builtin.set_fact:
        source_ami_id: "{{ ami_param.parameters[0].value }}"

    - name: Display resolved AMI
      ansible.builtin.debug:
        msg: "Patching from source AMI {{ source_ami_id }}"

    - name: Launch temporary patching instance
      amazon.aws.ec2_instance:
        name: "ami-patch-temp-{{ ansible_date_time.epoch | default(lookup('pipe','date +%s')) }}"
        image_id: "{{ source_ami_id }}"
        instance_type: "{{ instance_type }}"
        subnet_id: "{{ subnet_id }}"
        security_groups: ["{{ security_group_id }}"]
        key_name: "{{ key_name }}"
        iam_instance_profile: "{{ iam_instance_profile }}"
        region: "{{ aws_region }}"
        wait: true
        tags:
          Purpose: ami-patching
          Owner: "{{ owner_tag }}"
          Ephemeral: "true"
      register: temp_instance

    - name: Wait for SSH/boot to be ready
      ansible.builtin.wait_for:
        host: "{{ temp_instance.instances[0].private_ip_address }}"
        port: 22
        delay: 20
        timeout: 300

    - name: Add temp instance to in-memory inventory
      ansible.builtin.add_host:
        name: "{{ temp_instance.instances[0].private_ip_address }}"
        groups: patch_target
        instance_id: "{{ temp_instance.instances[0].instance_id }}"
        ansible_user: ec2-user

- name: Pre-checks, snapshot, patch, verify
  hosts: patch_target
  become: true
  gather_facts: true
  vars_files:
    - ../group_vars/all.yml
  roles:
    - prechecks
    - snapshot
    - patch
    - verify

- name: Bake new AMI from patched instance
  hosts: localhost
  gather_facts: false
  vars_files:
    - ../group_vars/all.yml
  roles:
    - bake_ami
```

---

## Role: `prechecks`

`roles/prechecks/tasks/main.yml`
```yaml
---
- name: Confirm OS is Amazon Linux 2023
  ansible.builtin.assert:
    that:
      - ansible_distribution == "Amazon"
      - ansible_distribution_major_version == "2023"
    fail_msg: "Target is not AL2023 — aborting."
  # WHY: never patch the wrong base OS into a hardened pipeline.

- name: Check available disk space on /
  ansible.builtin.shell: df --output=avail -BG / | tail -1 | tr -dc '0-9'
  register: free_gb
  changed_when: false

- name: Fail if less than 2GB free
  ansible.builtin.assert:
    that: free_gb.stdout | int >= 2
    fail_msg: "Insufficient disk space ({{ free_gb.stdout }}GB) for patching."

- name: Capture pre-patch package state (for diff/audit)
  ansible.builtin.shell: dnf list installed > /tmp/pre-patch-packages.txt
  changed_when: false

- name: Capture pre-patch kernel version
  ansible.builtin.command: uname -r
  register: pre_kernel
  changed_when: false

- name: Record start of patch run to log
  ansible.builtin.lineinfile:
    path: /var/log/ami-patch.log
    line: "PATCH START {{ ansible_date_time.iso8601 }} kernel={{ pre_kernel.stdout }}"
    create: true
```
**What/why:** verifies OS identity, ensures disk headroom (dnf transactions fail on full disks), and snapshots package + kernel state so you can prove exactly what changed and diff post-patch.

---

## Role: `snapshot`

`roles/snapshot/tasks/main.yml`
```yaml
---
- name: Find root EBS volume of temp instance
  amazon.aws.ec2_instance_info:
    instance_ids: ["{{ hostvars[inventory_hostname]['instance_id'] }}"]
    region: "{{ aws_region }}"
  delegate_to: localhost
  become: false
  register: inst_info
  when: create_snapshot | bool

- name: Create EBS snapshot before patching
  amazon.aws.ec2_snapshot:
    region: "{{ aws_region }}"
    volume_id: "{{ inst_info.instances[0].block_device_mappings[0].ebs.volume_id }}"
    description: "Pre-patch snapshot {{ ansible_date_time.iso8601 }}"
    snapshot_tags:
      Purpose: pre-patch-rollback
      SourceAMI: "{{ source_ami_id }}"
      Owner: "{{ owner_tag }}"
    wait: true
  delegate_to: localhost
  become: false
  register: pre_patch_snapshot
  when: create_snapshot | bool

- name: Show snapshot ID (record this for rollback)
  ansible.builtin.debug:
    msg: "ROLLBACK SNAPSHOT: {{ pre_patch_snapshot.snapshot_id }}"
  when: create_snapshot | bool
```
**Why:** the snapshot is your fast rollback point. Even though baking a new AMI keeps the old AMI intact, the snapshot lets you recover the *exact* pre-patch disk state if patching corrupts something mid-transaction. Tasks are `delegate_to: localhost` because AWS API calls run from the controller, not the target.

---

## Role: `patch`

`roles/patch/tasks/main.yml`
```yaml
---
- name: Refresh dnf metadata
  ansible.builtin.dnf:
    update_cache: true

- name: Apply security updates only (internal policy default)
  ansible.builtin.dnf:
    name: "*"
    state: latest
    security: true
    exclude: "{{ patch_exclusions }}"
  register: patch_result
  when: security_only | bool
  notify: check reboot required

- name: Apply ALL updates (when security_only is false)
  ansible.builtin.dnf:
    name: "*"
    state: latest
    exclude: "{{ patch_exclusions }}"
  register: patch_result_full
  when: not (security_only | bool)
  notify: check reboot required

- name: Log patched packages
  ansible.builtin.lineinfile:
    path: /var/log/ami-patch.log
    line: "PATCHED {{ (patch_result.results | default(patch_result_full.results) | default([])) | length }} packages at {{ ansible_date_time.iso8601 }}"
    create: true

- name: Flush handlers to trigger reboot logic now
  ansible.builtin.meta: flush_handlers
```

`roles/patch/handlers/main.yml`
```yaml
---
- name: check reboot required
  ansible.builtin.command: dnf needs-restarting -r
  register: needs_restart
  failed_when: false
  changed_when: false
  notify: reboot instance

- name: reboot instance
  ansible.builtin.reboot:
    reboot_timeout: 300
  when:
    - reboot_if_required | bool
    - needs_restart.rc == 1     # rc=1 means a reboot IS required
```
**What/why:** AL2023 uses `dnf`. `security: true` enforces the internal "security-only" policy. `dnf needs-restarting -r` is the canonical AL2023 way to detect whether a kernel/glibc update mandates reboot — return code 1 means reboot required. We reboot only when truly needed, minimizing AMI bake time.

---

## Role: `verify`

`roles/verify/tasks/main.yml`
```yaml
---
- name: Re-gather facts after reboot
  ansible.builtin.setup:

- name: Confirm no pending security updates remain
  ansible.builtin.command: dnf updateinfo list security
  register: remaining_sec
  changed_when: false
  failed_when: false

- name: Assert zero outstanding security advisories
  ansible.builtin.assert:
    that: "'No security updates' in remaining_sec.stdout or remaining_sec.stdout | trim == ''"
    fail_msg: "Security updates still pending after patch — investigate."
    success_msg: "All security updates applied."

- name: Capture post-patch package state
  ansible.builtin.shell: dnf list installed > /tmp/post-patch-packages.txt
  changed_when: false

- name: Generate package diff
  ansible.builtin.shell: diff /tmp/pre-patch-packages.txt /tmp/post-patch-packages.txt || true
  register: pkg_diff
  changed_when: false

- name: Write diff to patch log
  ansible.builtin.copy:
    content: "{{ pkg_diff.stdout }}"
    dest: /var/log/ami-patch-diff.log

- name: Verify critical services are running
  ansible.builtin.service_facts:

- name: Assert sshd is active
  ansible.builtin.assert:
    that: ansible_facts.services['sshd.service'].state == "running"
    fail_msg: "sshd not running post-patch — AMI would be unbootable/unreachable."

- name: Confirm system booted cleanly (no failed units)
  ansible.builtin.command: systemctl --failed --no-legend
  register: failed_units
  changed_when: false

- name: Assert no failed systemd units
  ansible.builtin.assert:
    that: failed_units.stdout | trim == ""
    fail_msg: "Failed systemd units detected: {{ failed_units.stdout }}"
```
**Why:** this is the gate before baking. It proves the patch took, the box still boots, sshd works (or you'd lock yourself out of the AMI), and no services broke. The package diff is your audit artifact.

---

## Role: `bake_ami`

`roles/bake_ami/tasks/main.yml`
```yaml
---
- name: Create new patched AMI
  amazon.aws.ec2_ami:
    instance_id: "{{ hostvars[groups['patch_target'][0]]['instance_id'] }}"
    region: "{{ aws_region }}"
    name: "{{ ami_name_prefix }}-{{ lookup('pipe','date +%Y%m%d-%H%M%S') }}"
    description: "AL2023 patched from {{ source_ami_id }}"
    wait: true
    wait_timeout: 1200
    tags:
      Owner: "{{ owner_tag }}"
      Compliance: "{{ compliance_tag }}"
      SourceAMI: "{{ source_ami_id }}"
      PatchDate: "{{ lookup('pipe','date +%Y-%m-%d') }}"
    reboot: false   # we already rebooted+verified; avoids double reboot
  register: new_ami

- name: Display new AMI ID
  ansible.builtin.debug:
    msg: "NEW PATCHED AMI: {{ new_ami.image_id }}"

- name: Terminate temporary patching instance
  amazon.aws.ec2_instance:
    instance_ids: ["{{ hostvars[groups['patch_target'][0]]['instance_id'] }}"]
    region: "{{ aws_region }}"
    state: absent
  when: new_ami.image_id is defined
  # WHY: only clean up the temp box once the AMI exists successfully.
```
**Why `reboot: false`:** the AMI create normally reboots the instance for filesystem consistency, but we already did a controlled reboot + verification, so we skip it to save time. (If you skip the verify-reboot, set `reboot: true` here instead.)

---

## Rollback Playbook: `playbooks/rollback.yml`

```yaml
---
- name: Roll back — restore volume from pre-patch snapshot
  hosts: localhost
  gather_facts: false
  vars_files:
    - ../group_vars/all.yml
  vars:
    rollback_snapshot_id: ""    # pass via -e
    target_instance_id: ""      # the instance to restore, pass via -e
  tasks:
    - name: Validate inputs
      ansible.builtin.assert:
        that:
          - rollback_snapshot_id | length > 0
          - target_instance_id | length > 0
        fail_msg: "Provide -e rollback_snapshot_id=snap-xxx -e target_instance_id=i-xxx"

    - name: Get instance + AZ details
      amazon.aws.ec2_instance_info:
        instance_ids: ["{{ target_instance_id }}"]
        region: "{{ aws_region }}"
      register: ri

    - name: Stop instance before volume swap
      amazon.aws.ec2_instance:
        instance_ids: ["{{ target_instance_id }}"]
        region: "{{ aws_region }}"
        state: stopped
        wait: true

    - name: Create new volume from pre-patch snapshot
      amazon.aws.ec2_vol:
        region: "{{ aws_region }}"
        snapshot: "{{ rollback_snapshot_id }}"
        zone: "{{ ri.instances[0].placement.availability_zone }}"
        volume_type: gp3
      register: restored_vol

    - name: Detach current (patched) root volume
      amazon.aws.ec2_vol:
        region: "{{ aws_region }}"
        id: "{{ ri.instances[0].block_device_mappings[0].ebs.volume_id }}"
        instance: None

    - name: Attach restored volume as root
      amazon.aws.ec2_vol:
        region: "{{ aws_region }}"
        id: "{{ restored_vol.volume_id }}"
        instance: "{{ target_instance_id }}"
        device_name: /dev/xvda

    - name: Start instance on pre-patch volume
      amazon.aws.ec2_instance:
        instance_ids: ["{{ target_instance_id }}"]
        region: "{{ aws_region }}"
        state: running
        wait: true

    - name: Rollback complete
      ansible.builtin.debug:
        msg: "Restored {{ target_instance_id }} to snapshot {{ rollback_snapshot_id }}."
```

---

## How to Run

```bash
# 1. Install collections
ansible-galaxy collection install -r requirements.yml

# 2. Dry-run check mode first (validates logic, no changes to packages)
ansible-playbook playbooks/patch-ami.yml --check

# 3. Real run
ansible-playbook playbooks/patch-ami.yml

# 4. Roll back if verification later fails downstream
ansible-playbook playbooks/rollback.yml \
  -e rollback_snapshot_id=snap-0abc123 \
  -e target_instance_id=i-0def456
```

## How to Verify After

1. **AMI exists & tagged:** `aws ec2 describe-images --owners self --filters "Name=tag:PatchDate,Values=$(date +%Y-%m-%d)"`
2. **Launch a smoke-test instance** from the new AMI ID, SSH in, and run `dnf updateinfo list security` — should report none pending.
3. **Check logs** on the temp instance (captured before termination) or pull `/var/log/ami-patch-diff.log` to audit exactly which packages changed.
4. **Kernel check:** `uname -r` on the new instance vs the `pre_kernel` value logged at start — confirms kernel update applied if one was pending.

## Rollback Decision Tree

- **Patch failed mid-run** → temp instance left up (`keep_temp_instance_on_failure: true`); SSH in, inspect `/var/log/ami-patch.log`, fix, re-run. No AMI was created, so nothing downstream is affected.
- **AMI baked but smoke test fails** → just don't promote the new AMI ID; the previous AMI is untouched and still valid. Delete the bad AMI: `aws ec2 deregister-image --image-id ami-xxx`.
- **Need exact disk-level restore** → run `rollback.yml` with the snapshot ID printed during the snapshot phase.

## Key Best Practices Baked In

Immutable golden-AMI pattern (patch a temp instance, never mutate a running fleet); dynamic latest-AMI resolution via SSM so you never hardcode stale IDs; security-only patching by default with an override switch; reboot only when `needs-restarting -r` demands it; mandatory pre-flight assertions and post-patch verification gates so an unbootable or sshd-broken image never gets baked; full package diffing and logging for compliance audit; and three independent rollback layers (re-run, discard AMI, snapshot restore).

One caveat: fill in the real `subnet_id`, `security_group_id`, `key_name`, and `iam_instance_profile` in `group_vars/all.yml` before running, and confirm the SSM parameter path matches your architecture (use the `arm64` variant if you bake Graviton AMIs).

## Restructured Layout

```
ami-patching/
├── ansible.cfg
├── group_vars/all.yml
├── requirements.yml
├── site.yml                        # MAIN CONTROLLER (thin)
└── playbooks/
    ├── 00-launch.yml               # resolve AMI + launch temp instance
    ├── 10-prechecks.yml
    ├── 20-snapshot.yml
    ├── 30-patch.yml
    ├── 40-verify.yml
    ├── 50-bake.yml
    └── 99-rollback.yml             # standalone, not in main flow
```

Each file is a full playbook (has its own `hosts:` and `roles:`/`tasks:`), included by the controller via `import_playbook`.

## Main Controller: `site.yml`

```yaml
---
# Thin orchestrator — sequences phases, owns nothing itself.
# Each phase is a self-contained, independently runnable playbook.

- import_playbook: playbooks/00-launch.yml
- import_playbook: playbooks/10-prechecks.yml
- import_playbook: playbooks/20-snapshot.yml
- import_playbook: playbooks/30-patch.yml
- import_playbook: playbooks/40-verify.yml
- import_playbook: playbooks/50-bake.yml
```

That's the whole controller. Note: rollback is deliberately excluded—it's a break-glass action you invoke manually, never part of the happy path.

## Phase Files

`playbooks/00-launch.yml`
```yaml
---
- name: "Phase 00 — Resolve AMI & launch temp instance"
  hosts: localhost
  gather_facts: false
  vars_files:
    - ../group_vars/all.yml
  tasks:
    - name: Resolve latest AL2023 AMI from SSM
      amazon.aws.ssm_parameter_info:
        name: "{{ source_ami_ssm_param }}"
        region: "{{ aws_region }}"
      register: ami_param

    - name: Set source AMI fact
      ansible.builtin.set_fact:
        source_ami_id: "{{ ami_param.parameters[0].value }}"

    - name: Launch temporary patching instance
      amazon.aws.ec2_instance:
        name: "ami-patch-temp-{{ lookup('pipe','date +%s') }}"
        image_id: "{{ source_ami_id }}"
        instance_type: "{{ instance_type }}"
        subnet_id: "{{ subnet_id }}"
        security_groups: ["{{ security_group_id }}"]
        key_name: "{{ key_name }}"
        iam_instance_profile: "{{ iam_instance_profile }}"
        region: "{{ aws_region }}"
        wait: true
        tags: { Purpose: ami-patching, Ephemeral: "true" }
      register: temp_instance

    - name: Wait for boot
      ansible.builtin.wait_for:
        host: "{{ temp_instance.instances[0].private_ip_address }}"
        port: 22
        delay: 20
        timeout: 300

    - name: Persist state to disk for cross-playbook handoff
      ansible.builtin.copy:
        dest: ./.run-state.json
        content: |
          {
            "source_ami_id": "{{ source_ami_id }}",
            "instance_id": "{{ temp_instance.instances[0].instance_id }}",
            "private_ip": "{{ temp_instance.instances[0].private_ip_address }}"
          }
      # WHY: each imported playbook shares the same run, so add_host also works.
      # But writing state to disk makes phases runnable STANDALONE later too.

    - name: Register temp instance in inventory
      ansible.builtin.add_host:
        name: "{{ temp_instance.instances[0].private_ip_address }}"
        groups: patch_target
        instance_id: "{{ temp_instance.instances[0].instance_id }}"
        ansible_user: ec2-user
```

`playbooks/10-prechecks.yml`
```yaml
---
- name: "Phase 10 — Pre-flight checks"
  hosts: patch_target
  become: true
  gather_facts: true
  vars_files:
    - ../group_vars/all.yml
  roles:
    - prechecks
```

`playbooks/20-snapshot.yml`, `30-patch.yml`, `40-verify.yml` follow the identical pattern—a one-block playbook targeting `patch_target` (or `localhost` for snapshot's AWS calls) that calls the corresponding role. `50-bake.yml` targets `localhost` and calls the `bake_ami` role.

The roles themselves (`prechecks`, `snapshot`, `patch`, `verify`, `bake_ami`) stay exactly as defined earlier—unchanged.

## The Standalone-Reentry Problem

There's a real gotcha. When you run `site.yml`, `add_host` shares the in-memory inventory across all imported playbooks, so `patch_target` is visible everywhere. But the moment you try to run a phase *alone*—

```bash
ansible-playbook playbooks/30-patch.yml   # fails: patch_target is empty
```

—it breaks, because the in-memory host from `00-launch` doesn't exist in a fresh process. That's why `00-launch` writes `.run-state.json`. To make any phase truly standalone, add a tiny bootstrap block at the top of each target-hitting phase:

```yaml
  pre_tasks:
    - name: Load run state if not already in inventory
      when: groups['patch_target'] is not defined
      delegate_to: localhost
      become: false
      block:
        - ansible.builtin.set_fact:
            rs: "{{ lookup('file', '../.run-state.json') | from_json }}"
        - ansible.builtin.add_host:
            name: "{{ rs.private_ip }}"
            groups: patch_target
            instance_id: "{{ rs.instance_id }}"
            ansible_user: ec2-user
```

Now `ansible-playbook playbooks/30-patch.yml` works on its own against the existing temp instance.

---

## Is This Recommended? The Honest Tradeoff

**Yes for this use case**, but it's not free. Here's the real reasoning rather than a blanket "best practice."

### Why it's the right call here

The deciding factor is that AMI patching is a **long, sequential, failure-prone pipeline where you frequently want to resume from a failed step rather than restart from scratch**. Relaunching an instance, re-snapshotting, and re-patching from zero every time the verify step finds a flaky failed-unit is expensive (10–20 min) and wasteful. Phase separation lets you fix the issue and re-run *just* `40-verify.yml` against the still-running temp instance.

Other genuine wins: each phase is independently testable in isolation; failures are easy to localize ("phase 30 failed" is clearer than a line number in a 200-line monolith); phases get a natural numeric run order; and the thin controller reads like documentation of the pipeline.

### Why it can be the *wrong* call

`import_playbook` is **static**—it's resolved at parse time, so you **cannot conditionally skip or loop** imported playbooks based on runtime facts. You can't write `import_playbook: ... when: skip_snapshot` and have it actually evaluate the condition the way you'd expect; the `when` gets pushed onto every task inside, not the import decision itself. If your flow needs real branching (e.g., "snapshot only if the volume is over a certain size, decided at runtime"), playbook-per-phase fights you, and roles-within-one-playbook (your original design) is cleaner.

The other cost is the **state-handoff friction** shown above. A single playbook with sequential roles shares facts and `add_host` for free with zero ceremony. Splitting into separate playbook *files* forces you to either rely on the shared in-memory inventory (which silently couples the files and breaks standalone runs) or serialize state to disk (the `.run-state.json` dance). That's real added complexity you're taking on deliberately.

### The distinction that actually matters

There are two different things people conflate:

- **Separate playbook files + `import_playbook`** — what you asked about. Static, heavier, enables standalone phase runs. Worth it when resumability across process boundaries matters.
- **One playbook, multiple `roles:` or `import_role`/`include_role`** — your original design. Shares state freely, supports runtime conditionals (`include_role` is dynamic), lighter. Better when the flow is conditional or you don't need to re-run phases as separate processes.

### My recommendation

For a CI/CD-driven golden-AMI bakery, go with the separate-files structure—the resumability and independent-testability payoff is large in a pipeline context, and AMI baking rarely needs runtime branching (the flow is almost always the same fixed sequence). But keep each phase file *thin*, push all real logic into the roles (which you've already done), and add the `.run-state.json` bootstrap so phases are genuinely standalone rather than secretly coupled.

If you find yourself wanting conditional phase execution, that's the signal to collapse back toward a single controlling playbook using `include_role` with `when:` conditions instead—don't force static imports to do dynamic work.