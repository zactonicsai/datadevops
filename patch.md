# Monthly Golden-AMI Patching Runbook — Amazon Linux 2023

**Audience:** Cloud / Platform Engineering team
**Scope:** Monthly security patching of the AL2023 base AMI, baking a new “golden AMI,” and rolling it out to running fleets (Kafka, NiFi, and others) across Dev → Stage → Prod.
**Tracking:** GitLab (code + pipeline + review) and Jira (work + change approval).

> Read this top to bottom the first time. After that, jump to **Section 6 (The Monthly Checklist)** each cycle.

-----

## 1. Background — what we are actually doing and why

Every server you run started life from an **AMI** (Amazon Machine Image) — a frozen snapshot of a disk. When you launch an EC2 instance, AWS copies that snapshot onto the new server. So the AMI is the *seed*: whatever software and patches are baked into it become the starting point for every instance launched from it.

The problem: an AMI is frozen in time. The moment AWS publishes a base Amazon Linux 2023 image, it starts going out of date as new security patches are released. If your production servers were launched from a base AMI six months ago, they are six months behind on security fixes.

There are two ways to fix that, and **we use both**:

1. **Patch the running servers in place** — log in (or use automation) and apply this month’s patches to servers that already exist. Fast, but the *seed* is still old, so any new server you launch is still behind until it patches itself on boot.
1. **Bake a new golden AMI** — take the newest AWS base AMI, apply our patches and our internal package requirements, test it, and save it as a new approved image. Every future launch starts already-patched. This is the durable fix.

This runbook ties both together into one monthly cycle: **build a fresh golden AMI, prove it works in Dev and Stage, then both (a) update production to launch from it going forward and (b) bring the existing running servers up to the same patch level — including reboots — in a controlled, service-aware way.**

### Key Amazon Linux 2023 concept you must understand first

AL2023 uses **deterministic, versioned repositories**. In plain terms: every AL2023 system is locked to a specific *repository version* that looks like a date stamp, e.g. `2023.4.20240416`. Two servers locked to the same version will receive the **exact same packages** — patching is repeatable and predictable, unlike older systems where “update everything” pulled whatever was newest that day.

This matters enormously for us because it means **Dev, Stage, and Prod can be made byte-for-byte identical** by locking them all to the same repository version. That is the foundation of “verify the patch matches the watch list.” (Confirm current version availability and limits in AWS docs; AWS retires very old repository snapshots over time.)

-----

## 2. The vocabulary (so the whole team uses the same words)

|Term                     |What it means here                                                                                                                 |
|-------------------------|-----------------------------------------------------------------------------------------------------------------------------------|
|**Base AMI**             |The latest official AL2023 image published by AWS. Our raw material.                                                               |
|**Golden AMI**           |Our hardened, patched, internally-approved image baked from the base AMI.                                                          |
|**dnf**                  |The package manager in AL2023 (the engine behind the old `yum` command).                                                           |
|**releasever**           |The repository version lock, e.g. `2023.4.20240416`. Controls exactly which patches a system can see.                              |
|**Watch list / manifest**|The approved, authoritative list of package names + versions that *must* be present after patching. We diff against this to verify.|
|**Versionlock**          |A pin that prevents a specific package from being upgraded (used for packages our apps are picky about).                           |
|**Exclude list**         |Packages we explicitly refuse to install or upgrade.                                                                               |
|**Instance refresh**     |The Auto Scaling Group feature that replaces running instances with ones from the new AMI, a few at a time.                        |
|**Maintenance window**   |The approved time slot when we are allowed to reboot production.                                                                   |

-----

## 3. What lives in GitLab (the source of truth)

Create one repository, e.g. `cloud/golden-ami-al2023`. Everything that defines an image lives here so changes are reviewed and versioned. Suggested layout:

```
golden-ami-al2023/
├── packer/
│   └── al2023-golden.pkr.hcl        # how to build the AMI (Packer)
├── config/
│   ├── packages-add.txt             # packages our org REQUIRES (e.g. CloudWatch agent, corretto)
│   ├── packages-remove.txt          # packages we strip out (unneeded/forbidden)
│   ├── versionlock.list             # exact versions we pin (don't let patches move these)
│   ├── exclude.list                 # packages dnf must never touch
│   └── releasever.txt               # the repo version we are locking this cycle to
├── scripts/
│   ├── apply-patches.sh             # runs inside the builder instance
│   └── capture-manifest.sh          # produces the "what's installed" manifest
├── manifests/
│   ├── approved-watchlist.txt       # THE watch list we verify against
│   └── 2026-06-built.txt            # the manifest produced by this month's build
├── .gitlab-ci.yml                   # the pipeline (build → test → promote)
└── README.md
```

