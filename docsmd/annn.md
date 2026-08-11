# Ansible for Linux Admins — The Complete Cheat Sheet & Tutorial

*Current as of July 2026 — written for **ansible-core 2.21** (shipped inside the **Ansible 14** community package). Everything here also works on ansible-core 2.19/2.20.*

---

## Table of Contents

1. [Background: What Ansible Is, in Plain Words](#1-background)
2. [Step-by-Step: Your Very First Ansible Setup (do this first)](#2-step-by-step-first-setup)
3. [Cheat Sheet: Every Keyword, Flag, and Module You Need](#3-cheat-sheet-keywords)
4. [Detailed Examples: Package & Service Management](#4-packages-and-services)
5. [Detailed Examples: File Management](#5-file-management)
6. [Detailed Examples: Configuration Management](#6-configuration-management)
7. [Detailed Examples: Users, Groups, SSH, and Sudo](#7-users-and-access)
8. [Detailed Examples: Logs and Log Management](#8-logs)
9. [Detailed Examples: Scheduled Jobs (cron & systemd timers)](#9-scheduled-jobs)
10. [Detailed Examples: Disks, Filesystems, and Mounts](#10-disks)
11. [Detailed Examples: Networking, Firewall, and SELinux](#11-network-firewall-selinux)
12. [Detailed Examples: Patching, Reboots, and Rolling Updates](#12-patching-and-reboots)
13. [Detailed Examples: Health Checks and Reporting](#13-health-checks)
14. [The Language: Variables, Facts, Loops, Handlers, Blocks, Tags](#14-the-language)
15. [Roles, Collections, and Project Layout](#15-roles-and-layout)
16. [Ansible Vault (secrets)](#16-vault)
17. [Best Practices](#17-best-practices)
18. [Pros and Cons (every big choice you have to make)](#18-pros-and-cons)
19. [Troubleshooting](#19-troubleshooting)
20. [One-Page Quick Reference](#20-quick-reference)

---

<a name="1-background"></a>
## 1. Background: What Ansible Is, in Plain Words

### The problem it solves

Imagine you are in charge of 300 Linux servers. You need to install a security patch on all of them, change one line in a config file, restart a service, and then prove to your boss that it actually happened everywhere.

Doing that by hand means logging into 300 machines and typing the same thing 300 times. You will get bored, you will make a typo on server #147, and six months later nobody will remember what you changed or why.

**Ansible is a program that types for you.** You write down what the servers *should look like* in a text file, and Ansible logs into all of them at once and makes it true.

### The four ideas that make Ansible different

**1. It is "agentless."**
Most tools of this type need you to install a little helper program (an "agent") on every server you manage. Ansible does not. It just uses **SSH** — the same remote-login tool you already use — plus **Python**, which is already on basically every Linux box. So there is nothing extra to install, patch, or troubleshoot on the servers themselves.

**2. It is "push" based.**
You sit at one machine (the **control node**, usually your laptop or a small admin server). You run a command. Ansible pushes the changes *out* to the servers (the **managed nodes**). Compare that to "pull" tools where every server wakes up every 30 minutes and asks a central server "anything new for me?"

**3. It is "declarative" and "idempotent."**
This is the most important idea in the whole document, so here it is slowly:

- **Declarative** means you describe the *destination*, not the *directions*. You don't say "run `apt install nginx`." You say "**nginx should be installed**." Ansible figures out whether that means apt, dnf, zypper, or nothing at all because it's already there.
- **Idempotent** is a fancy math word that means **"running it twice does the same thing as running it once."** If nginx is already installed, Ansible does nothing and reports `ok`. If it's missing, Ansible installs it and reports `changed`. This is why you can safely run the same playbook every single day. It's a thermostat, not a light switch: you set the temperature you want and it only turns on the heat when the room is actually cold.

**4. Everything is a plain text file (YAML).**
Your entire server configuration is text. Text goes in **Git**. Git gives you history, code review, blame, rollback, and the ability to say "on March 3rd, Priya changed the SSH timeout, here is the exact line." This whole approach has a name: **Infrastructure as Code (IaC)**.

### The vocabulary (learn these 12 words and you can read any playbook)

| Word | What it means |
|---|---|
| **Control node** | The machine where Ansible is installed and where you run commands. |
| **Managed node** | A server Ansible logs into and changes. Also called a "host" or "target." |
| **Inventory** | The list of your servers, usually grouped (webservers, dbservers, etc.). |
| **Module** | A small unit of work Ansible knows how to do — `copy`, `service`, `user`, `dnf`. There are thousands. |
| **Task** | One call to one module. "Install nginx" is a task. |
| **Play** | A set of tasks aimed at a set of hosts. |
| **Playbook** | A YAML file containing one or more plays. This is your main script. |
| **Handler** | A special task that only runs if something *changed* — usually "restart the service." |
| **Role** | A reusable, folder-shaped bundle of tasks, files, templates, and variables. |
| **Collection** | A downloadable package of modules/roles, e.g. `community.general`. |
| **Fact** | Information Ansible discovers about a server (OS, IP, RAM, disks) before running tasks. |
| **Idempotent** | Safe to run over and over. Nothing changes if nothing needs to change. |

### How a playbook run actually works (behind the curtain)

1. You run `ansible-playbook site.yml`.
2. Ansible reads your inventory and figures out which hosts to target.
3. It opens SSH connections (many at once — 5 by default, tunable to hundreds).
4. It **gathers facts** — runs a hidden `setup` task that collects OS version, IP addresses, memory, etc.
5. For each task: Ansible **generates a small Python program** containing your module plus your arguments, copies it to the target's temp directory, runs it, reads back the JSON result, then **deletes it**.
6. It prints `ok` (already correct), `changed` (it fixed something), `skipped`, or `failed` for every host.
7. At the end of the play, it runs any **handlers** that got notified.
8. It prints the **PLAY RECAP** summary.

Nothing is left behind on the server. That's the agentless magic.

### Ansible in 2026 — the version story

- **`ansible-core`** = the engine plus a small built-in module set (`ansible.builtin.*`). Current: **2.21**. Needs **Python 3.12+ on the control node** and Python 3.8+ (roughly) on targets.
- **`ansible`** = the "batteries included" community package: ansible-core plus ~50 curated collections. Current: **Ansible 14** (built on core 2.21). Ansible 13 went end-of-life in June 2026.
- Support is short — ansible-core keeps only about **3 releases** alive at a time, so plan to upgrade roughly yearly.
- **Red Hat Ansible Automation Platform (AAP)** is the paid enterprise product: a web UI, RBAC, scheduling, credential vaulting, and support. **AWX** is its free upstream.
- **Big modern rule:** always write **FQCN** — Fully Qualified Collection Names — like `ansible.builtin.copy` instead of bare `copy`. It's unambiguous, it's lint-clean, and it's what all current docs use.

---

<a name="2-step-by-step-first-setup"></a>
## 2. Step-by-Step: Your Very First Ansible Setup

**Goal of this section:** in about 20 minutes, go from nothing to a working playbook that installs and configures a web server on two machines. Do this *before* reading the cheat sheet — everything after will make far more sense.

### Step 1 — Install Ansible on the control node

Pick **one** of these. Only the control node needs Ansible.

```bash
# Option A (RECOMMENDED for learning and for most admins): pip into a virtualenv
python3 -m venv ~/ansible-venv
source ~/ansible-venv/bin/activate
pip install --upgrade pip
pip install ansible                 # the full community package (Ansible 14)
# or: pip install ansible-core      # engine only, if you want a tiny install

# Option B: Fedora / RHEL / Rocky / Alma
sudo dnf install -y ansible-core

# Option C: Debian / Ubuntu
sudo apt update && sudo apt install -y ansible

# Option D: macOS
brew install ansible
```

Check it worked:

```bash
ansible --version
```

You should see something like `ansible [core 2.21.x]` plus the config file path and the Python version.

**Why the virtualenv option is recommended:** distro packages are often a year or two behind, and mixing pip-installed and dnf-installed Ansible causes very confusing bugs. A virtualenv keeps Ansible in its own sandbox that you can upgrade or delete without touching system Python.

### Step 2 — Set up SSH keys (Ansible's front door)

Ansible logs in over SSH. Passwords work but are painful; keys are the real answer.

```bash
# Make a key if you don't have one (ed25519 is the modern choice)
ssh-keygen -t ed25519 -C "ansible-control" -f ~/.ssh/id_ed25519

# Copy the public key to each managed node
ssh-copy-id deploy@web1.example.com
ssh-copy-id deploy@web2.example.com

# Prove it works without a password
ssh deploy@web1.example.com hostname
```

**What just happened, in plain words:** `ssh-keygen` made two matching files — a private key (secret, stays on your control node) and a public key (safe to share). `ssh-copy-id` pasted the public key into `~/.ssh/authorized_keys` on the server. Now the server can verify you are you without a password, like a lock that only your specific key shape opens.

### Step 3 — Make a project folder

```bash
mkdir -p ~/ansible-lab/{group_vars,host_vars,roles,templates,files}
cd ~/ansible-lab
```

### Step 4 — Write the inventory (your list of servers)

Create `~/ansible-lab/inventory.ini`:

```ini
[webservers]
web1.example.com
web2.example.com

[dbservers]
db1.example.com

# A group made of other groups
[production:children]
webservers
dbservers

# Variables applied to everything in the webservers group
[webservers:vars]
http_port=80
app_name=demoapp

# All hosts everywhere: which user to log in as
[all:vars]
ansible_user=deploy
```

The same thing in YAML (`inventory.yml`) — many teams prefer this because it nests better:

```yaml
all:
  vars:
    ansible_user: deploy
  children:
    webservers:
      hosts:
        web1.example.com:
        web2.example.com:
      vars:
        http_port: 80
        app_name: demoapp
    dbservers:
      hosts:
        db1.example.com:
```

**No real servers?** Practice against your own machine:

```ini
[local]
localhost ansible_connection=local
```

### Step 5 — Write `ansible.cfg` (your settings file)

Create `~/ansible-lab/ansible.cfg`:

```ini
[defaults]
inventory            = ./inventory.ini
remote_user          = deploy
host_key_checking    = True
forks                = 20
stdout_callback      = yaml
callbacks_enabled    = timer, profile_tasks
interpreter_python   = auto_silent
retry_files_enabled  = False
nocows               = True

[privilege_escalation]
become        = False
become_method = sudo
become_user   = root
become_ask_pass = False

[ssh_connection]
pipelining = True
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s -o PreferredAuthentications=publickey
```

**Line-by-line, in plain words:**

- `inventory` — so you don't have to type `-i inventory.ini` every time.
- `forks = 20` — talk to 20 servers at the same time instead of 5. Big speed win.
- `stdout_callback = yaml` — makes output human-readable instead of one giant JSON line.
- `profile_tasks` — prints how long each task took, so you can find the slow one.
- `pipelining = True` — cuts the number of SSH round-trips per task roughly in half. **Caveat:** it needs `requiretty` to be off in the target's sudoers file (it's off by default on modern distros).
- `ControlPersist=60s` — reuses one SSH connection for 60 seconds instead of reconnecting for every single task. Another huge speed win.
- `host_key_checking = True` — keeps SSH's protection against someone impersonating your server. Turning it off is common in labs and a **bad habit** in production.

**Security warning:** Ansible reads `ansible.cfg` from the current directory. Never run `ansible-playbook` from a directory someone else can write to — a malicious `ansible.cfg` there could hijack your run.

### Step 6 — Test the connection (your first ad-hoc command)

```bash
cd ~/ansible-lab
ansible all -m ansible.builtin.ping
```

Good output:

```
web1.example.com | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

`ping` here is **not** ICMP ping. It means "I logged in over SSH, I found a working Python, and I ran a tiny module successfully." It's an end-to-end handshake test.

### Step 7 — Your first playbook

Create `~/ansible-lab/first.yml`:

```yaml
---
- name: Set up a basic web server
  hosts: webservers
  become: true                    # run tasks with sudo
  gather_facts: true

  vars:
    web_package: nginx
    web_service: nginx
    web_root: /usr/share/nginx/html

  tasks:
    - name: Install the web server package
      ansible.builtin.package:
        name: "{{ web_package }}"
        state: present

    - name: Deploy the home page from a template
      ansible.builtin.template:
        src: templates/index.html.j2
        dest: "{{ web_root }}/index.html"
        owner: root
        group: root
        mode: "0644"
        backup: true
      notify: Restart web service

    - name: Make sure the service is started and enabled at boot
      ansible.builtin.service:
        name: "{{ web_service }}"
        state: started
        enabled: true

    - name: Confirm the site answers on port 80
      ansible.builtin.uri:
        url: "http://{{ ansible_default_ipv4.address }}/"
        status_code: 200
      register: site_check
      retries: 3
      delay: 2
      until: site_check.status == 200

  handlers:
    - name: Restart web service
      ansible.builtin.service:
        name: "{{ web_service }}"
        state: restarted
```

Create `~/ansible-lab/templates/index.html.j2`:

```jinja
<!DOCTYPE html>
<html>
<head><title>{{ app_name | default('My App') }}</title></head>
<body>
  <h1>Hello from {{ inventory_hostname }}</h1>
  <ul>
    <li>OS: {{ ansible_distribution }} {{ ansible_distribution_version }}</li>
    <li>Kernel: {{ ansible_kernel }}</li>
    <li>CPUs: {{ ansible_processor_vcpus }}</li>
    <li>Memory: {{ ansible_memtotal_mb }} MB</li>
    <li>IP: {{ ansible_default_ipv4.address }}</li>
    <li>Built: {{ ansible_date_time.iso8601 }}</li>
  </ul>
</body>
</html>
```

### Step 8 — Check your work before running it

```bash
# 1. Is the YAML even valid, and does it parse?
ansible-playbook first.yml --syntax-check

# 2. Which hosts would this hit?
ansible-playbook first.yml --list-hosts

# 3. DRY RUN: pretend to run, change nothing, show what would change
ansible-playbook first.yml --check --diff
```

`--check` is your seatbelt. `--diff` shows the actual before/after text of any file it would touch. **Get in the habit of always running `--check --diff` first.**

### Step 9 — Run it for real

```bash
ansible-playbook first.yml
```

Reading the output:

```
PLAY [Set up a basic web server] ***********************

TASK [Gathering Facts] *********************************
ok: [web1.example.com]

TASK [Install the web server package] ******************
changed: [web1.example.com]

TASK [Deploy the home page from a template] ************
changed: [web1.example.com]

RUNNING HANDLER [Restart web service] ******************
changed: [web1.example.com]

PLAY RECAP *********************************************
web1.example.com : ok=5 changed=3 unreachable=0 failed=0 skipped=0
```

### Step 10 — Prove idempotency (the payoff)

Run the exact same command again:

```bash
ansible-playbook first.yml
```

```
PLAY RECAP
web1.example.com : ok=5 changed=0 unreachable=0 failed=0 skipped=0
```

**`changed=0`.** Nothing happened, because nothing needed to happen. That is the whole point of Ansible, and it is the test of a well-written playbook. If your second run still shows changes, you have a bug — usually a `command`/`shell` task without a guard.

**You now know Ansible.** Everything below is detail, breadth, and polish.

---

<a name="3-cheat-sheet-keywords"></a>
## 3. Cheat Sheet: Every Keyword, Flag, and Module You Need

This is the "look it up fast" section. Bullet lists first, deep examples later.

### 3.1 Command-line tools

- **`ansible`** — run a single module against hosts right now (ad-hoc). `ansible web -m ping`
- **`ansible-playbook`** — run a playbook. The one you use 95% of the time.
- **`ansible-doc`** — built-in manual for every module. `ansible-doc ansible.builtin.copy`
- **`ansible-inventory`** — inspect/expand inventory. `ansible-inventory --graph`
- **`ansible-vault`** — encrypt/decrypt secrets.
- **`ansible-galaxy`** — install roles and collections.
- **`ansible-config`** — show/dump current settings. `ansible-config dump --only-changed`
- **`ansible-console`** — an interactive REPL shell against your inventory.
- **`ansible-pull`** — flip to pull-mode: the node clones a git repo and runs a playbook on itself.
- **`ansible-lint`** — (separate install) static checker for style and bugs. **Use it.**
- **`ansible-navigator`** — modern TUI runner using execution environments (containers).

### 3.2 `ansible-playbook` flags — the ones that matter

**Targeting and inventory**
- `-i, --inventory PATH` — inventory file, directory, or dynamic script.
- `-l, --limit PATTERN` — only these hosts. `--limit web1,web2` or `--limit 'webservers:!web3'`
- `--limit @retry.txt` — re-run only the hosts that failed last time.
- `-e, --extra-vars` — highest-precedence variables. `-e "version=1.4"` or `-e @vars.json`

**Safety and preview**
- `-C, --check` — dry run, change nothing.
- `-D, --diff` — show file before/after.
- `--syntax-check` — parse only.
- `--list-hosts` / `--list-tasks` / `--list-tags` — show what *would* run.
- `--step` — ask y/n before every single task.
- `--start-at-task "NAME"` — begin partway through a playbook.

**Speed and connection**
- `-f, --forks N` — parallel hosts (default 5).
- `-c, --connection ssh|local|docker|winrm`
- `-T, --timeout N` — SSH connect timeout.

**Privileges and auth**
- `-b, --become` — use sudo.
- `--become-user root` — become who.
- `-K, --ask-become-pass` — prompt for the sudo password.
- `-k, --ask-pass` — prompt for the SSH password.
- `-u, --user USER` — SSH as this user.
- `--private-key FILE` — specific SSH key.

**Selecting parts of a playbook**
- `-t, --tags "config,deploy"` — only run tasks with these tags.
- `--skip-tags "slow,reboot"` — run everything except these.

**Secrets**
- `--ask-vault-pass` — prompt for the vault password.
- `--vault-password-file FILE` / `--vault-id prod@prompt`

**Debugging**
- `-v` / `-vv` / `-vvv` / `-vvvv` — more output; `-vvvv` includes SSH connection debugging.

### 3.3 Play-level keywords (top of a playbook)

- `name:` — human description of the play.
- `hosts:` — which hosts/groups/patterns.
- `become:` / `become_user:` / `become_method:` — privilege escalation.
- `gather_facts:` — `true`/`false`. Turn off for speed when you don't need facts.
- `vars:` / `vars_files:` / `vars_prompt:` — variables.
- `serial:` — batch size for rolling updates (`2`, `25%`, or a list `[1, 5, "30%"]`).
- `max_fail_percentage:` — abort the play if more than N% of hosts fail.
- `order:` — `inventory`, `sorted`, `reverse_sorted`, `shuffle`.
- `strategy:` — `linear` (default), `free` (hosts race ahead independently), `host_pinned`, `debug`.
- `any_errors_fatal:` — one host failing stops everything, everywhere.
- `roles:` — static list of roles to apply.
- `pre_tasks:` / `tasks:` / `post_tasks:` / `handlers:` — the four execution blocks, in that order.
- `environment:` — env vars for every task in the play.
- `force_handlers:` — run handlers even if the play fails.
- `run_once:` — do this on only the first host.
- `collections:` — (legacy) implicit collection search path; prefer FQCN instead.

### 3.4 Task-level keywords

- `name:` — always write one. It's your log message.
- `when:` — conditional (Jinja expression, no `{{ }}` needed).
- `loop:` / `loop_control:` — repeat with different items.
- `register:` — save the result into a variable.
- `notify:` — trigger a handler if this task changed.
- `changed_when:` / `failed_when:` — override how Ansible decides changed/failed.
- `ignore_errors: true` — keep going on failure.
- `ignore_unreachable: true` — keep going if the host is down.
- `retries:` / `delay:` / `until:` — retry loop.
- `tags:` — label for selective runs. `always` and `never` are special.
- `become:` / `become_user:` — per-task privilege escalation.
- `delegate_to:` / `delegate_facts:` — run this task on a *different* host (e.g., the load balancer).
- `local_action:` — shorthand for `delegate_to: localhost`.
- `run_once: true` — run on one host only, share the result with all.
- `throttle: N` — max N hosts at a time for this task only.
- `async:` / `poll:` — run long jobs in the background (`poll: 0` = fire and forget).
- `no_log: true` — hide the task's output. **Mandatory for passwords.**
- `check_mode: false` — force a task to really run even during `--check`.
- `diff: true` — force diff output for this task.
- `vars:` — variables scoped to this one task.
- `environment:` — env vars for this one task.
- `timeout: N` — kill the task after N seconds.

### 3.5 Block keywords (grouping and error handling)

- `block:` — group of tasks that share `when`, `become`, `tags`.
- `rescue:` — runs if anything in the block failed (like `catch`).
- `always:` — runs no matter what (like `finally`).

### 3.6 Core modules by job — the working list

**Packages**
- `ansible.builtin.package` — generic, auto-picks the right manager.
- `ansible.builtin.dnf` / `ansible.builtin.dnf5` — RHEL/Fedora/Rocky/Alma.
- `ansible.builtin.apt` — Debian/Ubuntu. Friends: `apt_key` (deprecated), `apt_repository`, `deb822_repository`.
- `ansible.builtin.yum_repository` — manage `.repo` files.
- `ansible.builtin.rpm_key` — trust a GPG key.
- `community.general.zypper`, `community.general.pacman`, `community.general.apk`, `community.general.snap`, `community.general.flatpak`, `community.general.homebrew`
- `ansible.builtin.pip`, `community.general.npm`, `community.general.gem`

**Services and processes**
- `ansible.builtin.service` — generic service control.
- `ansible.builtin.systemd_service` — systemd-specific (`daemon_reload`, `masked`, `scope`).
- `ansible.builtin.service_facts` — inventory of every service and its state.
- `ansible.builtin.reboot` — reboot and wait for the host to come back.
- `ansible.builtin.wait_for` / `wait_for_connection` — wait for a port, file, or the host itself.
- `community.general.pids` — find PIDs by process name.

**Files and directories**
- `ansible.builtin.copy` — push a file (or inline `content`) to the target.
- `ansible.builtin.template` — push a file *after* filling in variables (Jinja2). **The workhorse.**
- `ansible.builtin.file` — create/delete/chmod/chown files, dirs, and symlinks.
- `ansible.builtin.lineinfile` — make sure one specific line exists/matches.
- `ansible.builtin.blockinfile` — manage a marked block of lines.
- `ansible.builtin.replace` — regex search/replace across a file.
- `ansible.builtin.stat` — inspect a path (exists? size? mode? checksum?).
- `ansible.builtin.find` — search for files by age, size, name, pattern.
- `ansible.builtin.fetch` — pull a file *from* targets *to* the control node.
- `ansible.builtin.slurp` — read a remote file's contents into a variable (base64).
- `ansible.builtin.unarchive` — unpack .tar/.tar.gz/.zip (can download first).
- `community.general.archive` — create an archive on the target.
- `ansible.posix.synchronize` — rsync wrapper for big trees.
- `ansible.builtin.assemble` — build one config file from many fragments.
- `ansible.builtin.tempfile` — make a safe temp file/dir.
- `ansible.builtin.acl` (in `ansible.posix`) — POSIX ACLs.
- `ansible.builtin.iso_extract`, `community.general.filesize`

**Users, groups, and access**
- `ansible.builtin.user` — accounts, shells, home dirs, passwords, SSH key generation.
- `ansible.builtin.group` — groups.
- `ansible.posix.authorized_key` — manage `~/.ssh/authorized_keys`.
- `ansible.builtin.known_hosts` — manage SSH host keys.
- `community.general.sudoers` — safely write `/etc/sudoers.d/*` files.
- `ansible.builtin.pam_limits` (in `community.general`) — `/etc/security/limits.conf`.

**Commands (the escape hatch)**
- `ansible.builtin.command` — run a binary, no shell. **Preferred.**
- `ansible.builtin.shell` — run through `/bin/sh`, so pipes/redirects/globs work.
- `ansible.builtin.raw` — no Python needed on target (bootstrapping only).
- `ansible.builtin.script` — copy a local script over, run it, delete it.
- `ansible.builtin.expect` — answer interactive prompts.

**System configuration**
- `ansible.posix.sysctl` — kernel parameters.
- `ansible.posix.mount` — `/etc/fstab` and mounting.
- `ansible.builtin.hostname` — set the hostname.
- `ansible.builtin.timezone` (in `community.general`) — timezone.
- `ansible.builtin.cron` — crontab entries and `/etc/cron.d` files.
- `ansible.builtin.at` — one-off scheduled command.
- `community.general.alternatives` — update-alternatives.
- `community.general.modprobe` — kernel modules.
- `community.general.locale_gen` — locales.

**Storage**
- `community.general.parted` — partitions.
- `community.general.filesystem` — make a filesystem.
- `community.general.lvg` / `community.general.lvol` — LVM volume groups and logical volumes.
- `community.crypto.luks_device` — disk encryption.

**Networking and firewall**
- `ansible.posix.firewalld` — firewalld rules (RHEL family).
- `community.general.ufw` — UFW (Ubuntu).
- `ansible.builtin.iptables` — raw iptables rules.
- `ansible.builtin.uri` — make HTTP requests (great for health checks and APIs).
- `ansible.builtin.get_url` — download a file.
- `community.general.nmcli` — NetworkManager connections.
- `ansible.posix.selinux` / `ansible.posix.seboolean` — SELinux mode and booleans.

**Source control and archives**
- `ansible.builtin.git` — clone/checkout a repo.
- `ansible.builtin.subversion`

**Logic, output, and control**
- `ansible.builtin.debug` — print a message or variable.
- `ansible.builtin.assert` — fail unless a condition is true.
- `ansible.builtin.fail` — fail on purpose with a message.
- `ansible.builtin.set_fact` — create a variable at runtime.
- `ansible.builtin.include_tasks` / `import_tasks` — pull in another task file.
- `ansible.builtin.include_role` / `import_role`
- `ansible.builtin.include_vars` — load a vars file at runtime.
- `ansible.builtin.pause` — wait, or prompt the human.
- `ansible.builtin.meta` — `flush_handlers`, `end_play`, `clear_facts`, `end_host`.
- `ansible.builtin.setup` — manually gather facts (with `filter:` to gather only some).
- `ansible.builtin.gather_facts`
- `ansible.builtin.wait_for_connection`
- `ansible.builtin.add_host` / `ansible.builtin.group_by` — build inventory on the fly.

**Notification and reporting**
- `community.general.mail` — send email.
- `community.general.slack`, `community.general.mattermost`
- `ansible.builtin.uri` — POST to a webhook.

### 3.7 `state:` values you'll see everywhere

- **Packages:** `present`, `absent`, `latest`, `installed`, `removed`
- **Services:** `started`, `stopped`, `restarted`, `reloaded` (plus `enabled: true/false` for boot)
- **Files (`file` module):** `file`, `directory`, `link`, `hard`, `touch`, `absent`
- **Lines (`lineinfile`):** `present`, `absent`
- **Users/groups:** `present`, `absent`
- **Mounts:** `present` (fstab only), `mounted`, `unmounted`, `absent`, `remounted`

### 3.8 Most useful built-in facts

Run `ansible HOST -m ansible.builtin.setup` to see all of them (there are hundreds).

- `ansible_hostname`, `ansible_fqdn`, `ansible_nodename`
- `inventory_hostname`, `inventory_hostname_short` *(these are magic vars, not facts)*
- `ansible_distribution` — `Ubuntu`, `RedHat`, `Rocky`, `Debian`, `Amazon`
- `ansible_distribution_version` / `_major_version`
- `ansible_os_family` — `RedHat`, `Debian`, `Suse`, `Archlinux`
- `ansible_kernel`, `ansible_architecture`
- `ansible_pkg_mgr`, `ansible_service_mgr`
- `ansible_default_ipv4.address` / `.gateway` / `.interface`
- `ansible_all_ipv4_addresses`, `ansible_interfaces`
- `ansible_processor_vcpus`, `ansible_processor_cores`
- `ansible_memtotal_mb`, `ansible_memfree_mb`
- `ansible_mounts` — list of mounted filesystems with sizes
- `ansible_devices` — every block device
- `ansible_date_time.iso8601`, `.date`, `.epoch`
- `ansible_env` — the remote user's environment variables
- `ansible_virtualization_type` / `_role` — `kvm`, `docker`, `guest`/`host`
- `ansible_selinux.status`
- `ansible_uptime_seconds`

### 3.9 Magic variables (Ansible tells you about itself)

- `inventory_hostname` — the name of the current host *as written in inventory*.
- `hostvars` — a dict of every host's variables/facts. `hostvars['db1']['ansible_default_ipv4']['address']`
- `groups` — dict of group name → host list. `groups['webservers']`
- `group_names` — the groups the current host belongs to.
- `ansible_play_hosts` / `ansible_play_batch` — hosts still alive in this play/batch.
- `ansible_playbook_python` — the Python running Ansible.
- `playbook_dir`, `role_path`, `inventory_dir`
- `ansible_version` — dict with `major`, `minor`, `full`.
- `ansible_check_mode` — `true` during `--check`.
- `ansible_loop.index` / `.index0` / `.first` / `.last` (with `extended: true`).
- `omit` — the magic "pretend I didn't set this parameter" value.

### 3.10 Jinja2 filters cheat list

**Defaults and safety**
- `| default('x')` — fallback value.
- `| default('x', true)` — also use fallback when the value is empty/false.
- `| mandatory` — error out if undefined.

**Strings**
- `| upper`, `| lower`, `| capitalize`, `| trim`, `| replace('a','b')`
- `| regex_search('pat')`, `| regex_replace('p','r')`, `| regex_findall('p')`
- `| split(',')`, `| join(', ')`
- `| basename`, `| dirname`, `| realpath`, `| expanduser`, `| splitext`
- `| quote` — make a string shell-safe. **Always use this before putting a variable in `shell:`.**
- `| b64encode`, `| b64decode`
- `| hash('sha256')`, `| password_hash('sha512')`
- `| to_uuid`, `| urlencode`

**Numbers and math**
- `| int`, `| float`, `| round(2)`, `| abs`
- `| human_readable`, `| human_to_bytes`
- `| pow(2)`, `| root`

**Lists**
- `| length`, `| first`, `| last`, `| unique`, `| sort`, `| reverse`
- `| union(b)`, `| intersect(b)`, `| difference(b)`, `| symmetric_difference(b)`
- `| flatten`, `| zip(b)`, `| batch(3)`, `| slice(3)`
- `| map('upper')`, `| map(attribute='name')`
- `| select('match','^web')`, `| reject('search','test')`
- `| selectattr('state','eq','running')`, `| rejectattr('size','lt',100)`
- `| json_query('...')` — JMESPath queries (needs `community.general`).
- `| random`, `| shuffle`

**Dicts and structures**
- `| dict2items`, `| items2dict`, `| combine(other)`, `| combine(other, recursive=true)`
- `| to_json`, `| from_json`, `| to_yaml`, `| to_nice_yaml(indent=2)`
- `| subelements('users')`

**Paths, files, network**
- `| ipaddr('address')`, `| ipaddr('net')`, `| ipv4`, `| ipv6` (needs `ansible.utils`)
- `| type_debug` — tell me what type this variable actually is. **Great for debugging.**

**Tests (used with `is`)**
- `is defined`, `is undefined`, `is none`
- `is match('^web')`, `is search('web')`, `is regex('...')`
- `is file`, `is directory`, `is link`, `is exists`, `is mount`
- `is changed`, `is succeeded`, `is failed`, `is skipped` — for registered results
- `is version('2.0','>=')`
- `is subset(list)`, `is superset(list)`
- `is in [...]`

### 3.11 Common lookups (read data from the control node)

- `{{ lookup('ansible.builtin.file', '/path/local.txt') }}`
- `{{ lookup('ansible.builtin.env', 'HOME') }}`
- `{{ lookup('ansible.builtin.pipe', 'date +%s') }}`
- `{{ lookup('ansible.builtin.password', '/dev/null length=20') }}`
- `{{ lookup('ansible.builtin.template', 'x.j2') }}`
- `{{ lookup('ansible.builtin.ini', 'key section=main file=x.ini') }}`
- `{{ lookup('ansible.builtin.csvfile', 'web1 file=hosts.csv delimiter=, col=1') }}`
- `{{ lookup('community.general.passwordstore', 'db/prod') }}`
- `{{ query('ansible.builtin.fileglob', '/etc/conf.d/*.conf') }}` — `query()` always returns a list; prefer it for loops.

### 3.12 Return values you'll check constantly

After `register: result`:

- `result.rc` — exit code (command/shell).
- `result.stdout` / `result.stderr` — output as one string.
- `result.stdout_lines` / `result.stderr_lines` — output as a list. **Much easier to loop.**
- `result.changed` / `result.failed` / `result.skipped`
- `result.msg` — human message.
- `result.results` — list of per-item results when the task had a `loop`.
- `result.stat.exists` / `.isdir` / `.mode` / `.size` / `.checksum` — from `stat`.
- `result.content` — from `slurp` (base64; decode with `| b64decode`).
- `result.status` / `result.json` — from `uri`.
- `result.attempts` — how many retries it took.

### 3.13 Tag keywords

- `tags: [install, config]` — normal tags.
- `tags: always` — runs even when `--tags something_else` is used (unless `--skip-tags always`).
- `tags: never` — only runs when explicitly requested by name.
- `--tags tagged` / `--tags untagged` / `--tags all` — special selectors.

---

<a name="4-packages-and-services"></a>
## 4. Detailed Examples: Package & Service Management

### 4.1 Installing packages the portable way

```yaml
- name: Install a package list on any Linux distro
  hosts: all
  become: true
  vars:
    common_packages: [vim, curl, git, htop, rsync, tmux]

  tasks:
    - name: Install common tools (generic module)
      ansible.builtin.package:
        name: "{{ common_packages }}"
        state: present
```

**What's happening:** `package` is a "wrapper" module. It looks at the fact `ansible_pkg_mgr` and calls `dnf`, `apt`, `zypper`, or `pacman` for you. Passing a **list** to `name:` is important — Ansible sends all six package names to the package manager in **one transaction** instead of running it six times. On a slow server that's the difference between 4 seconds and 40.

**When `package` isn't enough:** package *names* differ between distros. Apache is `httpd` on RHEL and `apache2` on Debian. So you map them:

```yaml
- name: Install the right web server for this distro
  hosts: webservers
  become: true
  vars:
    web_pkg:
      RedHat: httpd
      Debian: apache2
      Suse: apache2
  tasks:
    - name: Install web server
      ansible.builtin.package:
        name: "{{ web_pkg[ansible_os_family] }}"
        state: present
```

**Reading `web_pkg[ansible_os_family]`:** `web_pkg` is a dictionary (like a lookup table). `ansible_os_family` is a fact that will be the string `"RedHat"` on a Rocky box. So the expression becomes `web_pkg["RedHat"]`, which is `httpd`. One playbook, three distro families.

### 4.2 Distro-specific power features

```yaml
# ---- RHEL family ----
- name: Install with dnf, enabling a module stream and a specific repo
  ansible.builtin.dnf:
    name:
      - nginx
      - php
    state: present
    enablerepo: epel
    disable_gpg_check: false
    install_weak_deps: false     # skip "recommended" extras — leaner servers

- name: Apply only security updates
  ansible.builtin.dnf:
    name: "*"
    state: latest
    security: true
    bugfix: true

- name: Remove a package and its now-orphaned dependencies
  ansible.builtin.dnf:
    name: telnet
    state: absent
    autoremove: true

# ---- Debian family ----
- name: Update apt cache if it is older than 1 hour, then install
  ansible.builtin.apt:
    name: [nginx, ufw]
    state: present
    update_cache: true
    cache_valid_time: 3600       # seconds; avoids a slow re-fetch every run

- name: Safe distribution upgrade
  ansible.builtin.apt:
    upgrade: safe                # options: 'no', 'yes', 'safe', 'full', 'dist'
    autoremove: true
    autoclean: true

- name: Hold a package at its current version
  ansible.builtin.dpkg_selections:
    name: kubelet
    selection: hold
```

**`cache_valid_time` explained:** `apt-get update` downloads package indexes from the internet and can take 10–30 seconds. `cache_valid_time: 3600` means "if we already updated within the last hour, don't bother." It makes repeat runs dramatically faster.

### 4.3 Adding repositories

```yaml
# Modern Debian/Ubuntu — deb822 format (replaces the old apt_key + apt_repository dance)
- name: Add the Docker repository (deb822, current best practice)
  ansible.builtin.deb822_repository:
    name: docker
    types: [deb]
    uris: "https://download.docker.com/linux/{{ ansible_distribution | lower }}"
    suites: ["{{ ansible_distribution_release }}"]
    components: [stable]
    architectures: [amd64]
    signed_by: https://download.docker.com/linux/ubuntu/gpg
    state: present
  notify: Update apt cache

# RHEL family
- name: Trust the EPEL GPG key
  ansible.builtin.rpm_key:
    key: https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-9
    state: present

- name: Add an internal YUM repo
  ansible.builtin.yum_repository:
    name: internal-tools
    description: Internal Tools Repo
    baseurl: https://repo.example.com/rhel/$releasever/$basearch/
    gpgcheck: true
    gpgkey: https://repo.example.com/RPM-GPG-KEY-internal
    enabled: true
    priority: 5
```

**Why `apt_key` is gone:** older guides tell you to run `apt-key add`. That command is deprecated and removed on modern Debian/Ubuntu because it put every key in one global trust store — meaning any repo could sign any package. `signed_by` scopes a key to one repo only. Use `deb822_repository`.

### 4.4 Services

```yaml
- name: Full service lifecycle
  hosts: all
  become: true
  tasks:
    - name: Start now and enable at boot
      ansible.builtin.systemd_service:
        name: nginx
        state: started
        enabled: true
        daemon_reload: true       # re-read unit files first

    - name: Reload config without dropping connections
      ansible.builtin.systemd_service:
        name: nginx
        state: reloaded

    - name: Stop and disable something we don't want
      ansible.builtin.systemd_service:
        name: telnet.socket
        state: stopped
        enabled: false
        masked: true              # masked = cannot even be started by accident

    - name: Gather every service's state into a fact
      ansible.builtin.service_facts:

    - name: Report on sshd
      ansible.builtin.debug:
        msg: "sshd is {{ ansible_facts.services['sshd.service'].state }}"
      when: "'sshd.service' in ansible_facts.services"
```

**`started` vs `restarted` — the single most common beginner bug:**

- `state: started` means "**make sure it is running.**" If it's already running, do nothing. Idempotent. ✅
- `state: restarted` means "**stop and start it right now, always.**" It changes every single run and briefly drops your service. ❌ in a plain task.

**Rule:** use `state: started` in tasks, and put `state: restarted` **only in handlers** so restarts happen just when the config actually changed.

**`masked: true` explained:** disabling a service stops it from starting at boot, but another package's dependency can still pull it up. Masking points the unit at `/dev/null` — it becomes literally unstartable. It's the difference between "don't come in" and locking the door.

### 4.5 Creating a systemd unit from scratch

```yaml
- name: Install a custom app as a systemd service
  hosts: appservers
  become: true
  tasks:
    - name: Write the unit file
      ansible.builtin.template:
        src: myapp.service.j2
        dest: /etc/systemd/system/myapp.service
        owner: root
        group: root
        mode: "0644"
        validate: /usr/bin/systemd-analyze verify %s
      notify:
        - Reload systemd
        - Restart myapp

    - name: Ensure it runs at boot
      ansible.builtin.systemd_service:
        name: myapp
        enabled: true
        state: started
        daemon_reload: true

  handlers:
    - name: Reload systemd
      ansible.builtin.systemd_service:
        daemon_reload: true

    - name: Restart myapp
      ansible.builtin.systemd_service:
        name: myapp
        state: restarted
```

`templates/myapp.service.j2`:

```jinja
[Unit]
Description={{ app_description | default('My Application') }}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{ app_user }}
Group={{ app_group }}
WorkingDirectory={{ app_dir }}
ExecStart={{ app_dir }}/bin/myapp --port {{ app_port }}
Restart=on-failure
RestartSec=5
# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={{ app_dir }}/data /var/log/myapp

[Install]
WantedBy=multi-user.target
```

**`validate:` is a lifesaver.** Ansible writes the new file to a temp path, runs your validation command on it (`%s` is replaced with the temp path), and **only** moves it into place if the command exits 0. A typo in a systemd unit or an nginx config gets caught *before* it can break the server.

### 4.6 Best practices — packages & services

- ✅ Pass **lists** to `name:`, not one task per package.
- ✅ Pin versions for anything that matters: `name: nginx=1.24.0-1ubuntu1`.
- ⚠️ `state: latest` on `*` is convenient and dangerous — it can upgrade a database mid-day. Use it deliberately, in a maintenance window, with `serial:`.
- ✅ `state: present` for "must exist"; `state: latest` only during patch cycles.
- ✅ Always pair `enabled: true` with `state: started` — otherwise the service dies at the next reboot.
- ✅ Use `validate:` on every config file that has a validator (nginx, sshd, sudoers, systemd, httpd).
- ❌ Never `shell: systemctl restart x` — you lose idempotency and clean error handling.

### 4.7 Pros and cons

| Choice | Pros | Cons |
|---|---|---|
| `package` (generic) | One task works on all distros; less code | Can't use distro-specific options; package names still differ |
| `dnf`/`apt` (specific) | Full feature access (security-only, holds, weak deps) | Needs `when: ansible_os_family == ...` branching |
| `state: present` | Idempotent, predictable, safe | Servers slowly drift behind on patches |
| `state: latest` | Always current, closes CVEs fast | Non-deterministic; can break apps without warning |
| `service` | Works on systemd and old SysV | No `daemon_reload`, `masked`, or `scope` |
| `systemd_service` | Full systemd control | Fails on non-systemd hosts |

---

<a name="5-file-management"></a>
## 5. Detailed Examples: File Management

This is the bread and butter of Linux administration, so this section is the longest.

### 5.1 Choosing the right file module — decision table

| I want to... | Use |
|---|---|
| Push a whole file exactly as-is | `copy` |
| Push a file with variables filled in | `template` |
| Create a directory, symlink, or set permissions | `file` |
| Make sure one line exists in a file I don't own | `lineinfile` |
| Manage several lines as a labeled chunk | `blockinfile` |
| Regex-replace text throughout a file | `replace` |
| Check whether something exists / get its checksum | `stat` |
| Find files by age, size, or pattern | `find` |
| Bring a file *back* from the servers | `fetch` |
| Read a remote file into a variable | `slurp` |
| Unpack a tarball or zip | `unarchive` |
| Copy a big directory tree efficiently | `ansible.posix.synchronize` |
| Build one config from many fragments | `assemble` |

### 5.2 `copy` — the simple push

```yaml
- name: Copy a file from the control node to the servers
  ansible.builtin.copy:
    src: files/motd                # relative to the playbook or role's files/
    dest: /etc/motd
    owner: root
    group: root
    mode: "0644"
    backup: true                   # save the old one with a timestamp
    validate: /usr/bin/test -f %s  # optional pre-flight check

- name: Create a file directly from inline text (no source file needed)
  ansible.builtin.copy:
    content: |
      # Managed by Ansible — do not edit by hand
      net.ipv4.ip_forward = 1
      net.ipv4.conf.all.rp_filter = 1
    dest: /etc/sysctl.d/99-custom.conf
    mode: "0644"

- name: Copy an entire directory's contents (note the trailing slash)
  ansible.builtin.copy:
    src: files/scripts/            # trailing / = copy the CONTENTS
    dest: /opt/scripts/
    mode: "0755"
    directory_mode: "0755"

- name: Copy a file that already exists ON the target (remote to remote)
  ansible.builtin.copy:
    src: /etc/nginx/nginx.conf
    dest: /etc/nginx/nginx.conf.golden
    remote_src: true
```

**The trailing-slash rule (people trip on this constantly):**
- `src: files/scripts/` → copies *what is inside* `scripts` into `dest`.
- `src: files/scripts` → copies *the folder itself*, producing `/opt/scripts/scripts/`.
It's the same rule as `rsync`.

**Why `mode: "0644"` is in quotes:** without quotes, YAML reads `0644` as a *number*, and depending on the parser it may become 644 decimal, which is the wrong permission bits. Quoting keeps it a string, and Ansible reads it as octal. **Always quote your modes.** You can also write symbolic modes: `mode: u=rw,g=r,o=r`.

**How `backup: true` helps:** the old file is saved as `/etc/motd.12345.2026-07-31@14:22:07~`. The task result includes `backup_file`, so you can print it or use it in a rollback.

### 5.3 `template` — the real workhorse

Templates are files with blanks that Ansible fills in per-host. This is how one config file serves 300 different servers.

`templates/nginx.conf.j2`:

```jinja
# {{ ansible_managed }}
# Generated for {{ inventory_hostname }} on {{ ansible_date_time.date }}

user  {{ nginx_user }};
worker_processes  {{ ansible_processor_vcpus }};
error_log  /var/log/nginx/error.log {{ nginx_log_level | default('warn') }};

events {
    worker_connections  {{ nginx_worker_connections | default(1024) }};
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout  {{ nginx_keepalive | default(65) }};

    {% if enable_gzip | default(true) %}
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;
    {% endif %}

    upstream app_backend {
    {% for host in groups['appservers'] %}
        server {{ hostvars[host]['ansible_default_ipv4']['address'] }}:{{ app_port }};
    {% endfor %}
    }

    server {
        listen {{ http_port | default(80) }};
        server_name {{ server_names | join(' ') }};

        location / {
            proxy_pass http://app_backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        {% for path, root in extra_locations.items() %}
        location {{ path }} {
            root {{ root }};
        }
        {% endfor %}
    }
}
```

The task:

```yaml
- name: Deploy nginx configuration
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    owner: root
    group: root
    mode: "0644"
    backup: true
    validate: nginx -t -c %s        # refuse to install a broken config
  notify: Reload nginx
```

**Jinja2 syntax, decoded:**

| Symbol | Meaning | Example |
|---|---|---|
| `{{ ... }}` | **Print** a value here | `{{ http_port }}` → `80` |
| `{% ... %}` | **Do** something (logic) — prints nothing | `{% if x %}` … `{% endif %}` |
| `{# ... #}` | A comment that never reaches the file | `{# TODO #}` |
| `\|` | A filter — transform the value | `{{ names \| join(',') }}` |
| `-` in `{%- -%}` | Trim surrounding whitespace | `{%- for x in y -%}` |

**The upstream block explained slowly:** `groups['appservers']` is the list of hostnames in that inventory group. The `for` loop walks it. `hostvars[host]` reaches into *another* host's gathered facts and pulls its IP. The result is that your load-balancer config automatically lists every app server — add a server to inventory, re-run, and the config updates itself. **This is the single biggest reason to use Ansible instead of scp.**

**`{{ ansible_managed }}`** expands into a warning comment like `Ansible managed`. Put it at the top of every generated file so the next human doesn't hand-edit a file that will be overwritten.

**Useful template options:**

```yaml
- name: Template with extra safety
  ansible.builtin.template:
    src: app.conf.j2
    dest: /etc/app/app.conf
    mode: "0640"
    lstrip_blocks: true      # strip leading whitespace before {% %}
    trim_blocks: true        # strip the newline after {% %}
    block_start_string: "[%" # change delimiters if the file itself uses {{ }}
    block_end_string: "%]"
    force: true              # overwrite even if dest exists (default true)
```

### 5.4 `file` — directories, symlinks, permissions, deletions

```yaml
- name: Create an application directory tree
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: appuser
    group: appgroup
    mode: "0750"
    recurse: false
  loop:
    - /opt/myapp
    - /opt/myapp/bin
    - /opt/myapp/data
    - /var/log/myapp

- name: Create parent directories automatically
  ansible.builtin.file:
    path: /opt/deep/nested/path/here
    state: directory
    mode: "0755"          # 'directory' state creates all missing parents

- name: Symlink the current release
  ansible.builtin.file:
    src: /opt/myapp/releases/{{ release_version }}
    dest: /opt/myapp/current
    state: link
    force: true

- name: Create an empty file if it doesn't exist (like `touch`)
  ansible.builtin.file:
    path: /var/log/myapp/app.log
    state: touch
    owner: appuser
    mode: "0640"
    modification_time: preserve     # keeps `touch` idempotent!
    access_time: preserve

- name: Delete a file or an entire directory
  ansible.builtin.file:
    path: /tmp/old-installer
    state: absent

- name: Fix ownership recursively on an existing tree
  ansible.builtin.file:
    path: /opt/myapp
    state: directory
    owner: appuser
    group: appgroup
    recurse: true

- name: Set SELinux context on a web directory
  ansible.builtin.file:
    path: /srv/www
    state: directory
    setype: httpd_sys_content_t
    seuser: system_u
```

**The `touch` trap:** by default `state: touch` updates the file's timestamp *every run*, so it always reports `changed`. Adding `modification_time: preserve` and `access_time: preserve` makes it truly idempotent — it only reports changed when it actually creates the file.

**Permissions refresher (because `0750` is not obvious):**
Three digits = owner, group, everyone else. Each digit adds up: read=4, write=2, execute=1.
- `0750` = owner rwx (7), group r-x (5), others nothing (0). Perfect for an app directory.
- `0644` = owner rw, everyone read. Standard config file.
- `0600` = owner only. Use for secrets, keys, and password files.
- `0755` = standard for directories and scripts.
- The leading `0` just tells YAML/Ansible "this is octal."

### 5.5 `lineinfile` — surgical single-line edits

Use this when you don't own the whole file and only need one setting right.

```yaml
- name: Harden SSH — disable root login
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^\s*#?\s*PermitRootLogin'     # find any form of the setting
    line: 'PermitRootLogin no'             # replace it with exactly this
    state: present
    validate: '/usr/sbin/sshd -t -f %s'    # never break SSH
    backup: true
  notify: Restart sshd

- name: Insert a line after a specific anchor
  ansible.builtin.lineinfile:
    path: /etc/hosts
    line: "10.0.0.50 db1.internal db1"
    insertafter: '^127\.0\.0\.1'
    state: present

- name: Put a line at the very top of the file
  ansible.builtin.lineinfile:
    path: /etc/motd
    line: "*** AUTHORIZED USE ONLY ***"
    insertbefore: BOF          # BOF = beginning of file; EOF also works

- name: Remove every line matching a pattern
  ansible.builtin.lineinfile:
    path: /etc/fstab
    regexp: '^/dev/sdb1'
    state: absent

- name: Create the file if it's missing
  ansible.builtin.lineinfile:
    path: /etc/sysctl.d/98-tuning.conf
    line: "vm.swappiness = 10"
    create: true
    mode: "0644"
```

**How `regexp` + `line` work together, step by step:**
1. Ansible reads the file and looks for lines matching `regexp`.
2. **If found:** the *last* matching line is replaced with `line`. Other matches are left alone (unless you look at `backrefs`).
3. **If not found:** `line` is appended at the end (or at `insertafter`/`insertbefore`).

**The classic bug:** using a `regexp` that doesn't match the *new* line. If your regexp is `^PermitRootLogin yes` and your line is `PermitRootLogin no`, then on the second run the regexp no longer matches, and Ansible appends a *second* copy. **Always write the regexp to match the setting name, not the value:** `^\s*#?\s*PermitRootLogin`.

**The `\s*#?\s*` part decoded:** `\s*` = any amount of whitespace, `#?` = an optional comment character, `\s*` = more optional whitespace. Together they match `PermitRootLogin`, `#PermitRootLogin`, and `  # PermitRootLogin` — so a commented-out setting gets properly uncommented and set.

### 5.6 `blockinfile` — manage a chunk of lines

```yaml
- name: Manage a block of hosts entries
  ansible.builtin.blockinfile:
    path: /etc/hosts
    marker: "# {mark} ANSIBLE MANAGED — cluster hosts"
    block: |
      {% for host in groups['cluster'] %}
      {{ hostvars[host].ansible_default_ipv4.address }} {{ host }} {{ hostvars[host].ansible_hostname }}
      {% endfor %}
    backup: true

- name: Add a config section to a shared file
  ansible.builtin.blockinfile:
    path: /etc/security/limits.conf
    marker: "# {mark} app limits"
    block: |
      appuser soft nofile 65536
      appuser hard nofile 65536
      appuser soft nproc  4096
    insertafter: EOF
    create: true

- name: Remove a previously managed block
  ansible.builtin.blockinfile:
    path: /etc/hosts
    marker: "# {mark} ANSIBLE MANAGED — cluster hosts"
    state: absent
```

**How the marker works:** Ansible writes `# BEGIN ANSIBLE MANAGED — cluster hosts` and `# END ...` around your block. On the next run it finds those markers and replaces everything between them. That's how it stays idempotent even when the content changes. **If you manage two blocks in one file, give each a unique `marker`** — otherwise the second block overwrites the first.

### 5.7 `replace` — regex across the whole file

```yaml
- name: Change every occurrence of the old domain
  ansible.builtin.replace:
    path: /etc/myapp/config.ini
    regexp: 'old\.example\.com'
    replace: 'new.example.com'
    backup: true

- name: Comment out all deprecated settings
  ansible.builtin.replace:
    path: /etc/app.conf
    regexp: '^(legacy_.*)$'
    replace: '# \1'          # \1 = whatever group 1 captured
```

**`lineinfile` vs `replace`:** `lineinfile` guarantees *one* line ends up correct and can add it if missing. `replace` edits *every* match and never adds anything new. Use `replace` for bulk find-and-replace, `lineinfile` for "this setting must equal this value."

### 5.8 `stat` and `find` — looking around before you act

```yaml
- name: Check whether the config exists
  ansible.builtin.stat:
    path: /etc/myapp/config.yml
    checksum_algorithm: sha256
    get_checksum: true
  register: cfg

- name: Show what we learned
  ansible.builtin.debug:
    msg: >-
      exists={{ cfg.stat.exists }}
      {% if cfg.stat.exists %}
      size={{ cfg.stat.size }} mode={{ cfg.stat.mode }}
      owner={{ cfg.stat.pw_name }} sha256={{ cfg.stat.checksum }}
      {% endif %}

- name: Only bootstrap if it's really missing
  ansible.builtin.template:
    src: config.yml.j2
    dest: /etc/myapp/config.yml
    mode: "0640"
  when: not cfg.stat.exists

- name: Find large old log files
  ansible.builtin.find:
    paths: /var/log
    patterns: ["*.log", "*.log.*", "*.gz"]
    age: 30d              # older than 30 days
    size: 10m             # bigger than 10 MB
    recurse: true
    file_type: file
    age_stamp: mtime      # mtime | ctime | atime
  register: old_logs

- name: Delete them
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ old_logs.files }}"
  loop_control:
    label: "{{ item.path }}"   # keeps output readable
```

**Why `loop_control: label:` matters:** without it, Ansible prints the entire `item` dictionary — dozens of lines of metadata per file. `label` prints just the path. Your log output goes from unreadable to readable.

### 5.9 `fetch` and `slurp` — pulling data back

```yaml
- name: Collect each server's sshd_config to the control node
  ansible.builtin.fetch:
    src: /etc/ssh/sshd_config
    dest: ./collected/            # becomes ./collected/web1/etc/ssh/sshd_config
    flat: false                   # false = keep the host/path structure
  # flat: true + dest: ./collected/{{ inventory_hostname }}.conf gives flat names

- name: Read a small remote file into a variable
  ansible.builtin.slurp:
    src: /etc/machine-id
  register: mid

- name: Print it
  ansible.builtin.debug:
    msg: "machine-id is {{ mid.content | b64decode | trim }}"
```

**`fetch` vs `slurp`:** `fetch` writes a **file** onto your control node — good for gathering evidence, backups, or audits. `slurp` returns the **content as base64 text** inside a variable — good when you just want to read a value and branch on it. `slurp` loads the file into memory, so don't use it on a 2 GB log.

### 5.10 Downloading, unpacking, and syncing

```yaml
- name: Download a release tarball with checksum verification
  ansible.builtin.get_url:
    url: https://releases.example.com/myapp-{{ app_version }}.tar.gz
    dest: /tmp/myapp-{{ app_version }}.tar.gz
    checksum: "sha256:{{ app_sha256 }}"
    mode: "0644"
    timeout: 60
  register: dl

- name: Unpack it
  ansible.builtin.unarchive:
    src: /tmp/myapp-{{ app_version }}.tar.gz
    dest: /opt/myapp/releases/
    remote_src: true            # the archive is already ON the target
    owner: appuser
    group: appgroup
    creates: /opt/myapp/releases/myapp-{{ app_version }}   # skip if already there

- name: Download AND unpack in one step
  ansible.builtin.unarchive:
    src: https://releases.example.com/tool.tar.gz
    dest: /opt/tools
    remote_src: true

- name: Rsync a big directory tree (fast, only sends differences)
  ansible.posix.synchronize:
    src: ./site-content/
    dest: /var/www/html/
    delete: true                # remove files on target that aren't in src
    recursive: true
    rsync_opts:
      - "--exclude=.git"
      - "--exclude=*.tmp"
      - "--chmod=D0755,F0644"

- name: Archive a directory on the target
  community.general.archive:
    path: /var/log/myapp
    dest: /backup/myapp-logs-{{ ansible_date_time.date }}.tar.gz
    format: gz
    remove: false
```

**`checksum:` is not optional in production.** It verifies the download actually matches what you expect — protecting you from a corrupted transfer *and* from a compromised mirror. It also makes the task idempotent: if the file exists and matches, nothing is downloaded.

**`creates:` explained:** "if this path already exists, consider this task already done and skip it." It's the standard way to make a non-idempotent operation idempotent.

**`copy` vs `synchronize`:** `copy` checksums every file individually through Ansible, which is slow past a few hundred files. `synchronize` shells out to rsync, which is built for this and transfers only changed blocks. Rule of thumb: under ~50 small files → `copy`; a website or code tree → `synchronize`. Downside: `synchronize` needs rsync installed on both ends and gets awkward with `become` and bastion hosts.

### 5.11 `assemble` — build a config from fragments

```yaml
- name: Drop config fragments
  ansible.builtin.copy:
    src: "files/logrotate.d/{{ item }}"
    dest: "/etc/myapp/conf.d/{{ item }}"
    mode: "0644"
  loop: [00-base.conf, 10-tuning.conf, 20-app.conf]

- name: Assemble them into one file
  ansible.builtin.assemble:
    src: /etc/myapp/conf.d
    dest: /etc/myapp/final.conf
    owner: root
    mode: "0644"
    delimiter: "\n# ---- fragment boundary ----\n"
    validate: /usr/bin/myapp --check-config %s
  notify: Restart myapp
```

Useful for daemons that **don't** support an `include` directive — you get modular source files and a single generated output.

### 5.12 Best practices — files

- ✅ Prefer **whole-file `template`** over many `lineinfile` edits. Owning the file means you know exactly what's in it.
- ✅ Use `lineinfile`/`blockinfile` only when a file is shared with a package or another tool.
- ✅ `validate:` on everything that has a validator — it's the difference between a failed task and a 3 a.m. outage.
- ✅ `backup: true` on anything you edit in place.
- ✅ Always quote `mode:`.
- ✅ Put `{{ ansible_managed }}` in every generated file.
- ✅ Use `--check --diff` before every real run.
- ❌ Don't use `shell: sed -i ...`. That's `replace` or `lineinfile`, and sed gives you no idempotency, no backup, no diff.
- ❌ Don't `copy` secrets in plain text — use Vault, and add `no_log: true`.

### 5.13 Pros and cons — file modules

| Module | Pros | Cons |
|---|---|---|
| `copy` | Simple; exact; can use inline `content`; supports `validate` | Slow for many files; no variables |
| `template` | Variables, loops, conditionals; one file serves all hosts | Must learn Jinja2; a template error breaks all hosts at once |
| `lineinfile` | Surgical; safe on files you don't own | Regex bugs cause duplicate lines; hard to review; doesn't scale past a few settings |
| `blockinfile` | Groups related lines; clean removal | Only one block per marker; a hand-edit inside the block gets silently wiped |
| `replace` | Great for bulk rename/refactor | Can't add missing content; a greedy regex can wreck a file |
| `synchronize` | Very fast for large trees; rsync semantics | Extra dependency; awkward with `become`/jump hosts; not pure Ansible |
| `assemble` | Modularity for daemons without `include` | Extra indirection; two places to look |

---

<a name="6-configuration-management"></a>
## 6. Detailed Examples: Configuration Management

"Configuration management" means: the config files on 300 servers are correct, identical where they should be identical, different where they should be different, and provably so.

### 6.1 The complete pattern (learn this shape and reuse it forever)

```yaml
---
- name: Configure the SSH daemon safely
  hosts: all
  become: true

  vars:
    sshd_port: 22
    sshd_permit_root: "no"
    sshd_password_auth: "no"
    sshd_allow_groups: [wheel, sshusers]
    sshd_max_auth_tries: 3

  tasks:
    # 1. PROVE the thing you depend on exists
    - name: Verify sshd is installed
      ansible.builtin.stat:
        path: /etc/ssh/sshd_config
      register: sshd_cfg
      failed_when: not sshd_cfg.stat.exists

    # 2. BACK UP before touching anything
    - name: Snapshot the current config
      ansible.builtin.copy:
        src: /etc/ssh/sshd_config
        dest: "/etc/ssh/sshd_config.bak.{{ ansible_date_time.epoch }}"
        remote_src: true
        mode: "0600"
      changed_when: false

    # 3. WRITE the new config, validated
    - name: Deploy sshd_config from template
      ansible.builtin.template:
        src: sshd_config.j2
        dest: /etc/ssh/sshd_config
        owner: root
        group: root
        mode: "0600"
        backup: true
        validate: "/usr/sbin/sshd -t -f %s"
      notify: Restart sshd

    # 4. APPLY changes now, not at the end of the play
    - name: Flush handlers so sshd restarts before we test it
      ansible.builtin.meta: flush_handlers

    # 5. VERIFY it actually works
    - name: Confirm SSH is accepting connections on the new port
      ansible.builtin.wait_for:
        port: "{{ sshd_port }}"
        host: "{{ ansible_default_ipv4.address }}"
        timeout: 30
      delegate_to: localhost
      become: false

  handlers:
    - name: Restart sshd
      ansible.builtin.systemd_service:
        name: "{{ 'sshd' if ansible_os_family == 'RedHat' else 'ssh' }}"
        state: restarted
```

**Why this order matters:**
1. **Check** — fail fast and clearly if the machine isn't what you assumed.
2. **Back up** — you can always get back. (`changed_when: false` stops this housekeeping step from polluting your "changed" count.)
3. **Write with `validate`** — a syntax error never reaches disk.
4. **`flush_handlers`** — handlers normally run at the *end* of the play. Here you need the restart to happen *before* the verification step, so you force it early.
5. **Verify** — trust nothing. `delegate_to: localhost` means the check runs from your control node, so you're testing the connection the way a real user would.

**The `{{ 'sshd' if ... else 'ssh' }}` bit:** that's a Jinja inline conditional (a "ternary"). Read it as: use `sshd` when the OS family is RedHat, otherwise `ssh`. Debian and RHEL genuinely name this service differently.

### 6.2 Layering variables so hosts differ correctly

Directory layout:

```
inventory/
  production/
    hosts.yml
    group_vars/
      all.yml
      webservers.yml
      dbservers.yml
    host_vars/
      web1.example.com.yml
```

`group_vars/all.yml`:

```yaml
timezone: UTC
ntp_servers: [0.pool.ntp.org, 1.pool.ntp.org]
admin_email: ops@example.com
log_retention_days: 30
```

`group_vars/webservers.yml`:

```yaml
http_port: 80
https_port: 443
nginx_worker_connections: 2048
log_retention_days: 14        # overrides 'all'
```

`host_vars/web1.example.com.yml`:

```yaml
nginx_worker_connections: 8192   # this one box is beefier
server_names: [www.example.com, example.com]
```

**Variable precedence — the short version (later wins):**
1. Role defaults (`roles/x/defaults/main.yml`) — lowest, meant to be overridden
2. Inventory group vars (`all` → specific groups)
3. `group_vars/`
4. `host_vars/`
5. Facts and `set_fact`
6. Play `vars:` / `vars_files:`
7. Task `vars:`
8. Role `vars/main.yml`
9. `-e / --extra-vars` — **highest, beats everything**

**Practical rule:** put safe defaults in `roles/*/defaults/`, put real values in `group_vars/`, put exceptions in `host_vars/`, and use `-e` only for one-off overrides like `-e "app_version=2.3.1"`.

### 6.3 Making configs environment-aware

```yaml
- name: Load environment-specific variables
  hosts: all
  become: true
  tasks:
    - name: Include vars for this environment
      ansible.builtin.include_vars:
        file: "vars/{{ env_name }}.yml"

    - name: Include OS-specific vars, with fallback
      ansible.builtin.include_vars: "{{ item }}"
      with_first_found:
        - "vars/{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml"
        - "vars/{{ ansible_distribution }}.yml"
        - "vars/{{ ansible_os_family }}.yml"
        - "vars/default.yml"
```

**`with_first_found` explained:** try each path in order and load the **first one that exists**. So `Ubuntu-24.yml` wins if it exists; otherwise `Ubuntu.yml`; otherwise `Debian.yml`; otherwise the generic default. It's a graceful-degradation ladder that keeps you from writing a mountain of `when:` conditions.

### 6.4 Enforcing configuration (drift detection)

```yaml
- name: Audit — report config drift without fixing it
  hosts: all
  become: true
  check_mode: true          # force the whole play into dry-run
  tasks:
    - name: Would sshd_config change?
      ansible.builtin.template:
        src: sshd_config.j2
        dest: /etc/ssh/sshd_config
      register: sshd_drift
      diff: true

    - name: Flag drifted hosts
      ansible.builtin.debug:
        msg: "DRIFT DETECTED on {{ inventory_hostname }}"
      when: sshd_drift.changed
```

Run it on a schedule and you have a free compliance report: any host reporting `changed` in check mode has been hand-edited.

### 6.5 Config with a rollback safety net

```yaml
- name: Deploy config with automatic rollback
  hosts: appservers
  become: true
  serial: 1
  tasks:
    - name: Deploy and verify, roll back on failure
      block:
        - name: Write new config
          ansible.builtin.template:
            src: app.conf.j2
            dest: /etc/myapp/app.conf
            backup: true
          register: cfg_change

        - name: Restart the app
          ansible.builtin.systemd_service:
            name: myapp
            state: restarted

        - name: Health check
          ansible.builtin.uri:
            url: "http://localhost:{{ app_port }}/healthz"
            status_code: 200
          retries: 5
          delay: 3
          register: health
          until: health.status == 200

      rescue:
        - name: Restore the backup
          ansible.builtin.copy:
            src: "{{ cfg_change.backup_file }}"
            dest: /etc/myapp/app.conf
            remote_src: true
          when: cfg_change.backup_file is defined

        - name: Restart with the old config
          ansible.builtin.systemd_service:
            name: myapp
            state: restarted

        - name: Make the failure loud
          ansible.builtin.fail:
            msg: "Deploy failed on {{ inventory_hostname }} — config rolled back."

      always:
        - name: Log the outcome either way
          ansible.builtin.lineinfile:
            path: /var/log/deploy-history.log
            line: "{{ ansible_date_time.iso8601 }} deploy result recorded"
            create: true
            mode: "0644"
```

**Block / rescue / always in plain words:** `block` is "try this." `rescue` is "if anything above blew up, do this instead." `always` is "do this no matter what happened." Same idea as try/catch/finally in a programming class. `serial: 1` means one server at a time, so a bad config can only ever take down one node before the play stops.

### 6.6 Best practices — configuration management

- ✅ **One source of truth.** If Ansible manages a file, *nobody* hand-edits it. Say so in the file header.
- ✅ **Structure your variables**: defaults → group_vars → host_vars. Never hardcode an IP in a task.
- ✅ **Namespace your variables** by role: `nginx_port`, not `port`. Prevents collisions.
- ✅ **Validate everything.** `nginx -t`, `sshd -t`, `visudo -cf`, `systemd-analyze verify`, `named-checkconf`.
- ✅ **Run the same playbook in every environment**, changing only variables. That's how dev actually predicts prod.
- ✅ Keep `serial:` small for risky changes.
- ❌ Don't mix "configure" and "deploy app code" in one playbook — different risk levels, different cadences.
- ❌ Don't disable `host_key_checking` to make errors go away.

---

<a name="7-users-and-access"></a>
## 7. Detailed Examples: Users, Groups, SSH, and Sudo

### 7.1 Creating users properly

```yaml
- name: Manage admin users
  hosts: all
  become: true

  vars:
    admin_users:
      - name: alice
        comment: "Alice Chen - Platform Team"
        groups: [wheel, docker]
        shell: /bin/bash
        uid: 3001
        keys:
          - "ssh-ed25519 AAAAC3Nza... alice@laptop"
      - name: bob
        comment: "Bob Ray - DBA"
        groups: [dba]
        shell: /bin/bash
        uid: 3002
        keys:
          - "ssh-ed25519 AAAAC3Nza... bob@workstation"

    removed_users: [oldcontractor, tempintern]

  tasks:
    - name: Ensure required groups exist
      ansible.builtin.group:
        name: "{{ item }}"
        state: present
      loop: [wheel, docker, dba]

    - name: Create admin accounts
      ansible.builtin.user:
        name: "{{ item.name }}"
        comment: "{{ item.comment }}"
        uid: "{{ item.uid | default(omit) }}"
        groups: "{{ item.groups | join(',') }}"
        append: true               # ADD groups, don't replace existing ones
        shell: "{{ item.shell | default('/bin/bash') }}"
        create_home: true
        state: present
      loop: "{{ admin_users }}"
      loop_control:
        label: "{{ item.name }}"

    - name: Install their SSH public keys
      ansible.posix.authorized_key:
        user: "{{ item.0.name }}"
        key: "{{ item.1 }}"
        state: present
        exclusive: false          # true = wipe any key not listed here
        manage_dir: true
      loop: "{{ admin_users | subelements('keys') }}"
      loop_control:
        label: "{{ item.0.name }}"

    - name: Grant passwordless sudo to the wheel group
      community.general.sudoers:
        name: wheel-nopasswd
        group: wheel
        commands: ALL
        nopassword: true
        state: present
        validation: required       # runs visudo -cf; refuses to write a broken file

    - name: Lock and expire departed users
      ansible.builtin.user:
        name: "{{ item }}"
        state: present
        password_lock: true
        expires: 1                 # epoch seconds; any past date disables the account
        shell: /sbin/nologin
      loop: "{{ removed_users }}"
      ignore_errors: true          # they may not exist on every host
```

**`append: true` is critical.** Without it, `groups: [docker]` **replaces** all of the user's supplementary groups — so a user in `wheel` and `docker` who you re-run with just `docker` silently loses sudo. Almost always set `append: true`.

**`subelements` explained:** `admin_users` is a list where each item has a *nested list* of keys. `subelements('keys')` flattens that into pairs. Each `item` becomes a two-element list: `item.0` is the user dict, `item.1` is one key string. So the loop runs once per key per user.

**`default(omit)` explained:** `omit` is a special Ansible value meaning "pretend I never passed this parameter." So if a user has no `uid` defined, Ansible lets the system pick one instead of erroring or passing an empty string.

**Locking vs deleting:** in most companies you **lock and expire** departing users rather than deleting them, so their files keep a valid owner and audit logs stay meaningful. `password_lock` disables password login, `shell: /sbin/nologin` blocks interactive shells, and `expires` in the past disables the account entirely. To fully delete: `state: absent` with `remove: true` (which also deletes the home directory — think first).

### 7.2 Passwords the right way

```yaml
- name: Set a hashed password (NEVER put a plaintext password here)
  ansible.builtin.user:
    name: svcaccount
    password: "{{ svc_password | password_hash('sha512', 65534 | random(seed=inventory_hostname) | string) }}"
    update_password: on_create    # don't reset it on every run
  no_log: true
```

**Every part of that matters:**
- `password_hash('sha512', salt)` turns plaintext into the `$6$...` crypt hash that `/etc/shadow` expects. Ansible will **not** hash it for you — passing plaintext stores a literally unusable (and unsafe) value.
- The **salt** must be stable per host, or the hash changes every run and the task reports `changed` forever. Seeding `random` with `inventory_hostname` makes it deterministic.
- `update_password: on_create` means "only set this when the account is first made," so admins can change it later without Ansible fighting them.
- `no_log: true` keeps the secret out of your terminal, your CI logs, and your callback plugins. **Non-negotiable.**
- `svc_password` itself should live in an **Ansible Vault** file (see §16).

### 7.3 SSH key management

```yaml
- name: Add a key from a local file
  ansible.posix.authorized_key:
    user: deploy
    key: "{{ lookup('ansible.builtin.file', 'files/keys/deploy.pub') }}"
    state: present

- name: Fetch a key straight from GitHub
  ansible.posix.authorized_key:
    user: alice
    key: https://github.com/alicehandle.keys

- name: Restrict what a key can do (great for backup/automation keys)
  ansible.posix.authorized_key:
    user: backup
    key: "{{ backup_pubkey }}"
    key_options: 'no-port-forwarding,no-agent-forwarding,no-pty,command="/usr/local/bin/backup-only.sh",from="10.0.5.0/24"'

- name: Enforce an exact key list (removes anything not listed)
  ansible.posix.authorized_key:
    user: deploy
    key: "{{ approved_deploy_keys | join('\n') }}"
    exclusive: true

- name: Generate a key pair on the host
  ansible.builtin.user:
    name: appuser
    generate_ssh_key: true
    ssh_key_type: ed25519
    ssh_key_bits: 521
    ssh_key_file: .ssh/id_ed25519
    ssh_key_comment: "appuser@{{ inventory_hostname }}"
```

**`key_options` explained:** these are restrictions SSH enforces on that specific key. `command="..."` forces the key to run only that one script no matter what the client asks for. `from="10.0.5.0/24"` limits which network can use it. This turns a general-purpose key into a single-purpose one — a huge security win for automation accounts.

**`exclusive: true` is powerful and sharp.** It guarantees the file contains exactly the keys you listed — perfect for offboarding. It will also cheerfully delete a key someone added manually for a legitimate reason. Use it deliberately.

### 7.4 Best practices — access

- ✅ Manage users from a **variable list**, ideally per group, so onboarding is a one-line pull request.
- ✅ Prefer **SSH keys over passwords**, everywhere.
- ✅ Use `community.general.sudoers` with `validation: required` instead of editing `/etc/sudoers` directly. A broken sudoers file can lock everyone out of root permanently.
- ✅ Write sudo rules to `/etc/sudoers.d/*`, never into the main file.
- ✅ `no_log: true` on every task that touches a credential.
- ✅ Keep an explicit "removed users" list so offboarding is enforced, not remembered.
- ❌ Never commit plaintext passwords, private keys, or API tokens. Vault them.
- ❌ Don't grant blanket `NOPASSWD: ALL` to humans unless your threat model allows it; scope commands where you can.

---

<a name="8-logs"></a>
## 8. Detailed Examples: Logs and Log Management

Logs are how you find out what happened. Ansible helps in four ways: **rotating** them, **shipping** them, **reading** them, and **collecting** them for analysis.

### 8.1 Log rotation with logrotate

```yaml
- name: Configure log rotation for our app
  hosts: appservers
  become: true

  tasks:
    - name: Ensure logrotate is installed
      ansible.builtin.package:
        name: logrotate
        state: present

    - name: Create the log directory
      ansible.builtin.file:
        path: /var/log/myapp
        state: directory
        owner: appuser
        group: adm
        mode: "0750"

    - name: Write the logrotate rule
      ansible.builtin.template:
        src: logrotate-myapp.j2
        dest: /etc/logrotate.d/myapp
        owner: root
        group: root
        mode: "0644"
        validate: "logrotate -d %s"     # -d = debug/dry-run, catches syntax errors

    - name: Verify the rule parses and show what it would do
      ansible.builtin.command:
        cmd: logrotate -d /etc/logrotate.d/myapp
      register: lr_check
      changed_when: false
      failed_when: lr_check.rc != 0
```

`templates/logrotate-myapp.j2`:

```jinja
# {{ ansible_managed }}
/var/log/myapp/*.log {
    {{ logrotate_frequency | default('daily') }}
    rotate {{ log_retention_days | default(14) }}
    size {{ logrotate_size | default('100M') }}
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    dateext
    dateformat -%Y%m%d
    create 0640 appuser adm
    sharedscripts
    postrotate
        systemctl reload myapp >/dev/null 2>&1 || true
    endscript
}
```

**Every logrotate keyword, in plain words:**
- `daily` / `weekly` / `monthly` — how often to consider rotating.
- `rotate 14` — keep 14 old copies, then delete the oldest.
- `size 100M` — also rotate if the file gets this big, regardless of schedule.
- `missingok` — don't complain if the log doesn't exist yet.
- `notifempty` — don't rotate an empty file (avoids a pile of 0-byte archives).
- `compress` — gzip the old ones to save disk.
- `delaycompress` — wait one cycle before compressing, so a process still writing to the just-rotated file doesn't write into a gzip.
- `copytruncate` — copy the file then empty the original in place, instead of renaming it. **Use this when the app holds the file open and can't be told to reopen it.** Slight risk of losing a few lines written during the copy.
- `create 0640 appuser adm` — make the fresh log file with these permissions/owner.
- `sharedscripts` — run `postrotate` once for the whole group, not once per matched file.
- `postrotate ... endscript` — commands to run after rotation (usually telling the daemon to reopen its log).

**`copytruncate` vs `postrotate` reload — the trade-off:** `copytruncate` is simpler and needs no cooperation from the app, but can lose a handful of log lines. A `postrotate` signal/reload loses nothing but requires the app to support reopening its log file. Prefer the reload when the app supports it.

### 8.2 systemd-journald configuration

```yaml
- name: Tune journald so logs survive reboots and don't eat the disk
  hosts: all
  become: true
  tasks:
    - name: Create persistent journal directory
      ansible.builtin.file:
        path: /var/log/journal
        state: directory
        owner: root
        group: systemd-journal
        mode: "2755"          # the leading 2 = setgid, so new files inherit the group

    - name: Configure journald limits
      ansible.builtin.template:
        src: journald.conf.j2
        dest: /etc/systemd/journald.conf.d/99-custom.conf
        mode: "0644"
      notify: Restart journald

    - name: Vacuum old journal data now
      ansible.builtin.command:
        cmd: journalctl --vacuum-time={{ journal_max_age | default('30d') }}
      register: vac
      changed_when: "'Vacuuming done' in vac.stderr or 'Deleted' in vac.stderr"

  handlers:
    - name: Restart journald
      ansible.builtin.systemd_service:
        name: systemd-journald
        state: restarted
```

`templates/journald.conf.j2`:

```jinja
# {{ ansible_managed }}
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse={{ journal_max_use | default('2G') }}
SystemMaxFileSize={{ journal_max_file | default('128M') }}
MaxRetentionSec={{ journal_max_age | default('30d') }}
RateLimitIntervalSec=30s
RateLimitBurst=10000
ForwardToSyslog={{ journal_forward_syslog | default('no') }}
```

**Why `Storage=persistent` matters:** by default many distros keep the journal in `/run/log/journal`, which is **RAM**. Every reboot wipes it. If a server crashes, the logs explaining why vanish with it. Persistent storage writes to `/var/log/journal` on disk. `SystemMaxUse` then caps how much disk it can consume so logs can't fill the root filesystem.

### 8.3 Central log shipping with rsyslog

```yaml
- name: Ship logs to a central collector
  hosts: all
  become: true
  vars:
    log_server: logs.example.com
    log_port: 6514
  tasks:
    - name: Install rsyslog
      ansible.builtin.package:
        name: rsyslog
        state: present

    - name: Configure forwarding
      ansible.builtin.copy:
        dest: /etc/rsyslog.d/60-forward.conf
        mode: "0644"
        content: |
          # {{ ansible_managed }}
          # Queue to disk so nothing is lost if the collector is down
          $ActionQueueType LinkedList
          $ActionQueueFileName fwdRule1
          $ActionQueueMaxDiskSpace 1g
          $ActionQueueSaveOnShutdown on
          $ActionResumeRetryCount -1
          # TLS-encrypted forwarding over TCP (@@ means TCP, @ means UDP)
          *.* @@{{ log_server }}:{{ log_port }}
        validate: "rsyslogd -N1 -f %s"
      notify: Restart rsyslog

    - name: Open the outbound port
      ansible.posix.firewalld:
        port: "{{ log_port }}/tcp"
        permanent: true
        immediate: true
        state: enabled
      when: ansible_os_family == 'RedHat'

  handlers:
    - name: Restart rsyslog
      ansible.builtin.systemd_service:
        name: rsyslog
        state: restarted
```

**Disk queueing explained:** without a queue, if the log server is unreachable, messages are simply dropped — exactly when you most want them (during an outage). `ActionQueueType LinkedList` plus `MaxDiskSpace` tells rsyslog to buffer to disk and replay when the collector returns.

### 8.4 Reading and searching logs across many servers

```yaml
- name: Hunt for errors across the fleet
  hosts: all
  become: true
  gather_facts: true

  tasks:
    - name: Search journald for errors in the last hour
      ansible.builtin.command:
        cmd: journalctl --since "1 hour ago" --priority=err --no-pager --output=short-iso
      register: recent_errors
      changed_when: false          # reading is never a change
      failed_when: false           # empty results are fine, not a failure

    - name: Show hosts that have errors
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }}: {{ recent_errors.stdout_lines | length }} error lines"
      when: recent_errors.stdout_lines | length > 0

    - name: Count failed SSH logins today
      ansible.builtin.shell:
        cmd: "journalctl -u sshd --since today --no-pager | grep -c 'Failed password' || true"
      register: failed_ssh
      changed_when: false

    - name: Warn on brute-force-looking activity
      ansible.builtin.debug:
        msg: "⚠ {{ inventory_hostname }} has {{ failed_ssh.stdout | trim }} failed SSH logins today"
      when: (failed_ssh.stdout | trim | int) > 50

    - name: Grep an application log file
      ansible.builtin.shell:
        cmd: "grep -i 'exception' /var/log/myapp/app.log | tail -50"
      register: app_errors
      changed_when: false
      failed_when: false

    - name: Check for disk-full messages in dmesg
      ansible.builtin.command:
        cmd: dmesg --level=err,crit,alert,emerg --time-format=iso
      register: dmesg_out
      changed_when: false
      failed_when: false
```

**`changed_when: false` on every read-only task** — this is a hallmark of a professional playbook. `command` and `shell` have no way to know whether they changed anything, so Ansible pessimistically reports `changed` every time. Telling it the truth keeps your run summary meaningful: if `changed` is non-zero, something real actually happened.

**`|| true` in the shell command:** `grep` exits with code 1 when it finds nothing. Ansible sees a non-zero exit and calls it a failure. `|| true` forces exit 0 so "no matches" is treated as a normal result rather than an error.

### 8.5 Collecting logs to the control node for analysis

```yaml
- name: Gather diagnostic bundles from all servers
  hosts: all
  become: true
  vars:
    bundle_dir: "/tmp/diag-{{ ansible_date_time.epoch }}"
    local_dir: "./logbundles/{{ ansible_date_time.date }}"

  tasks:
    - name: Create a staging directory on the target
      ansible.builtin.file:
        path: "{{ bundle_dir }}"
        state: directory
        mode: "0700"

    - name: Dump the last 24h of journal
      ansible.builtin.shell:
        cmd: "journalctl --since '24 hours ago' --no-pager > {{ bundle_dir }}/journal.log"
      changed_when: true

    - name: Copy key log files into the bundle
      ansible.builtin.shell:
        cmd: "cp -a {{ item }} {{ bundle_dir }}/ 2>/dev/null || true"
      loop:
        - /var/log/messages
        - /var/log/syslog
        - /var/log/secure
        - /var/log/auth.log
        - /var/log/myapp/app.log
      changed_when: true

    - name: Compress the bundle
      community.general.archive:
        path: "{{ bundle_dir }}"
        dest: "{{ bundle_dir }}.tar.gz"
        format: gz

    - name: Pull it back to the control node
      ansible.builtin.fetch:
        src: "{{ bundle_dir }}.tar.gz"
        dest: "{{ local_dir }}/{{ inventory_hostname }}.tar.gz"
        flat: true

    - name: Clean up the target
      ansible.builtin.file:
        path: "{{ item }}"
        state: absent
      loop:
        - "{{ bundle_dir }}"
        - "{{ bundle_dir }}.tar.gz"
```

### 8.6 Disk-space guard: clean logs before they fill the disk

```yaml
- name: Emergency log cleanup when disk is tight
  hosts: all
  become: true
  tasks:
    - name: Look at the root filesystem
      ansible.builtin.set_fact:
        root_pct_free: >-
          {{ (ansible_mounts | selectattr('mount','equalto','/') | first).size_available
             / (ansible_mounts | selectattr('mount','equalto','/') | first).size_total }}

    - name: Find logs older than 7 days when disk is over 85% full
      ansible.builtin.find:
        paths: [/var/log]
        patterns: ["*.log.*", "*.gz", "*.old", "*.1"]
        age: 7d
        recurse: true
      register: purgeable
      when: (root_pct_free | float) < 0.15

    - name: Delete them
      ansible.builtin.file:
        path: "{{ item.path }}"
        state: absent
      loop: "{{ purgeable.files | default([]) }}"
      loop_control:
        label: "{{ item.path }}"

    - name: Vacuum the journal down to 500M
      ansible.builtin.command:
        cmd: journalctl --vacuum-size=500M
      when: (root_pct_free | float) < 0.15
      changed_when: true

    - name: Truncate (don't delete) an actively-written log
      ansible.builtin.command:
        cmd: "truncate -s 0 /var/log/myapp/app.log"
      when: (root_pct_free | float) < 0.05
      changed_when: true
```

**Truncate vs delete for open files:** if a process has a log file open and you `rm` it, the disk space is **not** freed until that process restarts — the file lives on as an unlinked inode. `truncate -s 0` empties it in place while keeping the same inode, so space is freed immediately and the app keeps writing happily. This trips up admins constantly during disk-full emergencies.

### 8.7 Auditd for security logging

```yaml
- name: Configure the audit daemon
  hosts: all
  become: true
  tasks:
    - name: Install auditd
      ansible.builtin.package:
        name: audit
        state: present

    - name: Deploy audit rules
      ansible.builtin.copy:
        dest: /etc/audit/rules.d/99-hardening.rules
        mode: "0640"
        content: |
          # {{ ansible_managed }}
          -w /etc/passwd -p wa -k identity
          -w /etc/shadow -p wa -k identity
          -w /etc/sudoers -p wa -k privilege
          -w /etc/sudoers.d/ -p wa -k privilege
          -w /var/log/audit/ -p wa -k auditlog
          -a always,exit -F arch=b64 -S execve -F euid=0 -k rootcmd
      notify: Reload audit rules

  handlers:
    - name: Reload audit rules
      ansible.builtin.command:
        cmd: augenrules --load
```

**Rule syntax quickly:** `-w PATH` = watch this path, `-p wa` = alert on **w**rite and **a**ttribute changes, `-k NAME` = tag it with a key so you can search later with `ausearch -k identity`.

### 8.8 Best practices — logs

- ✅ Rotate **before** you have a problem. Unrotated logs are the #1 cause of full root filesystems.
- ✅ Make journald persistent and capped.
- ✅ Ship logs off the box. A compromised or dead server takes its local logs with it.
- ✅ Always `changed_when: false` on log-reading tasks.
- ✅ Use `--no-pager` with journalctl — otherwise it can hang waiting for a terminal.
- ✅ Set `create 0640 owner adm` in logrotate so rotated logs keep correct permissions.
- ⚠️ Be careful with `copytruncate` on high-volume logs; a few lines can be lost.
- ❌ Don't `rm` an actively-written log expecting space back — truncate it.
- ❌ Don't ship secrets in logs; scrub before forwarding.

### 8.9 Pros and cons — log approaches

| Approach | Pros | Cons |
|---|---|---|
| logrotate | Universal, mature, simple config | Cron-driven, so rotation isn't instant; `copytruncate` can lose lines |
| journald limits | Built into systemd, structured/queryable, no extra tooling | Binary format; awkward for old tools; not on non-systemd hosts |
| rsyslog forwarding | Central search, survives host loss, disk-queue reliability | Extra infrastructure; TLS setup effort; network dependency |
| Ad-hoc `journalctl` via Ansible | Zero infra, instant, works today | Doesn't scale past a few dozen hosts; no history or correlation |
| `fetch` bundles | Great for deep post-incident forensics | Manual, bulky, slow; only a point-in-time snapshot |

---

<a name="9-scheduled-jobs"></a>
## 9. Detailed Examples: Scheduled Jobs (cron & systemd timers)

### 9.1 Cron jobs

```yaml
- name: Manage scheduled jobs
  hosts: all
  become: true
  tasks:
    - name: Nightly backup at 2:30 AM
      ansible.builtin.cron:
        name: "nightly database backup"     # the unique ID — never change it casually
        minute: "30"
        hour: "2"
        day: "*"
        month: "*"
        weekday: "*"
        user: root
        job: "/usr/local/bin/backup.sh >> /var/log/backup.log 2>&1"
        state: present

    - name: Every 15 minutes
      ansible.builtin.cron:
        name: "metrics collection"
        minute: "*/15"
        user: monitoring
        job: "/usr/local/bin/collect-metrics.sh"

    - name: Weekly, Sundays at 4 AM
      ansible.builtin.cron:
        name: "weekly log cleanup"
        minute: "0"
        hour: "4"
        weekday: "0"                 # 0 or 7 = Sunday
        job: "/usr/local/bin/cleanup-logs.sh"

    - name: Run at boot
      ansible.builtin.cron:
        name: "warm the cache at boot"
        special_time: reboot         # reboot|yearly|annually|monthly|weekly|daily|hourly
        job: "/usr/local/bin/warm-cache.sh"

    - name: Write to /etc/cron.d instead of a user crontab
      ansible.builtin.cron:
        name: "fleet health check"
        cron_file: fleet-health       # creates /etc/cron.d/fleet-health
        user: root
        minute: "*/5"
        job: "/usr/local/bin/healthcheck.sh"

    - name: Set environment variables for cron
      ansible.builtin.cron:
        name: PATH
        env: true
        job: /usr/local/bin:/usr/bin:/bin

    - name: Remove an old job
      ansible.builtin.cron:
        name: "obsolete nightly rsync"
        state: absent
```

**How Ansible keeps cron idempotent:** it writes a comment line above each job, `#Ansible: nightly database backup`. On the next run it finds that comment and updates the line beneath it. **This means `name:` is the primary key.** Change the name and you get a *second* job instead of an edited one — a classic way to accidentally run backups twice.

**Cron time fields, left to right:** minute (0–59), hour (0–23), day of month (1–31), month (1–12), day of week (0–7, where 0 and 7 both mean Sunday).
- `*` = every
- `*/15` = every 15
- `1,15` = the 1st and 15th
- `9-17` = the range 9 through 17

**Why redirect output:** cron emails any output to the user, which usually means it silently piles up in a spool nobody reads. `>> /var/log/backup.log 2>&1` sends both normal output (stdout) and errors (stderr) to a file you can actually find.

**`cron_file` vs user crontab:** files in `/etc/cron.d/` are plain text you can inspect, back up, and diff — and they carry a user field. User crontabs live in a spool directory and are easy to forget. For managed infrastructure, prefer `cron_file`.

### 9.2 systemd timers (the modern replacement)

```yaml
- name: Replace a cron job with a systemd timer
  hosts: all
  become: true
  tasks:
    - name: Service unit (what to run)
      ansible.builtin.copy:
        dest: /etc/systemd/system/backup.service
        mode: "0644"
        content: |
          # {{ ansible_managed }}
          [Unit]
          Description=Nightly backup
          After=network-online.target

          [Service]
          Type=oneshot
          User=root
          ExecStart=/usr/local/bin/backup.sh
          Nice=10
          IOSchedulingClass=idle
      notify: Reload systemd

    - name: Timer unit (when to run it)
      ansible.builtin.copy:
        dest: /etc/systemd/system/backup.timer
        mode: "0644"
        content: |
          # {{ ansible_managed }}
          [Unit]
          Description=Run nightly backup

          [Timer]
          OnCalendar=*-*-* 02:30:00
          RandomizedDelaySec=900
          Persistent=true

          [Install]
          WantedBy=timers.target
      notify: Reload systemd

    - name: Enable the timer
      ansible.builtin.systemd_service:
        name: backup.timer
        enabled: true
        state: started
        daemon_reload: true

  handlers:
    - name: Reload systemd
      ansible.builtin.systemd_service:
        daemon_reload: true
```

**Why timers beat cron:**
- `Persistent=true` — if the machine was off at 2:30 AM, run the job as soon as it boots. Cron just skips it forever.
- `RandomizedDelaySec=900` — spread 300 servers randomly over 15 minutes instead of hammering your backup server all at 2:30:00 exactly. This is called **jitter** and it prevents "thundering herd" outages.
- Output goes to the journal automatically — no redirect needed.
- Full systemd features: resource limits, dependencies, sandboxing, `Nice`, and `IOSchedulingClass=idle` so backups don't starve your database of disk I/O.
- `systemctl list-timers` shows you the next run time for everything at a glance.

### 9.3 Pros and cons — cron vs timers

| | Pros | Cons |
|---|---|---|
| **cron** | On every Unix; one-line syntax everyone knows; trivial to write | No catch-up after downtime; no jitter; output handling is manual; hard to see status |
| **systemd timer** | Catch-up, jitter, journal logging, dependencies, sandboxing, easy status | Two files per job; systemd only; more verbose; syntax is less familiar |

---

<a name="10-disks"></a>
## 10. Detailed Examples: Disks, Filesystems, and Mounts

### 10.1 Partition → filesystem → mount, the whole chain

```yaml
- name: Prepare a new data disk end to end
  hosts: dbservers
  become: true
  vars:
    data_disk: /dev/sdb
    data_mount: /data

  tasks:
    - name: Confirm the disk actually exists on this host
      ansible.builtin.assert:
        that: data_disk | basename in ansible_devices
        fail_msg: "{{ data_disk }} is not present on {{ inventory_hostname }}"

    - name: Create a single GPT partition using the whole disk
      community.general.parted:
        device: "{{ data_disk }}"
        number: 1
        state: present
        label: gpt
        part_start: 0%
        part_end: 100%

    - name: Make an XFS filesystem
      community.general.filesystem:
        fstype: xfs
        dev: "{{ data_disk }}1"
        opts: "-L DATA"
        force: false          # NEVER set true unless you truly mean "erase this disk"

    - name: Create the mount point
      ansible.builtin.file:
        path: "{{ data_mount }}"
        state: directory
        mode: "0755"

    - name: Mount it and add it to /etc/fstab
      ansible.posix.mount:
        path: "{{ data_mount }}"
        src: LABEL=DATA
        fstype: xfs
        opts: defaults,noatime,nodev,nosuid
        state: mounted
        dump: 0
        passno: 2

    - name: Verify it's mounted and has space
      ansible.builtin.assert:
        that:
          - ansible_mounts | selectattr('mount','equalto',data_mount) | list | length > 0
        fail_msg: "{{ data_mount }} did not mount"
```

**Mount `state:` values, precisely:**
- `present` — write the fstab entry only; **don't** mount now.
- `mounted` — write fstab **and** mount it now. This is what you almost always want.
- `unmounted` — unmount now, leave fstab alone.
- `absent` — unmount **and** remove from fstab.
- `remounted` — apply new options without a full unmount.

**Why `LABEL=DATA` instead of `/dev/sdb1`:** device names are assigned in discovery order and can change when you add hardware or reboot a cloud VM. Your `/dev/sdb` can silently become `/dev/sdc`, and then fstab mounts the wrong disk — or fails to boot. Labels and UUIDs stick to the filesystem itself. **Always use LABEL or UUID in fstab.**

**Mount options decoded:** `noatime` stops the kernel writing an access timestamp on every single read (a real performance win). `nodev` means "no device files here," `nosuid` means "ignore setuid bits" — both block classic privilege-escalation tricks on data partitions. `passno: 2` means fsck checks this after the root filesystem; root uses 1, and 0 means never check.

**`force: false` on `filesystem`:** with `force: true`, the module will happily reformat a disk that already has data on it. There is no undo. Leave it false.

### 10.2 LVM

```yaml
- name: Set up LVM storage
  hosts: dbservers
  become: true
  tasks:
    - name: Create a volume group across two disks
      community.general.lvg:
        vg: vg_data
        pvs: /dev/sdb,/dev/sdc
        state: present

    - name: Create a logical volume using 80% of the group
      community.general.lvol:
        vg: vg_data
        lv: lv_postgres
        size: 80%VG
        state: present

    - name: Make the filesystem
      community.general.filesystem:
        fstype: xfs
        dev: /dev/vg_data/lv_postgres

    - name: Mount it
      ansible.posix.mount:
        path: /var/lib/pgsql
        src: /dev/vg_data/lv_postgres
        fstype: xfs
        opts: defaults,noatime
        state: mounted

    - name: Grow the volume AND the filesystem online
      community.general.lvol:
        vg: vg_data
        lv: lv_postgres
        size: +20G
        resizefs: true       # extends the filesystem too — XFS/ext4 grow while mounted
```

**Why LVM is worth the extra layer:** without it, growing a full partition means a maintenance window, a backup, and a risky resize. With LVM you add a disk, extend the volume group, and grow the logical volume and filesystem **while the database keeps running**. That capability alone justifies it on any server with unpredictable data growth. The cost is one more abstraction to understand during recovery.

### 10.3 Disk space monitoring

```yaml
- name: Report filesystems over 80% full
  hosts: all
  gather_facts: true
  tasks:
    - name: Keep only real, non-empty filesystems
      ansible.builtin.set_fact:
        real_mounts: >-
          {{ ansible_mounts
             | selectattr('size_total', 'gt', 0)
             | rejectattr('fstype', 'in', ['tmpfs','devtmpfs','squashfs','overlay'])
             | list }}

    - name: Show usage per mount
      ansible.builtin.debug:
        msg: >-
          {{ item.mount }} is {{ (100 - (item.size_available / item.size_total * 100)) | round(1) }}% full
          ({{ (item.size_available / 1024 / 1024 / 1024) | round(1) }} GB free)
      loop: "{{ real_mounts }}"
      loop_control:
        label: "{{ item.mount }}"
      when: (item.size_available / item.size_total) < 0.20

    - name: Fail the run if anything is critically full
      ansible.builtin.assert:
        that:
          - (item.size_available / item.size_total) > 0.05
        fail_msg: "CRITICAL: {{ item.mount }} on {{ inventory_hostname }} is over 95% full"
      loop: "{{ real_mounts }}"
      loop_control:
        label: "{{ item.mount }}"
```

**The math, slowly:** `size_available / size_total` gives the fraction that's **free**. If it's less than `0.20`, the disk is more than 80% used. Multiplying by 100 and subtracting from 100 flips it to a "percent used" number for humans. We exclude `tmpfs` and friends because those are RAM-backed pseudo-filesystems and their "fullness" is meaningless noise.

---

<a name="11-network-firewall-selinux"></a>
## 11. Detailed Examples: Networking, Firewall, and SELinux

### 11.1 firewalld (RHEL family)

```yaml
- name: Configure firewalld
  hosts: webservers
  become: true
  tasks:
    - name: Install and start firewalld
      ansible.builtin.package:
        name: firewalld
        state: present

    - name: Enable it
      ansible.builtin.systemd_service:
        name: firewalld
        state: started
        enabled: true

    - name: Allow standard services
      ansible.posix.firewalld:
        service: "{{ item }}"
        permanent: true
        immediate: true
        state: enabled
      loop: [ssh, http, https]

    - name: Allow a custom port
      ansible.posix.firewalld:
        port: "{{ app_port }}/tcp"
        permanent: true
        immediate: true
        state: enabled

    - name: Allow the monitoring subnet to reach a port
      ansible.posix.firewalld:
        rich_rule: 'rule family="ipv4" source address="10.0.5.0/24" port port="9100" protocol="tcp" accept'
        permanent: true
        immediate: true
        state: enabled

    - name: Put an interface in the internal zone
      ansible.posix.firewalld:
        zone: internal
        interface: eth1
        permanent: true
        immediate: true
        state: enabled

    - name: Set the default zone
      ansible.builtin.command:
        cmd: firewall-cmd --set-default-zone=public
      register: dz
      changed_when: "'success' in dz.stdout"
```

**`permanent` vs `immediate` — a very common mistake:**
- `permanent: true` writes the rule to disk so it survives a reboot, but **does not apply it right now**.
- `immediate: true` applies it to the running firewall, but **is lost on reboot**.
- You almost always want **both**. Setting only `permanent` is why "I added the rule but the port is still closed."

### 11.2 UFW (Ubuntu)

```yaml
- name: Configure UFW
  hosts: webservers
  become: true
  tasks:
    - name: Install ufw
      ansible.builtin.apt:
        name: ufw
        state: present

    - name: Default deny incoming, allow outgoing
      community.general.ufw:
        direction: "{{ item.dir }}"
        policy: "{{ item.pol }}"
      loop:
        - { dir: incoming, pol: deny }
        - { dir: outgoing, pol: allow }

    - name: Allow SSH FIRST (before enabling — or you lock yourself out)
      community.general.ufw:
        rule: allow
        name: OpenSSH

    - name: Allow web ports with rate limiting on SSH
      community.general.ufw:
        rule: "{{ item.rule }}"
        port: "{{ item.port }}"
        proto: tcp
      loop:
        - { rule: allow, port: '80' }
        - { rule: allow, port: '443' }
        - { rule: limit, port: '22' }

    - name: Allow a specific source network
      community.general.ufw:
        rule: allow
        src: 10.0.5.0/24
        port: '9100'
        proto: tcp

    - name: Enable the firewall
      community.general.ufw:
        state: enabled
```

**`rule: limit` explained:** UFW's rate limiting blocks an IP that opens more than 6 connections to that port in 30 seconds. It's a cheap, built-in defense against SSH brute-force attempts.

**⚠ Order is life-or-death here.** If you enable a default-deny firewall *before* allowing SSH, Ansible's own connection dies mid-play and you need console access to recover. Always allow your management port first.

### 11.3 SELinux

```yaml
- name: Manage SELinux
  hosts: all
  become: true
  when: ansible_os_family == 'RedHat'
  tasks:
    - name: Set SELinux to enforcing
      ansible.posix.selinux:
        policy: targeted
        state: enforcing
      register: se

    - name: Let Apache make outbound network connections
      ansible.posix.seboolean:
        name: httpd_can_network_connect
        state: true
        persistent: true

    - name: Label a custom web directory correctly
      community.general.sefcontext:
        target: '/srv/www(/.*)?'
        setype: httpd_sys_content_t
        state: present
      register: sefc

    - name: Apply the new labels
      ansible.builtin.command:
        cmd: restorecon -Rv /srv/www
      when: sefc.changed

    - name: Allow a non-standard port for httpd
      community.general.seport:
        ports: "8443"
        proto: tcp
        setype: http_port_t
        state: present

    - name: Reboot if the SELinux mode change requires it
      ansible.builtin.reboot:
        reboot_timeout: 600
      when: se.reboot_required | default(false)
```

**Please don't just disable SELinux.** Nearly every "fix" you find online says `setenforce 0`. That's like removing your car's airbags because the light was on. The three things that solve 95% of real SELinux problems are: set the right **file context** (`sefcontext` + `restorecon`), flip the right **boolean** (`seboolean`), and register a **non-standard port** (`seport`). Use `ausearch -m avc -ts recent` to see exactly what was denied and why.

### 11.4 Network configuration and sysctl

```yaml
- name: Network and kernel tuning
  hosts: all
  become: true
  tasks:
    - name: Set the hostname
      ansible.builtin.hostname:
        name: "{{ inventory_hostname_short }}"
        use: systemd

    - name: Ensure hostname resolves locally
      ansible.builtin.lineinfile:
        path: /etc/hosts
        regexp: '^127\.0\.1\.1'
        line: "127.0.1.1 {{ inventory_hostname }} {{ inventory_hostname_short }}"

    - name: Configure a static IP with NetworkManager
      community.general.nmcli:
        conn_name: eth0
        ifname: eth0
        type: ethernet
        ip4: "{{ static_ip }}/24"
        gw4: "{{ gateway_ip }}"
        dns4: [1.1.1.1, 8.8.8.8]
        state: present
        autoconnect: true

    - name: Apply kernel network tuning
      ansible.posix.sysctl:
        name: "{{ item.key }}"
        value: "{{ item.value }}"
        state: present
        sysctl_file: /etc/sysctl.d/99-tuning.conf
        reload: true
      loop: "{{ sysctl_settings | dict2items }}"
      vars:
        sysctl_settings:
          net.ipv4.tcp_syncookies: 1
          net.ipv4.conf.all.rp_filter: 1
          net.ipv4.conf.all.accept_redirects: 0
          net.ipv4.ip_local_port_range: "10000 65535"
          net.core.somaxconn: 4096
          vm.swappiness: 10
          fs.file-max: 2097152
```

**`dict2items` explained:** `sysctl_settings` is a dictionary. `dict2items` converts it into a list of `{key: ..., value: ...}` pairs so `loop` can walk it. It's the standard way to loop over a dictionary in Ansible.

**`vm.swappiness: 10` in plain words:** swappiness controls how eagerly Linux moves memory to disk. The default (60) is tuned for desktops. On a database server, swapping is catastrophic for latency, so you turn it way down.

---

<a name="12-patching-and-reboots"></a>
## 12. Detailed Examples: Patching, Reboots, and Rolling Updates

### 12.1 A safe, complete patching playbook

```yaml
---
- name: Patch servers safely, a few at a time
  hosts: all
  become: true
  serial: "25%"                  # 25% of the fleet per batch
  max_fail_percentage: 10        # abort everything if >10% of a batch fails

  vars:
    reboot_if_needed: true

  pre_tasks:
    - name: Record pre-patch package state
      ansible.builtin.command:
        cmd: "{{ 'rpm -qa' if ansible_os_family == 'RedHat' else 'dpkg -l' }}"
      register: pre_pkgs
      changed_when: false

    - name: Save it to the control node for the audit trail
      ansible.builtin.copy:
        content: "{{ pre_pkgs.stdout }}"
        dest: "./patch-audit/{{ inventory_hostname }}-before.txt"
      delegate_to: localhost
      become: false

    - name: Take this node out of the load balancer
      ansible.builtin.uri:
        url: "http://{{ lb_host }}/api/disable/{{ inventory_hostname }}"
        method: POST
      delegate_to: localhost
      become: false
      when: lb_host is defined

  tasks:
    - name: Apply security updates (RHEL family)
      ansible.builtin.dnf:
        name: "*"
        state: latest
        security: true
        exclude: "{{ patch_exclude | default(omit) }}"
      when: ansible_os_family == 'RedHat'
      register: dnf_result

    - name: Apply updates (Debian family)
      ansible.builtin.apt:
        upgrade: safe
        update_cache: true
        cache_valid_time: 3600
        autoremove: true
      when: ansible_os_family == 'Debian'
      register: apt_result

    - name: Check whether a reboot is required (RHEL)
      ansible.builtin.command:
        cmd: needs-restarting -r
      register: nr
      failed_when: false
      changed_when: false
      when: ansible_os_family == 'RedHat'

    - name: Check whether a reboot is required (Debian)
      ansible.builtin.stat:
        path: /var/run/reboot-required
      register: deb_reboot
      when: ansible_os_family == 'Debian'

    - name: Decide
      ansible.builtin.set_fact:
        needs_reboot: >-
          {{ (ansible_os_family == 'RedHat' and nr.rc | default(0) == 1)
             or (ansible_os_family == 'Debian' and deb_reboot.stat.exists | default(false)) }}

    - name: Reboot and wait for the host to come back
      ansible.builtin.reboot:
        msg: "Rebooting for patches via Ansible"
        reboot_timeout: 900
        connect_timeout: 30
        pre_reboot_delay: 10
        post_reboot_delay: 30
        test_command: "systemctl is-system-running --wait"
      when: needs_reboot | bool and reboot_if_needed | bool

  post_tasks:
    - name: Wait for the application port to answer again
      ansible.builtin.wait_for:
        port: "{{ app_port | default(80) }}"
        host: "{{ ansible_default_ipv4.address }}"
        delay: 5
        timeout: 300
      delegate_to: localhost
      become: false

    - name: Health check before we accept traffic again
      ansible.builtin.uri:
        url: "http://{{ ansible_default_ipv4.address }}:{{ app_port | default(80) }}/healthz"
        status_code: 200
      retries: 10
      delay: 6
      register: health
      until: health.status == 200
      delegate_to: localhost
      become: false

    - name: Put the node back in the load balancer
      ansible.builtin.uri:
        url: "http://{{ lb_host }}/api/enable/{{ inventory_hostname }}"
        method: POST
      delegate_to: localhost
      become: false
      when: lb_host is defined
```

**The whole shape, in plain words:** take a server out of rotation → patch it → reboot only if needed → wait for it to be genuinely healthy → put it back → move to the next batch. `serial: "25%"` guarantees three-quarters of your capacity stays online. `max_fail_percentage: 10` is the emergency brake: if a bad patch starts killing servers, the play stops rather than marching through the whole fleet.

**`ansible.builtin.reboot` is smarter than `shell: reboot`.** It issues the reboot, deliberately tolerates the SSH connection dropping, then polls until the host answers again and `test_command` succeeds. Doing it with `shell:` just makes the task fail when the connection dies.

**`needs-restarting -r` exit codes:** 0 means no reboot needed, 1 means reboot needed. That's why we check `rc == 1` and set `failed_when: false` — a "1" here is information, not an error.

### 12.2 Zero-downtime rolling deploy pattern

```yaml
- name: Rolling application deploy
  hosts: appservers
  become: true
  serial: 1
  any_errors_fatal: true

  tasks:
    - name: Drain connections
      ansible.builtin.command:
        cmd: /usr/local/bin/drain.sh
      changed_when: true

    - name: Wait for in-flight requests to finish
      ansible.builtin.wait_for:
        timeout: 30

    - name: Deploy the new release
      ansible.builtin.unarchive:
        src: "releases/app-{{ app_version }}.tar.gz"
        dest: "/opt/app/releases/"
        owner: appuser

    - name: Flip the 'current' symlink atomically
      ansible.builtin.file:
        src: "/opt/app/releases/app-{{ app_version }}"
        dest: /opt/app/current
        state: link
        force: true

    - name: Restart the app
      ansible.builtin.systemd_service:
        name: myapp
        state: restarted

    - name: Verify health before continuing to the next host
      ansible.builtin.uri:
        url: "http://localhost:{{ app_port }}/healthz"
        status_code: 200
      retries: 20
      delay: 3
      register: h
      until: h.status == 200

    - name: Rejoin the pool
      ansible.builtin.command:
        cmd: /usr/local/bin/undrain.sh
      changed_when: true
```

**Why the symlink flip:** unpacking directly over a live application means half-new, half-old files for several seconds. Instead you unpack into a versioned folder and then repoint one symlink — an operation the filesystem does instantly. Rollback becomes "point the symlink back," which takes milliseconds.

**`any_errors_fatal: true` + `serial: 1`:** if host #3 fails its health check, the play stops immediately. Hosts 4 through 40 keep running the old, working version. This one line is the difference between a bad deploy affecting one server and it affecting all of them.

---

<a name="13-health-checks"></a>
## 13. Detailed Examples: Health Checks and Reporting

### 13.1 A full system audit playbook

```yaml
---
- name: Fleet health audit
  hosts: all
  gather_facts: true
  become: true

  tasks:
    - name: Uptime
      ansible.builtin.command: uptime -p
      register: up
      changed_when: false

    - name: Load average
      ansible.builtin.command: cat /proc/loadavg
      register: load
      changed_when: false

    - name: Failed systemd units
      ansible.builtin.command: systemctl --failed --no-legend --no-pager
      register: failed_units
      changed_when: false
      failed_when: false

    - name: Pending package updates (RHEL)
      ansible.builtin.command: dnf check-update -q
      register: updates
      failed_when: updates.rc not in [0, 100]   # 100 means "updates available"
      changed_when: false
      when: ansible_os_family == 'RedHat'

    - name: Listening ports
      ansible.builtin.command: ss -tulpn
      register: ports
      changed_when: false

    - name: Last 10 logins
      ansible.builtin.command: last -n 10
      register: logins
      changed_when: false

    - name: Build a per-host report
      ansible.builtin.set_fact:
        host_report:
          hostname: "{{ ansible_fqdn }}"
          os: "{{ ansible_distribution }} {{ ansible_distribution_version }}"
          kernel: "{{ ansible_kernel }}"
          uptime: "{{ up.stdout }}"
          load: "{{ load.stdout.split()[0:3] | join(', ') }}"
          cpus: "{{ ansible_processor_vcpus }}"
          memory_mb: "{{ ansible_memtotal_mb }}"
          mem_free_mb: "{{ ansible_memfree_mb }}"
          failed_units: "{{ failed_units.stdout_lines | length }}"
          ip: "{{ ansible_default_ipv4.address | default('n/a') }}"
          reboot_required: "{{ (updates.rc | default(0)) == 100 }}"

    - name: Write a per-host report file on the control node
      ansible.builtin.copy:
        content: "{{ host_report | to_nice_yaml }}"
        dest: "./reports/{{ inventory_hostname }}.yml"
      delegate_to: localhost
      become: false

- name: Build one combined HTML report
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Render the summary
      ansible.builtin.template:
        src: report.html.j2
        dest: ./reports/fleet-summary.html
      vars:
        all_reports: "{{ groups['all'] | map('extract', hostvars, 'host_report') | select('defined') | list }}"
```

`templates/report.html.j2`:

```jinja
<!DOCTYPE html>
<html><head><title>Fleet Report</title>
<style>
 body{font-family:system-ui,sans-serif;margin:2rem}
 table{border-collapse:collapse;width:100%}
 th,td{border:1px solid #ddd;padding:.5rem;text-align:left}
 th{background:#f4f4f4}
 .warn{background:#fff3cd}.bad{background:#f8d7da}
</style></head><body>
<h1>Fleet Health — {{ ansible_date_time.date }}</h1>
<table>
<tr><th>Host</th><th>OS</th><th>Kernel</th><th>Uptime</th><th>Load</th><th>Mem Free</th><th>Failed Units</th></tr>
{% for r in all_reports %}
<tr class="{{ 'bad' if r.failed_units | int > 0 else '' }}">
  <td>{{ r.hostname }}</td>
  <td>{{ r.os }}</td>
  <td>{{ r.kernel }}</td>
  <td>{{ r.uptime }}</td>
  <td>{{ r.load }}</td>
  <td>{{ r.mem_free_mb }} MB</td>
  <td>{{ r.failed_units }}</td>
</tr>
{% endfor %}
</table>
<p>{{ all_reports | length }} hosts reported.</p>
</body></html>
```

**`map('extract', hostvars, 'host_report')` decoded:** for every hostname in `groups['all']`, reach into `hostvars` for that host and pull out its `host_report` variable. It's how you gather one fact from every server into a single list on the control node.

### 13.2 Assertion-based compliance checks

```yaml
- name: Security compliance checks
  hosts: all
  become: true
  tasks:
    - name: Read sshd_config
      ansible.builtin.slurp:
        src: /etc/ssh/sshd_config
      register: sshd_raw

    - name: Set a readable variable
      ansible.builtin.set_fact:
        sshd_text: "{{ sshd_raw.content | b64decode }}"

    - name: Assert SSH is hardened
      ansible.builtin.assert:
        that:
          - "'PermitRootLogin no' in sshd_text"
          - "'PasswordAuthentication no' in sshd_text"
          - ansible_selinux.status | default('') == 'enabled' or ansible_os_family != 'RedHat'
        fail_msg: "❌ {{ inventory_hostname }} failed hardening checks"
        success_msg: "✅ {{ inventory_hostname }} is compliant"
      ignore_errors: true
      register: compliance

    - name: Summarize failures
      ansible.builtin.debug:
        msg: "NON-COMPLIANT: {{ inventory_hostname }}"
      when: compliance is failed
```

**`ignore_errors: true` + `register:`** lets you keep auditing every host instead of stopping at the first failure, and still collect the results. Without it, one non-compliant server ends the run.

---

<a name="14-the-language"></a>
## 14. The Language: Variables, Facts, Loops, Handlers, Blocks, Tags

### 14.1 Variables

```yaml
- name: Variable techniques
  hosts: all
  vars:
    simple_string: "hello"
    a_number: 42
    a_boolean: true
    a_list: [alpha, beta, gamma]
    a_dict:
      name: myapp
      port: 8080
      features: [auth, cache]
    computed: "{{ a_dict.name }}-{{ a_dict.port }}"

  vars_files:
    - vars/common.yml
    - "vars/{{ env_name }}.yml"

  vars_prompt:
    - name: deploy_confirm
      prompt: "Type YES to deploy to production"
      private: false

  tasks:
    - name: Dot notation and bracket notation both work
      ansible.builtin.debug:
        msg: "{{ a_dict.port }} == {{ a_dict['port'] }}"

    - name: Create a variable at runtime
      ansible.builtin.set_fact:
        release_tag: "{{ app_name }}-{{ ansible_date_time.epoch }}"
        cacheable: true          # persists into the fact cache across plays

    - name: Safe access to something that may not exist
      ansible.builtin.debug:
        msg: "{{ maybe_missing | default('fallback') }}"

    - name: Require a variable to be supplied
      ansible.builtin.assert:
        that:
          - app_version is defined
          - app_version is match('^[0-9]+\.[0-9]+\.[0-9]+$')
        fail_msg: "app_version must be set, e.g. -e app_version=1.2.3"

    - name: What type is this thing, really?
      ansible.builtin.debug:
        msg: "{{ a_number | type_debug }}"
```

**Naming rules:** letters, numbers, and underscores; must start with a letter or underscore. **No dashes.** `app-port` is invalid; `app_port` is correct.

**The quoting rule that saves hours:** a value that *starts* with `{{` must be quoted, because YAML thinks `{` begins a dictionary.
- ✅ `port: "{{ app_port }}"`
- ❌ `port: {{ app_port }}` → YAML syntax error
- ✅ `url: "http://{{ host }}/x"` (already quoted anyway)

### 14.2 Loops

```yaml
# Simple list
- name: Install packages
  ansible.builtin.package:
    name: "{{ item }}"
    state: present
  loop: [git, vim, curl]

# List of dictionaries — the most common real pattern
- name: Create users
  ansible.builtin.user:
    name: "{{ item.name }}"
    groups: "{{ item.groups }}"
    shell: "{{ item.shell | default('/bin/bash') }}"
  loop:
    - { name: alice, groups: wheel }
    - { name: bob,   groups: dba, shell: /bin/zsh }
  loop_control:
    label: "{{ item.name }}"

# Loop over a dictionary
- name: Apply sysctl settings
  ansible.posix.sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
  loop: "{{ sysctl_map | dict2items }}"

# Nested loop (every combination)
- name: Grant each user access to each database
  ansible.builtin.debug:
    msg: "{{ item.0 }} -> {{ item.1 }}"
  loop: "{{ users | product(databases) | list }}"

# Loop with index and extended info
- name: Numbered output
  ansible.builtin.debug:
    msg: "{{ ansible_loop.index }}/{{ ansible_loop.length }}: {{ item }}"
  loop: "{{ servers }}"
  loop_control:
    extended: true
    pause: 2            # wait 2 seconds between iterations

# Loop over a registered result
- name: Delete found files
  ansible.builtin.file:
    path: "{{ item.path }}"
    state: absent
  loop: "{{ found.files }}"

# Loop over files on the control node
- name: Copy every conf file
  ansible.builtin.copy:
    src: "{{ item }}"
    dest: "/etc/app.d/{{ item | basename }}"
  loop: "{{ query('ansible.builtin.fileglob', 'files/conf.d/*.conf') }}"

# Retry until success
- name: Wait for the API to come up
  ansible.builtin.uri:
    url: "http://localhost:8080/health"
  register: r
  retries: 30
  delay: 5
  until: r.status is defined and r.status == 200
```

**`loop` vs `with_items`:** `with_*` is the old syntax. `loop` is the modern one and is what all current documentation uses. They mostly behave the same, except `with_items` auto-flattens nested lists and `loop` does not — use the `flatten` filter if you need that.

**Performance warning:** a loop runs the module once per item, which means one SSH round-trip each. Ten packages in a loop is ten transactions; one list passed to `name:` is one. **Where a module accepts a list, pass a list.**

### 14.3 Conditionals

```yaml
- name: Only on RedHat family
  ansible.builtin.dnf: { name: httpd, state: present }
  when: ansible_os_family == 'RedHat'

- name: Multiple conditions — a list means AND
  ansible.builtin.debug: { msg: "Big modern RHEL box" }
  when:
    - ansible_os_family == 'RedHat'
    - ansible_distribution_major_version | int >= 9
    - ansible_memtotal_mb > 8000

- name: OR conditions
  ansible.builtin.debug: { msg: "Debian-ish" }
  when: ansible_distribution == 'Ubuntu' or ansible_distribution == 'Debian'

- name: Membership
  ansible.builtin.debug: { msg: "Supported" }
  when: ansible_distribution in ['Ubuntu', 'RedHat', 'Rocky', 'AlmaLinux']

- name: Based on a previous result
  ansible.builtin.systemd_service: { name: nginx, state: restarted }
  when: config_task is changed

- name: Existence and group membership
  ansible.builtin.debug: { msg: "web + var set" }
  when:
    - "'webservers' in group_names"
    - custom_var is defined
    - custom_var | length > 0

- name: Skip during dry runs
  ansible.builtin.command: /usr/local/bin/dangerous.sh
  when: not ansible_check_mode

- name: Version comparison
  ansible.builtin.debug: { msg: "New enough" }
  when: ansible_distribution_version is version('9.0', '>=')
```

**Why `when:` has no `{{ }}`:** `when` is already evaluated as a Jinja expression, so braces are redundant and can even cause errors. Write `when: my_var == 'x'`, not `when: "{{ my_var }} == 'x'"`.

**Conditions run per host.** `when` is evaluated separately for every server, which is exactly what makes one playbook work across mixed fleets.

### 14.4 Handlers

```yaml
  tasks:
    - name: Update main config
      ansible.builtin.template:
        src: app.conf.j2
        dest: /etc/app/app.conf
      notify:
        - Validate app config
        - Restart app

    - name: Update secondary config
      ansible.builtin.template:
        src: extra.conf.j2
        dest: /etc/app/extra.conf
      notify: Restart app       # same handler, still runs only once

  handlers:
    - name: Validate app config
      ansible.builtin.command: /usr/sbin/appctl -t
      changed_when: false

    - name: Restart app
      ansible.builtin.systemd_service:
        name: myapp
        state: restarted

    - name: Restart app family
      ansible.builtin.systemd_service:
        name: "{{ item }}"
        state: restarted
      loop: [myapp, myapp-worker]
      listen: "restart everything"    # notify: "restart everything" triggers this
```

**The four rules of handlers:**
1. They run **only if the notifying task reported `changed`**.
2. They run **once**, at the **end of the play**, no matter how many tasks notified them.
3. They run **in the order they're defined**, not the order they were notified.
4. If the play fails partway, **handlers are skipped** — unless you set `force_handlers: true`.

**Force them early with `- ansible.builtin.meta: flush_handlers`** when you need the restart to happen before a later verification step.

### 14.5 Blocks and error handling

```yaml
- name: Grouped tasks with shared settings
  block:
    - name: Task A
      ansible.builtin.command: /bin/true
    - name: Task B
      ansible.builtin.command: /bin/true
  when: ansible_os_family == 'RedHat'    # applies to both
  become: true
  tags: [setup]

- name: Try, catch, finally
  block:
    - name: Risky operation
      ansible.builtin.command: /usr/local/bin/migrate.sh
  rescue:
    - name: Show what went wrong
      ansible.builtin.debug:
        msg: "Failed: {{ ansible_failed_task.name }} — {{ ansible_failed_result.msg | default('') }}"
    - name: Undo it
      ansible.builtin.command: /usr/local/bin/rollback.sh
  always:
    - name: Clean up regardless
      ansible.builtin.file:
        path: /tmp/migration.lock
        state: absent
```

**Custom success/failure logic:**

```yaml
- name: Run a check script with custom result rules
  ansible.builtin.command: /usr/local/bin/check.sh
  register: chk
  changed_when: "'MODIFIED' in chk.stdout"
  failed_when:
    - chk.rc != 0
    - "'WARNING' not in chk.stderr"     # rc!=0 is only a failure if it wasn't a warning
```

`ansible_failed_task` and `ansible_failed_result` are magic variables available **only inside `rescue`** — they tell you exactly what blew up.

### 14.6 Tags

```yaml
  tasks:
    - name: Install packages
      ansible.builtin.package: { name: nginx, state: present }
      tags: [install, packages]

    - name: Deploy config
      ansible.builtin.template: { src: n.conf.j2, dest: /etc/nginx/nginx.conf }
      tags: [config]

    - name: Slow full reindex
      ansible.builtin.command: /usr/local/bin/reindex.sh
      tags: [never, reindex]      # ONLY runs with --tags reindex

    - name: Always print the version
      ansible.builtin.debug: { msg: "v{{ app_version }}" }
      tags: [always]
```

```bash
ansible-playbook site.yml --tags config              # only config tasks
ansible-playbook site.yml --skip-tags install        # everything but installs
ansible-playbook site.yml --tags reindex             # opts into the 'never' task
ansible-playbook site.yml --list-tags                # what tags exist?
```

Tags turn a 20-minute full playbook into a 20-second config push. Tag consistently: `install`, `config`, `service`, `deploy`, `security`, `debug`.

### 14.7 Speed features

```yaml
# Long job in the background
- name: Kick off a long backup and don't wait
  ansible.builtin.command: /usr/local/bin/full-backup.sh
  async: 7200        # allow up to 2 hours
  poll: 0            # 0 = fire and forget
  register: bkp

- name: Do other things meanwhile
  ansible.builtin.debug: { msg: "carrying on" }

- name: Now wait for it
  ansible.builtin.async_status:
    jid: "{{ bkp.ansible_job_id }}"
  register: job
  until: job.finished
  retries: 240
  delay: 30

# Run something once for the whole group
- name: Run the DB migration on one host only
  ansible.builtin.command: /usr/local/bin/migrate.sh
  run_once: true

# Do something on a different machine
- name: Add this host to monitoring
  ansible.builtin.uri:
    url: "https://monitor.example.com/api/hosts"
    method: POST
    body_format: json
    body: { hostname: "{{ inventory_hostname }}" }
  delegate_to: localhost
  become: false

# Limit concurrency for a rate-limited API
- name: Register with a fragile service
  ansible.builtin.uri: { url: "https://api.example.com/register" }
  throttle: 2
```

**Fact caching — the biggest easy speed win.** Add to `ansible.cfg`:

```ini
[defaults]
gathering = smart
fact_caching = jsonfile
fact_caching_connection = /tmp/ansible_facts
fact_caching_timeout = 7200
```

`gathering = smart` means "only gather facts if we don't already have fresh ones cached." On a 200-host fleet this can shave minutes off every run. Turn off gathering entirely (`gather_facts: false`) in plays that don't reference any `ansible_*` variable.

---

<a name="15-roles-and-layout"></a>
## 15. Roles, Collections, and Project Layout

### 15.1 Standard role structure

```
roles/
  nginx/
    defaults/main.yml     # lowest-precedence variables — the knobs users may override
    vars/main.yml         # high-precedence internals — don't expect users to change these
    tasks/main.yml        # the entry point
    handlers/main.yml     # restart/reload handlers
    templates/            # .j2 files
    files/                # static files to copy
    meta/main.yml         # metadata + role dependencies
    tests/                # test playbook
    README.md             # WHAT it does, WHICH variables it takes
```

`roles/nginx/defaults/main.yml`:

```yaml
nginx_package: nginx
nginx_service: nginx
nginx_user: "{{ 'nginx' if ansible_os_family == 'RedHat' else 'www-data' }}"
nginx_port: 80
nginx_worker_connections: 1024
nginx_enable_gzip: true
nginx_sites: []
```

`roles/nginx/tasks/main.yml`:

```yaml
---
- name: Include OS-specific variables
  ansible.builtin.include_vars: "{{ lookup('ansible.builtin.first_found', params) }}"
  vars:
    params:
      files:
        - "{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml"
        - "{{ ansible_os_family }}.yml"
        - "default.yml"
      paths:
        - "vars"

- name: Install nginx
  ansible.builtin.package:
    name: "{{ nginx_package }}"
    state: present
  tags: [install]

- name: Deploy main configuration
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    mode: "0644"
    validate: nginx -t -c %s
  notify: Reload nginx
  tags: [config]

- name: Deploy virtual hosts
  ansible.builtin.template:
    src: vhost.conf.j2
    dest: "/etc/nginx/conf.d/{{ item.name }}.conf"
    mode: "0644"
  loop: "{{ nginx_sites }}"
  loop_control:
    label: "{{ item.name }}"
  notify: Reload nginx
  tags: [config]

- name: Ensure nginx is running
  ansible.builtin.systemd_service:
    name: "{{ nginx_service }}"
    state: started
    enabled: true
  tags: [service]
```

Using it:

```yaml
- name: Build web tier
  hosts: webservers
  become: true
  roles:
    - role: common
    - role: nginx
      vars:
        nginx_port: 8080
        nginx_sites:
          - { name: app, server_name: app.example.com, root: /var/www/app }
    - role: monitoring
```

### 15.2 Recommended project layout

```
ansible-project/
├── ansible.cfg
├── requirements.yml            # collections & roles to install
├── site.yml                    # the master playbook
├── playbooks/
│   ├── webservers.yml
│   ├── patching.yml
│   └── audit.yml
├── inventory/
│   ├── production/
│   │   ├── hosts.yml
│   │   ├── group_vars/
│   │   │   ├── all.yml
│   │   │   ├── all/vault.yml   # encrypted
│   │   │   └── webservers.yml
│   │   └── host_vars/
│   └── staging/
├── roles/
│   ├── common/
│   ├── nginx/
│   └── postgres/
├── collections/                # ansible-galaxy install target
├── files/
├── templates/
└── README.md
```

`requirements.yml`:

```yaml
---
collections:
  - name: community.general
    version: ">=10.0.0"
  - name: ansible.posix
  - name: community.crypto

roles:
  - name: geerlingguy.docker
    version: 7.4.1
```

```bash
ansible-galaxy install -r requirements.yml
ansible-galaxy collection install -r requirements.yml -p ./collections
```

**Always pin versions in `requirements.yml`.** An unpinned dependency means your playbook can start behaving differently tomorrow because someone else released a new version.

### 15.3 `import_*` vs `include_*` — the distinction that confuses everyone

| | `import_tasks` / `import_role` | `include_tasks` / `include_role` |
|---|---|---|
| When it's processed | **Static** — at parse time, before anything runs | **Dynamic** — at run time, when the line is reached |
| Can use a variable in the filename? | ❌ No | ✅ Yes |
| Can be inside a `loop`? | ❌ No | ✅ Yes |
| Do tags reach the inner tasks? | ✅ Yes, inherited | ⚠️ Only the include itself is tagged |
| Shows in `--list-tasks`? | ✅ Yes | ❌ No |

**Rule of thumb:** use `import_*` by default (better tagging and visibility); switch to `include_*` when you need a variable filename or a loop.

---

<a name="16-vault"></a>
## 16. Ansible Vault (Secrets)

### 16.1 Commands

```bash
# Create a new encrypted file
ansible-vault create group_vars/all/vault.yml

# Edit it (decrypts to a temp file, re-encrypts on save)
ansible-vault edit group_vars/all/vault.yml

# Encrypt an existing plaintext file
ansible-vault encrypt secrets.yml

# Decrypt it back (careful!)
ansible-vault decrypt secrets.yml

# Look without editing
ansible-vault view group_vars/all/vault.yml

# Change the password
ansible-vault rekey group_vars/all/vault.yml

# Encrypt just ONE value, to paste into a normal YAML file
ansible-vault encrypt_string 'sup3rs3cret' --name 'db_password'
```

### 16.2 Using it

```bash
# Prompt for the password
ansible-playbook site.yml --ask-vault-pass

# Read the password from a file (chmod 600, and .gitignore it!)
ansible-playbook site.yml --vault-password-file ~/.vault_pass

# Multiple vaults with IDs
ansible-playbook site.yml --vault-id prod@prompt --vault-id dev@~/.dev_pass
```

Or set it permanently in `ansible.cfg`:

```ini
[defaults]
vault_password_file = ~/.vault_pass
```

### 16.3 The layout pattern everyone uses

```
group_vars/
  production/
    vars.yml       # plaintext, readable, reviewable
    vault.yml      # encrypted
```

`vars.yml`:

```yaml
db_user: appuser
db_host: db1.example.com
db_password: "{{ vault_db_password }}"   # a pointer to the secret
```

`vault.yml` (encrypted):

```yaml
vault_db_password: "actual-secret-here"
vault_api_token: "another-secret"
```

**Why the indirection?** Encrypted files are opaque blobs in `git diff` — you can't see *what* changed, only *that* it changed. By keeping all the readable structure in `vars.yml` and putting only raw secret values in `vault.yml` with a `vault_` prefix, code review stays useful and you can grep your repo to see which secrets exist without decrypting anything.

### 16.4 Best practices — secrets

- ✅ Prefix vaulted variables with `vault_` so they're obvious.
- ✅ Add `no_log: true` to any task that touches a secret.
- ✅ Different vault passwords per environment (`--vault-id prod@prompt`).
- ✅ Add the vault password file to `.gitignore` and never commit it.
- ✅ For bigger setups, graduate to a real secrets manager (HashiCorp Vault, AWS Secrets Manager) via a lookup plugin — you get rotation and audit logs, which Ansible Vault does not provide.
- ❌ Never `ansible-vault decrypt` a file "temporarily" in a git working tree. You will commit it.
- ❌ Don't put secrets in `--extra-vars` on the command line — they land in your shell history and the process list.

---

<a name="17-best-practices"></a>
## 17. Best Practices

### Structure
- **Name every play, task, and handler.** Unnamed tasks print module names, which are useless when debugging at 3 a.m.
- **One role per service.** If a role touches nginx *and* postgres, split it.
- **Use `site.yml` as a thin master** that imports playbooks; keep logic in roles.
- **Separate inventories per environment** — never one inventory with an `env` variable deciding whether you hit prod.
- **Keep playbooks under ~100 lines.** Beyond that, make roles.

### Correctness
- **Always use FQCN** (`ansible.builtin.copy`). Ambiguity bites you when collections update.
- **Test idempotency**: run twice, demand `changed=0` on the second run. Make this a CI gate.
- **Prefer modules over `shell`/`command`.** Every `shell:` is a small piece of Ansible you've turned off.
- **When you must use `command`, guard it** with `creates:`, `removes:`, `when:`, or `changed_when:`.
- **Quote things that start with `{{`** and quote all `mode:` values.
- **`validate:` on every config file** that has a validator.

### Safety
- **`--check --diff` before every real run.** No exceptions in production.
- **`serial:` for anything that restarts a service.** Start at 1, widen once you trust it.
- **`max_fail_percentage:`** so a bad change stops rather than spreads.
- **Handlers for restarts, never plain `state: restarted` tasks.**
- **`no_log: true`** on credential-handling tasks.
- **Health-check after you change something.** Deploying is not the same as working.

### Speed
- Turn on `pipelining` and `ControlPersist`.
- Raise `forks` (20–50 is comfortable; test your control node's CPU).
- Enable **fact caching**; set `gather_facts: false` where facts aren't used.
- Pass **lists** to modules instead of looping.
- Use `async` for genuinely long jobs.
- Use `ansible.builtin.setup` with `gather_subset: '!all,!min,network'` to gather only what you need.

### Process
- **Everything in Git.** Playbooks, inventory, roles, requirements.
- **`ansible-lint` in CI**, plus `--syntax-check` and a Molecule test if you're serious.
- **Pin collection and role versions.**
- **Write a README per role** listing every variable and its default.
- **Review changes like code.** A one-character diff in a template hits 300 servers.
- **Use `--limit` while developing.** Test on one host before the fleet.

### Anti-patterns to unlearn
- ❌ `shell: |` blocks of 40 lines. That's a bash script wearing a costume — either use modules or use `script:`.
- ❌ `ignore_errors: true` sprinkled everywhere to make red text go away.
- ❌ `become: true` at the play level when only two tasks need it.
- ❌ `gather_facts: true` in a play that never reads a fact.
- ❌ Hardcoded IPs, paths, and versions inside tasks.
- ❌ `when: item.something` on a loop with no `loop_control: label:` — unreadable output.
- ❌ Editing files on servers by hand "just this once." That's how drift starts.

---

<a name="18-pros-and-cons"></a>
## 18. Pros and Cons

### 18.1 Ansible itself

**Pros**
- **Agentless** — nothing to install, patch, or debug on managed nodes. Just SSH + Python.
- **Low learning curve** — YAML is readable by people who don't code. A new team member can review a playbook on day one.
- **Enormous module ecosystem** — thousands of modules covering Linux, Windows, network gear, and every major cloud.
- **Idempotent by design** — safe to re-run, which makes it usable as both a deploy tool and a drift corrector.
- **Push model with instant control** — you decide exactly when a change happens, and you watch it happen.
- **Great for orchestration**, not just config: rolling restarts, multi-tier deploys, and load-balancer coordination are first-class.
- **Everything is text**, so Git gives you history, review, and rollback for free.
- **Works on day one** with no server infrastructure at all.

**Cons**
- **Slow at scale.** SSH per host per task adds up; 1,000+ hosts needs tuning (forks, pipelining, fact caching) or AAP/AWX.
- **YAML is not a programming language.** Complex logic becomes ugly, and error messages from deep Jinja expressions can be cryptic.
- **No enforced state between runs.** If someone edits a file by hand, nothing is corrected until you run the playbook again. (Pull-based tools with periodic agents fix drift automatically.)
- **Ordering surprises** — variable precedence has ~22 levels and catches everyone eventually.
- **Requires Python on targets** (a genuine limitation on appliances and minimal containers, though `raw` can bootstrap).
- **Push model needs reachability** — the control node must be able to reach every host, which is awkward across NAT or intermittent networks.
- **Testing is harder than code** — Molecule helps, but it's extra machinery.
- **Version churn** — ansible-core supports only ~3 releases, so upgrades are a recurring chore.

### 18.2 Ansible vs the alternatives

| Tool | Best at | Weakness vs Ansible |
|---|---|---|
| **Ansible** | Config mgmt + orchestration, ad-hoc ops, mixed fleets, agentless | Slower at very large scale; no automatic drift correction |
| **Puppet** | Continuous enforcement of desired state at huge scale | Needs agents + a server; own DSL; weaker for orchestration/ordering |
| **Chef** | Complex logic (it's real Ruby) | Needs agents; steepest learning curve; heavier infrastructure |
| **Salt** | Very fast at large scale (persistent ZeroMQ bus) | Agent-based by default; smaller community now |
| **Terraform / OpenTofu** | *Creating* infrastructure (VMs, networks, cloud) | Not for in-OS config; the two are complements, not rivals |
| **Shell scripts** | Tiny one-offs | No idempotency, inventory, reporting, or safe parallelism |
| **Docker/K8s** | Immutable, replaceable workloads | Doesn't manage the hosts themselves — you still need Ansible below it |

**The common real-world combo:** Terraform/OpenTofu builds the machines → Ansible configures them → Kubernetes runs the apps.

### 18.3 Key decisions, side by side

| Decision | Option A | Option B | Guidance |
|---|---|---|---|
| Inventory format | INI (simple, fast to read) | YAML (nesting, complex vars) | YAML for anything non-trivial |
| Whole-file vs line edits | `template` (you own it) | `lineinfile` (surgical) | Template unless a package owns the file |
| `command` vs `shell` | `command` (no shell, safer) | `shell` (pipes, globs) | `command` unless you need shell features |
| Static roles vs dynamic includes | `import_role` | `include_role` | Import by default; include when you need variables/loops |
| `serial: 1` vs full parallel | Safe, slow | Fast, risky | Serial for stateful services; parallel for stateless |
| Ansible Vault vs external secrets manager | Simple, no infra | Rotation, audit, RBAC | Vault to start; external once you have compliance needs |
| Community roles vs your own | Fast start, battle-tested | Full control, no surprises | Read the source before adopting; pin the version |
| CLI Ansible vs AWX/AAP | Free, simple, git-native | RBAC, scheduling, UI, audit, API | Add AWX when non-admins need to run playbooks |

---

<a name="19-troubleshooting"></a>
## 19. Troubleshooting

### 19.1 Debugging toolkit

```bash
ansible-playbook site.yml -vvv                 # verbose; -vvvv adds SSH internals
ansible-playbook site.yml --step               # confirm each task manually
ansible-playbook site.yml --start-at-task "Deploy config"
ansible all -m ansible.builtin.setup           # dump every fact
ansible all -m ansible.builtin.setup -a 'filter=ansible_distribution*'
ansible-inventory --graph                      # visualize groups
ansible-inventory --host web1 --yaml           # all vars for one host
ansible web1 -m ansible.builtin.debug -a 'var=hostvars[inventory_hostname]'
ansible-config dump --only-changed             # what settings are non-default?
ansible-doc -l | grep firewall                 # find a module
ansible-doc ansible.posix.firewalld            # read its docs
ansible-doc -s ansible.builtin.copy            # short form: just the options
```

In a playbook:

```yaml
- name: Dump a variable
  ansible.builtin.debug:
    var: my_complex_var
    verbosity: 1          # only shows with -v

- name: Interactive debugger on failure
  ansible.builtin.command: /bin/false
  ignore_errors: true
  # or add to the play:  strategy: debug
```

With `strategy: debug`, a failing task drops you into a prompt where you can type `p task_vars`, `p result`, change a variable with `task.args['x'] = 'y'`, and then `redo`.

### 19.2 Common errors and what they actually mean

| Message | Real cause | Fix |
|---|---|---|
| `UNREACHABLE! ... Permission denied (publickey)` | SSH key isn't on the target for that user | `ssh-copy-id`, check `ansible_user`, try `-k` |
| `Missing sudo password` | `become: true` but no password supplied | Add `-K`, or configure NOPASSWD sudo |
| `The task includes an option with an undefined variable` | Typo, or the variable is defined for a different host/scope | `| default('x')`, or `ansible-inventory --host X` to see what's actually set |
| `Syntax Error while loading YAML ... could not find expected ':'` | Almost always a value starting with `{{` that isn't quoted, or a tab character | Quote it; never use tabs in YAML |
| `FAILED! ... /bin/sh: python: not found` | No Python on the target | `ansible_python_interpreter=/usr/bin/python3`, or bootstrap with `raw` |
| Task reports `changed` on every run | `command`/`shell` with no guard, or `lineinfile` regexp mismatch | Add `changed_when:`/`creates:`; fix the regexp |
| `Timeout (12s) waiting for privilege escalation prompt` | sudo is prompting; pipelining conflict with `requiretty` | Use `-K`, or disable `requiretty` in sudoers |
| `Failed to connect to the host via ssh: Host key verification failed` | New/changed host key | `ssh-keyscan -H host >> ~/.ssh/known_hosts` (don't just disable checking) |
| `AnsibleUndefinedVariable: 'dict object' has no attribute 'x'` | Facts weren't gathered, or the key genuinely doesn't exist | Check `gather_facts`, use `| default({})`, print with `debug` first |
| `msg: 'Unsupported parameters'` | Module version mismatch — you're reading newer docs than your installed collection | `ansible-doc <module>` shows *your* version's options |

### 19.3 Speed diagnosis

```ini
# ansible.cfg
[defaults]
callbacks_enabled = timer, profile_tasks, profile_roles
```

This prints the slowest tasks at the end of every run. Typical culprits, in order: fact gathering on every play, loops that should be lists, `synchronize` over a slow link, and `apt update` without `cache_valid_time`.

---

<a name="20-quick-reference"></a>
## 20. One-Page Quick Reference

### Ad-hoc commands you'll actually type

```bash
ansible all -m ping                                        # connectivity test
ansible all -m setup -a 'filter=ansible_distribution*'     # a few facts
ansible web -a "uptime"                                    # 'command' is the default module
ansible web -m shell -a "df -h | grep -v tmpfs"            # needs a shell
ansible all -m package -a "name=htop state=present" -b     # install everywhere
ansible all -m service -a "name=nginx state=restarted" -b  # restart everywhere
ansible all -m copy -a "src=./f dest=/etc/f mode=0644" -b  # push a file
ansible all -m file -a "path=/tmp/x state=absent" -b       # delete
ansible all -m user -a "name=bob state=absent remove=yes" -b
ansible all -m cron -a "name=job minute=0 job=/x.sh" -b
ansible all -m git -a "repo=... dest=/opt/app version=main"
ansible all -m reboot -b
ansible all -m command -a "needs-restarting -r" -b
ansible web --list-hosts                                   # who matches?
ansible all -m debug -a "var=ansible_default_ipv4.address"
```

### Host pattern syntax

```
all  or  *              everything
web1                    one host
webservers              a group
web*.example.com        wildcard
web:db                  union (in either group)
web:&staging            intersection (in BOTH)
web:!web3               exclusion (web group, minus web3)
webservers[0]           the first host in the group
webservers[0:2]         a slice
~web\d+\.example\.com   regex (prefix with ~)
```

### The playbook skeleton, from memory

```yaml
---
- name: Descriptive play name
  hosts: target_group
  become: true
  gather_facts: true
  serial: 2
  vars:
    key: value
  vars_files:
    - vars/main.yml

  pre_tasks:
    - name: Something first
      ansible.builtin.debug: { msg: "starting" }

  roles:
    - common

  tasks:
    - name: Do the thing
      ansible.builtin.module_name:
        param: "{{ key }}"
      when: condition
      loop: "{{ some_list }}"
      register: result
      notify: Handler name
      tags: [tag1]

  post_tasks:
    - name: Verify
      ansible.builtin.assert:
        that: result is succeeded

  handlers:
    - name: Handler name
      ansible.builtin.systemd_service:
        name: svc
        state: restarted
```

### The five habits that separate beginners from pros

1. `--check --diff` **before** every production run.
2. `changed_when: false` on every read-only `command`/`shell` task.
3. `validate:` on every config file that has a validator.
4. Restarts live in **handlers**, never in tasks.
5. Run it **twice** — and demand `changed=0` the second time.

---

*Written for ansible-core 2.21 / Ansible 14, July 2026. Verify module options against your installed version with `ansible-doc <module>` — options do change between releases.*
