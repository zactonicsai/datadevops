Yes—splitting each phase into its own playbook file orchestrated by a thin controller is recommended for an AMI pipeline. Here's the structure, then the honest tradeoff analysis.

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