**The review artifact** each month is the **diff** between last month’s manifest and this month’s. That diff is what reviewers approve in the Merge Request, and it’s what you attach to the Jira change ticket.

-----

## 4. What lives in Jira (the work + approval trail)

Mirror the GitLab work in Jira so auditors and managers can see status without reading code.

- **Epic** (one per month): `Monthly Patching — June 2026` → key like `PATCH-100`.
- **Stories** under the epic:
  - `PATCH-101` Build June golden AMI
  - `PATCH-102` Validate in Dev
  - `PATCH-103` Validate in Stage
  - `PATCH-104` Production rollout (Kafka)
  - `PATCH-105` Production rollout (NiFi)
- **Change request** (separate, requires approval before prod): `CHG-2026-06` linked to `PATCH-104/105`. This holds the approved maintenance window and the manifest diff.

**Link the two systems** by putting the Jira key in every Git commit and branch:

```bash
git checkout -b patch/2026-06-PATCH-101
git commit -m "PATCH-101: lock releasever to 2023.x.2026MMDD, add corretto17"
```

If your GitLab↔Jira integration is on, the commit and MR automatically appear on the Jira ticket. Move tickets through `To Do → In Progress → In Review → Done` as each phase completes.

-----

## 5. Defining “internal requirements” — add, remove, and the watch list

This is the heart of “remove or add patches to the latest AL2023 base.” You are shaping the base image to your org’s standard.

### 5a. Packages we ADD (`config/packages-add.txt`)

Things every server must have. Example contents:

```
amazon-cloudwatch-agent
amazon-ssm-agent
java-17-amazon-corretto-headless
chrony
audit
```

> Kafka and NiFi run on the JVM, so the **Amazon Corretto** version is critical — pinning it is usually required (see versionlock below).

### 5b. Packages we REMOVE (`config/packages-remove.txt`)

Things we strip to reduce attack surface or because policy forbids them:

```
telnet
rsh
ftp
```

### 5c. Packages we PIN (`config/versionlock.list`)

Some apps break if a dependency jumps versions. Pin those so monthly patches leave them alone:

```
java-17-amazon-corretto-headless-1:17.0.11+9-1.amzn2023
```

### 5d. Packages dnf must NEVER touch (`config/exclude.list`)

```
kernel-headers
```

### 5e. The watch list (`manifests/approved-watchlist.txt`)

This is the authoritative answer to “what should be installed and at what version.” It is generated from a known-good build, reviewed, and committed. Every later verification compares the live server against this file. You regenerate and re-approve it each cycle once the new build passes Stage.

-----

## 6. THE MONTHLY CHECKLIST (the flow, end to end)

Below is the full cycle. Each phase has the commands and the GitLab/Jira action.

```
Phase 0  Intake          → open Jira epic + branch
Phase 1  Get base AMI     → find newest AL2023 image
Phase 2  Build builder    → launch a temp instance from base AMI
Phase 3  Patch + shape    → apply security patches, add/remove/pin packages
Phase 4  Capture + diff   → manifest the result, diff vs last month
Phase 5  Bake             → create the golden AMI, tag it
Phase 6  Dev              → deploy, verify against watch list
Phase 7  Stage            → deploy, verify, soak test
Phase 8  Approve          → freeze watch list, get CHG approval
Phase 9  Prod (in place)  → patch + rolling reboot Kafka/NiFi
Phase 10 Prod (forward)   → point launch templates/ASGs at new AMI
Phase 11 Close            → verify fleet, close Jira, merge MR
```

-----

### Phase 0 — Intake

```bash
# In GitLab repo
git checkout main && git pull
git checkout -b patch/2026-06-PATCH-101
```

In Jira: create the epic and stories from Section 4. Set `PATCH-101` to **In Progress**.

-----

### Phase 1 — Find the newest AL2023 base AMI

AWS publishes the latest AMI ID in SSM Parameter Store, so you never have to guess or hardcode an ID that will go stale:

```bash
# x86_64 default kernel (use the arm64 path for Graviton)
aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text
# → ami-0abc123... (this month's base)

# See ALL the published AL2023 parameters (minimal, arm64, etc.)
aws ssm get-parameters-by-path \
  --path /aws/service/ami-amazon-linux-latest \
  --query 'Parameters[].Name' --output text
```

Record the returned AMI ID in the Jira story and in your build notes.

-----

### Phase 2 — Launch a builder instance from the base AMI

You can do this manually for transparency (shown here), or with Packer/EC2 Image Builder (Section 8). Manual first so you understand every step.

```bash
BASE_AMI=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)

aws ec2 run-instances \
  --image-id "$BASE_AMI" \
  --instance-type t3.medium \
  --key-name cloud-team-build \
  --security-group-ids sg-0buildonly \
  --subnet-id subnet-0build \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ami-builder-2026-06},{Key=Purpose,Value=golden-ami}]' \
  --query 'Instances[0].InstanceId' --output text
# → i-0builder123

# Then connect (SSM Session Manager is preferred — no SSH keys/ports needed)
aws ssm start-session --target i-0builder123
```

-----

### Phase 3 — Patch and shape the image (`scripts/apply-patches.sh`)

This is where you apply security patches AND your add/remove/pin rules. Run it on the builder instance.

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1) Lock to the exact repo version we approved for this cycle (deterministic!)
RELEASEVER="$(cat /tmp/releasever.txt)"   # e.g. 2023.x.2026MMDD
echo "Locking to releasever=$RELEASEVER"

# 2) Refresh metadata for that version
sudo dnf --releasever="$RELEASEVER" clean all
sudo dnf --releasever="$RELEASEVER" makecache

# 3) See what security work is pending (the per-image diff)
sudo dnf --releasever="$RELEASEVER" updateinfo summary --security

# 4) Apply ONLY security updates, honoring our exclude list
EXCLUDES=$(paste -sd, /tmp/exclude.list)
sudo dnf --releasever="$RELEASEVER" upgrade --security -y \
  ${EXCLUDES:+--exclude="$EXCLUDES"}

# 5) Add required packages
sudo dnf --releasever="$RELEASEVER" install -y $(grep -vE '^\s*#|^\s*$' /tmp/packages-add.txt)

# 6) Remove forbidden packages
sudo dnf remove -y $(grep -vE '^\s*#|^\s*$' /tmp/packages-remove.txt) || true

# 7) Apply version pins so future patches won't move them
sudo dnf install -y python3-dnf-plugin-versionlock
sudo dnf versionlock clear
while read -r pkg; do
  [[ "$pkg" =~ ^\s*# || -z "$pkg" ]] && continue
  sudo dnf versionlock add "$pkg"
done < /tmp/versionlock.list

echo "Patching + shaping complete."
```

**What each `dnf` piece does, in plain terms:**

- `--releasever=...` → “only look at this exact frozen repo version.” This is the AL2023 determinism lever.
- `updateinfo summary --security` → counts the security fixes waiting (Critical/Important/etc.).
- `upgrade --security` → installs *only* security-flagged updates, not every cosmetic update.
- `--exclude=` → skip packages on our exclude list.
- `versionlock add` → pin a package so next month’s run can’t bump it.

Copy the config files up before running:

```bash
# from your laptop / CI runner
for f in releasever.txt exclude.list packages-add.txt packages-remove.txt versionlock.list; do
  aws ssm send-command --document-name AWS-RunShellScript \
    --targets "Key=InstanceIds,Values=i-0builder123" \
    --parameters "commands=[\"echo placeholder\"]" >/dev/null   # (or use S3/scp to deliver files)
done
```

*(In practice you bake the config files into the Packer build or pull them from S3/GitLab; the line above is illustrative.)*

-----

### Phase 4 — Capture the manifest and DIFF it (`scripts/capture-manifest.sh`)

This produces the exact list of what is installed — your evidence and your comparison key.

```bash
#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-/tmp/manifest.txt}"

# Full package inventory: name-version-release.arch, sorted for stable diffs
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "$OUT"

echo "=== Manifest written to $OUT ==="
echo "Kernel:      $(uname -r)"
echo "Releasever:  $(cat /etc/dnf/vars/releasever 2>/dev/null || rpm -E %{amzn})"
echo "Corretto:    $(rpm -q java-17-amazon-corretto-headless 2>/dev/null || echo 'not installed')"
echo "Versionlock:"; dnf versionlock list 2>/dev/null || true
```

Pull the manifest off the builder and diff it against last month’s:

```bash
# Compare last month vs this month — THIS is the MR review artifact
diff manifests/2026-05-built.txt manifests/2026-06-built.txt

# Friendlier side-by-side
diff -y --suppress-common-lines \
  manifests/2026-05-built.txt manifests/2026-06-built.txt

# Just the security packages that changed
sudo dnf --releasever="$RELEASEVER" updateinfo list --security > manifests/2026-06-security.txt
```

Commit the new manifest and open the Merge Request:

```bash
cp /tmp/manifest.txt manifests/2026-06-built.txt
git add manifests/ config/
git commit -m "PATCH-101: June build — security upgrades + corretto pin (see manifest diff)"
git push -u origin patch/2026-06-PATCH-101
```

Open the MR in GitLab, paste the `diff` output into the description, and request review. Reviewers approve the **package delta**, not vibes.

-----

### Phase 5 — Bake the golden AMI

Once the manifest looks right, turn the builder into an image. Clean it first so the image is generic and safe.

```bash
# On the builder: remove host-specific state before imaging
sudo dnf clean all
sudo rm -rf /var/lib/cloud/instances/*        # let cloud-init re-init on next boot
sudo rm -f /etc/ssh/ssh_host_*                # regenerate host keys per instance
sudo rm -f /home/ec2-user/.ssh/authorized_keys 2>/dev/null || true
history -c 2>/dev/null || true
```

```bash
# From your laptop / CI: create the image
aws ec2 create-image \
  --instance-id i-0builder123 \
  --name "al2023-golden-2026-06" \
  --description "AL2023 golden, releasever 2023.x.2026MMDD, security + corretto17" \
  --tag-specifications \
    'ResourceType=image,Tags=[{Key=Cycle,Value=2026-06},{Key=Releasever,Value=2023.x.2026MMDD},{Key=Status,Value=untested},{Key=Jira,Value=PATCH-101}]' \
  --query 'ImageId' --output text
# → ami-0golden202606

# Wait until it's ready
aws ec2 wait image-available --image-ids ami-0golden202606

# Terminate the builder — you don't need it anymore
aws ec2 terminate-instances --instance-ids i-0builder123
```

The `Status=untested` tag is your guardrail: nothing in Stage/Prod consumes an AMI tagged untested.

-----

### Phase 6 — Deploy to Dev and verify against the watch list

Launch a Dev instance from the new AMI (or run an ASG instance refresh in Dev — see Phase 10).

```bash
aws ec2 run-instances \
  --image-id ami-0golden202606 \
  --instance-type t3.large \
  --subnet-id subnet-0dev \
  --security-group-ids sg-0dev \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=dev-kafka-golden-test},{Key=Env,Value=dev}]' \
  --query 'Instances[0].InstanceId' --output text
```

**Verification — does the live server match the watch list?** This is the “verify the patch matches what was in place” step.

```bash
# On the Dev instance, regenerate its live manifest
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > /tmp/live.txt

# Compare against the approved watch list. EMPTY diff = perfect match.
diff manifests/approved-watchlist.txt /tmp/live.txt && echo "MATCH ✔"

# Spot-check the things that matter most
rpm -q kernel openssl java-17-amazon-corretto-headless
uname -r
dnf versionlock list
needs-restarting -r        # confirms whether a reboot is pending
systemctl --failed         # nothing should be failed
```

Now confirm the **applications actually start** on the new image:

```bash
# Kafka broker comes up and registers
sudo systemctl status kafka
# (or your unit name) — then confirm it joined:
kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null && echo "Kafka OK"

# NiFi comes up
sudo systemctl status nifi
curl -sk https://localhost:8443/nifi-api/system-diagnostics >/dev/null && echo "NiFi OK"
```

Update Jira `PATCH-102` to **Done** with the diff result pasted in.

-----

### Phase 7 — Promote to Stage and soak

Stage should mirror production topology (same instance types, same cluster size). Repeat the Phase 6 verification, then **soak**: leave it running under realistic load for an agreed period (e.g. 24–48h) watching dashboards, GC behavior on the JVM, and error rates. Kafka and NiFi problems from a patch (JVM, TLS, file-descriptor limits) usually surface under load, not at boot.

When Stage passes, retag the AMI:

```bash
aws ec2 create-tags --resources ami-0golden202606 \
  --tags Key=Status,Value=approved
```

Set `PATCH-103` to **Done**.

-----

### Phase 8 — Freeze the watch list and get change approval

Now that Stage is proven, **this build becomes the new authority**:

```bash
# Promote the proven Stage manifest to the approved watch list
cp manifests/2026-06-built.txt manifests/approved-watchlist.txt
git add manifests/approved-watchlist.txt
git commit -m "PATCH-101: promote June build to approved watch list"
git push
```

In Jira, complete the **CHG-2026-06** change request: attach the manifest diff, the AMI ID, the rollback plan (Section 11), and the approved **maintenance window**. Get the required approvals **before** touching production. Do not proceed to Phase 9 without an approved change.

-----

### Phase 9 — Production: patch existing servers and reboot (service-aware)

This brings the **already-running** Kafka/NiFi servers up to the new patch level. Because these are stateful clustered systems, **never reboot them all at once**. Go one node at a time and verify cluster health between each.

#### Option A — Patch in place to the exact same releasever (keeps hosts, matches the watch list)

This is usually preferred for stateful clusters because it avoids replacing the node’s storage.

```bash
# Apply the SAME security patches, locked to the SAME version as the golden AMI
sudo dnf --releasever=2023.x.2026MMDD upgrade --security -y
needs-restarting -r        # tells you if a reboot is required (kernel/glibc updates need it)
```

#### Kafka — rolling restart procedure (one broker at a time)

```bash
# 0) Before starting, the cluster must be HEALTHY:
kafka-topics.sh --bootstrap-server broker1:9092 \
  --describe --under-replicated-partitions
# → MUST return nothing (zero under-replicated partitions)

# --- For EACH broker, in turn ---

# 1) (Optional but recommended) move leadership off this broker first,
#    or rely on graceful shutdown to do controlled leader migration.

# 2) Patch + reboot the single broker
sudo dnf --releasever=2023.x.2026MMDD upgrade --security -y
sudo reboot

# 3) After it returns, wait until it's fully back in sync BEFORE moving on:
kafka-topics.sh --bootstrap-server broker1:9092 \
  --describe --under-replicated-partitions          # must be empty again
# Also confirm the broker re-registered and ISR is full for its partitions.

# 4) Only then proceed to the next broker.
```

> Golden rules for Kafka: under-replicated partitions must return to **0** before you touch the next broker; never take down more brokers simultaneously than your replication factor can tolerate (with RF=3 / min.insync.replicas=2, that’s one at a time). Verify the **active controller** moved cleanly if you reboot the controller broker.

#### NiFi — rolling restart procedure (one node at a time)

```bash
# --- For EACH NiFi node, in turn ---

# 1) Disconnect the node from the cluster (via UI cluster menu or REST):
curl -sk -X PUT https://nifi-node1:8443/nifi-api/controller/cluster/nodes/<nodeId> \
  -H 'Content-Type: application/json' \
  -d '{"node":{"nodeId":"<nodeId>","status":"DISCONNECTING"}}'

# 2) OFFLOAD it so its queued flowfiles redistribute to the remaining nodes:
curl -sk -X PUT https://nifi-node1:8443/nifi-api/controller/cluster/nodes/<nodeId> \
  -H 'Content-Type: application/json' \
  -d '{"node":{"nodeId":"<nodeId>","status":"OFFLOADING"}}'
# Wait until offload completes (queues drained).

# 3) Stop NiFi gracefully, patch, reboot:
sudo systemctl stop nifi
sudo dnf --releasever=2023.x.2026MMDD upgrade --security -y
sudo reboot

# 4) After boot, NiFi restarts and rejoins. Confirm it's CONNECTED and the
#    cluster shows the full node count before moving to the next node.
curl -sk https://nifi-node1:8443/nifi-api/controller/cluster | jq '.cluster.nodes[].status'
```

> Golden rules for NiFi: always **offload** before stopping so in-flight data isn’t stranded on a down node; keep the **cluster coordinator / primary node** in mind (reboot it last, or let NiFi re-elect); ensure each node returns to **CONNECTED** before the next.

#### “Others” (stateless web/app tiers)

For stateless fleets behind a load balancer, the in-place dance isn’t necessary — prefer the **forward** method (Phase 10) and let the ASG replace instances a few at a time.

Set `PATCH-104`/`PATCH-105` to **Done** as each cluster finishes.

-----

### Phase 10 — Production: point future launches at the new golden AMI

So that *new* instances are born patched, update the Launch Template and let the Auto Scaling Group refresh.

```bash
# 1) Create a new Launch Template version using the approved AMI
aws ec2 create-launch-template-version \
  --launch-template-id lt-0prodkafka \
  --source-version '$Latest' \
  --launch-template-data '{"ImageId":"ami-0golden202606"}' \
  --query 'LaunchTemplateVersion.VersionNumber' --output text

# 2) Make that version the default
aws ec2 modify-launch-template \
  --launch-template-id lt-0prodkafka \
  --default-version <newVersionNumber>

# 3) Roll the ASG to the new AMI a few instances at a time, keeping capacity up.
#    MinHealthyPercentage keeps most of the cluster serving during the refresh.
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name prod-kafka-asg \
  --preferences '{"MinHealthyPercentage":90,"InstanceWarmup":300}'

# 4) Watch progress
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name prod-kafka-asg \
  --query 'InstanceRefreshes[0].{Status:Status,Pct:PercentageComplete}'
```

> For Kafka/NiFi, an automated instance refresh **replaces the whole node** (and its storage unless using durable/EBS-backed data with proper detach/reattach). For stateful brokers, many teams keep data on separate EBS volumes or use in-place patching (Phase 9, Option A) instead of refresh. Choose per service and document the choice in the MR.

-----

### Phase 11 — Verify the whole fleet and close out

Run a fleet-wide compliance check, then close the paperwork.

```bash
# Fleet-wide: scan against your patch baseline via Systems Manager
aws ssm send-command \
  --document-name AWS-RunPatchBaseline \
  --targets "Key=tag:PatchGroup,Values=prod-al2023" \
  --parameters "Operation=Scan"

# Compliance summary across the patch group
aws ssm describe-patch-group-state --patch-group prod-al2023
# Look for InstancesWithInstalledPendingReboot = 0 and high Compliant count

# Per-instance proof that it matches the watch list (repeat on a sample of nodes)
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > /tmp/live.txt
diff manifests/approved-watchlist.txt /tmp/live.txt && echo "FLEET NODE MATCH ✔"
```

Then:

- Merge the GitLab MR into `main` (tag it, e.g. `git tag golden-2026-06 && git push --tags`).
- Move the Jira epic and all stories to **Done**; mark **CHG-2026-06** as implemented.
- Tag last month’s AMI for retirement so it can be deregistered later: `Status=retired`.

-----

## 7. Verifying “the patch matches the watch list” — the mental model

The watch list (`approved-watchlist.txt`) is the single source of truth for *what should be installed*. Verification is always the same move, whether on a freshly-baked AMI, a Dev box, or a production broker:

```bash
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > /tmp/live.txt
diff manifests/approved-watchlist.txt /tmp/live.txt
```

- **Empty output = exact match.** The server is exactly what was approved.
- **Lines starting with `<`** = on the watch list but *missing* from the server (patch didn’t apply, or package removed).
- **Lines starting with `>`** = on the server but *not* on the watch list (drift — something extra got installed).

Because every system is locked to the same `releasever`, a clean diff is achievable and meaningful. Run this verification on a sample of nodes per cluster every cycle and attach the result to Jira as evidence.

-----

## 8. Automating the build — Packer and EC2 Image Builder

The manual Phase 2–5 flow is great for learning and one-offs. For repeatability, automate it. Two common choices:

### Packer (HashiCorp) — `packer/al2023-golden.pkr.hcl`

```hcl
packer {
  required_plugins {
    amazon = { source = "github.com/hashicorp/amazon", version = ">= 1.2.0" }
  }
}

variable "releasever" { type = string }   # e.g. "2023.x.2026MMDD"
variable "cycle"      { type = string }   # e.g. "2026-06"

data "amazon-ami" "al2023" {
  filters = {
    name                = "al2023-ami-2023.*-x86_64"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }
  owners      = ["amazon"]
  most_recent = true
  region      = "us-east-1"
}

source "amazon-ebs" "golden" {
  region        = "us-east-1"
  instance_type = "t3.medium"
  source_ami    = data.amazon-ami.al2023.id
  ssh_username  = "ec2-user"
  ami_name      = "al2023-golden-${var.cycle}"
  tags = {
    Cycle      = var.cycle
    Releasever = var.releasever
    Status     = "untested"
  }
}

build {
  sources = ["source.amazon-ebs.golden"]

  # ship config files into the builder
  provisioner "file" { source = "config/", destination = "/tmp/config" }

  # run the same patch+shape logic from Phase 3
  provisioner "shell" {
    environment_vars = ["RELEASEVER=${var.releasever}"]
    script           = "scripts/apply-patches.sh"
  }

  # capture the manifest as a build artifact
  provisioner "shell"             { script = "scripts/capture-manifest.sh" }
  provisioner "file" {
    direction   = "download"
    source      = "/tmp/manifest.txt"
    destination = "manifests/${var.cycle}-built.txt"
  }
}
```

Run it:

```bash
packer init packer/
packer validate -var "releasever=2023.x.2026MMDD" -var "cycle=2026-06" packer/
packer build  -var "releasever=2023.x.2026MMDD" -var "cycle=2026-06" packer/
```

### EC2 Image Builder (AWS-native alternative)

If you prefer staying inside AWS: define an **Image Recipe** (base = the AL2023 SSM parameter + your components for patch/add/remove), an **Infrastructure Configuration**, and a **Distribution Configuration**, then trigger the **Image Pipeline**. It produces a tagged AMI on a schedule (e.g. monthly) and can run validation/test components automatically. Either tool fits this runbook — keep the recipe/template in the same GitLab repo so it’s reviewed.

-----

## 9. The GitLab CI/CD pipeline — `.gitlab-ci.yml`

This wires the phases together with a **manual gate** before production.

```yaml
stages: [validate, build, test-dev, test-stage, approve, deploy-prod]

variables:
  CYCLE: "2026-06"
  RELEASEVER: "2023.x.2026MMDD"
  AWS_DEFAULT_REGION: "us-east-1"

validate:
  stage: validate
  script:
    - packer init packer/
    - packer validate -var "releasever=$RELEASEVER" -var "cycle=$CYCLE" packer/
    - echo "Config files present:" && ls -l config/

build-ami:
  stage: build
  script:
    - packer build -var "releasever=$RELEASEVER" -var "cycle=$CYCLE" packer/
    # capture the new AMI id into a file for later stages
    - aws ec2 describe-images --owners self
        --filters "Name=name,Values=al2023-golden-$CYCLE"
        --query 'Images[0].ImageId' --output text > ami_id.txt
  artifacts:
    paths: [ami_id.txt, manifests/]

test-dev:
  stage: test-dev
  script:
    - AMI=$(cat ami_id.txt)
    - ./scripts/deploy-and-verify.sh dev "$AMI"   # launches + diffs vs watch list
    # fail the job if diff is non-empty or apps don't start

test-stage:
  stage: test-stage
  script:
    - AMI=$(cat ami_id.txt)
    - ./scripts/deploy-and-verify.sh stage "$AMI"
    - ./scripts/soak.sh stage 86400               # 24h soak, watch metrics
    - aws ec2 create-tags --resources "$AMI" --tags Key=Status,Value=approved

approve-prod:
  stage: approve
  script: [ "echo 'CHG approved? proceeding.'" ]
  when: manual          # <-- human gate; only runs after Jira CHG is approved
  allow_failure: false

deploy-prod:
  stage: deploy-prod
  needs: ["approve-prod"]
  script:
    - AMI=$(cat ami_id.txt)
    - ./scripts/rolling-kafka.sh "$AMI"   # one broker at a time, checks URP=0
    - ./scripts/rolling-nifi.sh  "$AMI"   # offload → stop → patch → reboot → rejoin
    - ./scripts/point-launch-templates.sh "$AMI"
  when: manual
  environment: { name: production }
```

The `when: manual` gates make sure a human (with an approved Jira `CHG`) clicks **Play** before anything production happens — the pipeline can’t silently roll prod on its own.

-----

## 10. Roles and cadence (who does what, when)

|Day of month|Activity                                                  |Owner                   |
|------------|----------------------------------------------------------|------------------------|
|1–2         |Open epic, fetch base AMI, build + manifest (Phases 0–5)  |Build engineer          |
|3–5         |Dev verify + Stage soak (Phases 6–7)                      |Build engineer + QA     |
|6           |Freeze watch list, raise CHG, get approval (Phase 8)      |Team lead               |
|7–8         |Production rolling patch + reboot, point LTs (Phases 9–10)|On-call + service owners|
|9           |Fleet verify, close out (Phase 11)                        |Team lead               |


> Always do the *out-of-band* (critical zero-day) patches off-cycle using the same Phase 9 rolling procedure — don’t wait for month-end if a Critical CVE drops.

-----

## 11. Rollback — the safety net

Always have a way back before you touch prod.

```bash
# BEFORE prod work: snapshot/image the current good state of a node
aws ec2 create-image --instance-id i-0prodbroker \
  --name "pre-patch-2026-06-$(date +%Y%m%d)" --no-reboot

# If a patch breaks a single in-place node, roll back its packages:
sudo dnf history            # find the transaction id
sudo dnf history undo <id>  # reverse just that transaction
sudo reboot

# If the new AMI is bad, revert the Launch Template to the prior version...
aws ec2 modify-launch-template --launch-template-id lt-0prodkafka \
  --default-version <previousVersion>
# ...then instance-refresh back to the known-good AMI
aws autoscaling start-instance-refresh --auto-scaling-group-name prod-kafka-asg
```

-----

## 12. Limits, gotchas, and rules of thumb

- **Reboots aren’t automatic.** `dnf upgrade --security` *installs* kernel/glibc fixes, but they don’t take effect until reboot. A node can read “patched” yet still run the vulnerable kernel. Always check `needs-restarting -r` and reboot during the window.
- **`--security` depends on AWS metadata.** If a fix isn’t flagged as security, the `--security` filter skips it. Periodically run a full `dnf upgrade` review (in Dev) to catch non-security but important fixes.
- **Old releasever snapshots age out.** AWS retires very old repository versions over time. Don’t pin a fleet to an ancient `releasever` forever; move forward each cycle. (Verify current retention in AWS docs.)
- **Versionlock silently blocks patches.** If Corretto (or anything) is pinned, security updates to it won’t apply. Each cycle, consciously review `versionlock.list` — is the pin still justified?
- **Stateful clusters ≠ instance refresh by default.** Replacing a Kafka broker or NiFi node also replaces its disk. Keep broker/repo data on separate durable volumes, or use in-place patching (Phase 9A) for stateful nodes; reserve instance refresh for stateless tiers.
- **Never break the quorum.** Reboot Kafka brokers / NiFi nodes strictly one at a time; verify health (URP=0 for Kafka, CONNECTED for NiFi) before the next. Watch ZooKeeper/KRaft controller health if applicable.
- **SSM prerequisites.** Fleet patching/verification via Systems Manager needs the **SSM Agent running** (it’s pre-installed on AL2023) *and* an **IAM instance role** with SSM permissions. No role = no remote patching.
- **Test the JVM, not just the OS.** Most Kafka/NiFi patch breakages come from Java, TLS libraries, or file-descriptor/ulimit changes — which is why the **Stage soak under load** matters more than a clean boot.
- **One change at a time.** Don’t combine OS patching with app-version upgrades or config changes in the same window; if something breaks you won’t know which change did it.

-----

### Quick command reference

```bash
# Find latest base AMI
aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query 'Parameters[0].Value' --output text

# Patch to an exact version (deterministic)
sudo dnf --releasever=2023.x.2026MMDD upgrade --security -y

# Manifest a host
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > live.txt

# Verify vs watch list (empty = match)
diff manifests/approved-watchlist.txt live.txt

# Reboot needed?
needs-restarting -r

# Kafka health gate
kafka-topics.sh --bootstrap-server localhost:9092 --describe --under-replicated-partitions

# Bake AMI
aws ec2 create-image --instance-id i-xxx --name al2023-golden-2026-06 --no-reboot

# Roll an ASG to a new AMI
aws autoscaling start-instance-refresh --auto-scaling-group-name prod-kafka-asg --preferences '{"MinHealthyPercentage":90}'
```