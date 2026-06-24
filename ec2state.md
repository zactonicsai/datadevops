

The cleanest AWS-native approach is snapshot-based rollback via AMIs and EBS snapshots, paired with dnf's built-in history.

## 1. Snapshot before patching (rollback point)

Create an AMI of the running instance (captures full root + attached volumes):

```bash
aws ec2 create-image \
  --instance-id i-xxxxxxxx \
  --name "rhel-prepatch-$(date +%Y%m%d-%H%M)" \
  --description "Pre-patch baseline" \
  --no-reboot \
  --tag-specifications 'ResourceType=image,Tags=[{Key=Purpose,Value=prepatch}]'
```

Or just snapshot the EBS root volume (faster, lighter):

```bash
aws ec2 create-snapshot \
  --volume-id vol-xxxxxxxx \
  --description "Pre-patch $(date +%F)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Purpose,Value=prepatch}]'
```

`--no-reboot` keeps the instance up but risks filesystem inconsistency. For a clean image, drop it and let it reboot, or run `sync` first.

## 2. Patch with dnf (on the instance)

```bash
sudo dnf upgrade --refresh -y
```

dnf logs every transaction:

```bash
sudo dnf history          # list transactions with IDs
sudo dnf history info 42  # detail on transaction 42
```

## 3. Rollback options

**OS-level (package-only changes), fast:**

```bash
sudo dnf history undo 42      # reverse a specific transaction
sudo dnf history rollback 41  # roll back to state after txn 41
```

This handles dnf changes but NOT config files edited outside dnf, kernel state, or non-package modifications.

**Full instance rollback (when OS rollback isn't enough):**

Launch a new instance from the pre-patch AMI:

```bash
aws ec2 run-instances \
  --image-id ami-xxxxxxxx \
  --instance-type t3.medium \
  --key-name your-key \
  --subnet-id subnet-xxxxxxxx \
  --security-group-ids sg-xxxxxxxx
```

Or detach the current root volume and reattach one restored from the snapshot:

```bash
# Restore volume from snapshot (same AZ as instance)
aws ec2 create-volume \
  --snapshot-id snap-xxxxxxxx \
  --availability-zone us-east-1a \
  --volume-type gp3

# Stop instance, detach current root, attach restored as /dev/xvda
aws ec2 stop-instances --instance-ids i-xxxxxxxx
aws ec2 detach-volume --volume-id vol-current
aws ec2 attach-volume --volume-id vol-restored --instance-id i-xxxxxxxx --device /dev/xvda
aws ec2 start-instances --instance-ids i-xxxxxxxx
```

## Recommended pattern

Snapshot/AMI for guaranteed full rollback (the safety net), `dnf history` for quick package reversions. At scale, drive the patching itself through **AWS Systems Manager Patch Manager**, which orchestrates snapshots, patch baselines, and reporting across fleets rather than per-instance CLI calls.

Want the SSM Patch Manager version instead of manual CLI?
There's no single command for this, since Linux doesn't track "what changed since the base AMI" natively. You reconstruct it from package history, file timestamps, and service state. Here's how.

## 1. Packages added since base (dnf history)

```bash
# Full transaction history — the base AMI build is usually txn 1
sudo dnf history

# What a specific install transaction added
sudo dnf history info 5

# Everything installed after a given date
sudo dnf history list --reverse | awk '$0 ~ /2024-/'
```

For Amazon Linux / RHEL, the AMI's original package set is transaction 1. Everything after is your additions.

## 2. Files newer than the AMI baseline (timestamp diff)

Find a reference file from image creation (e.g. `/etc/machine-id` or the root filesystem creation), then find everything newer:

```bash
# Files modified in the last N days
sudo find / -xdev -type f -mtime -30 2>/dev/null

# Files newer than a known baseline file
sudo find / -xdev -type f -newer /etc/machine-id 2>/dev/null \
  | grep -vE '^/(proc|sys|tmp|var/log|var/cache|run)'
```

`-xdev` keeps it on the root filesystem; the grep strips noise (logs, caches, runtime dirs).

## 3. Files owned by NO package (manually added — configs, app drops)

This is the key one for apps like Kafka/NiFi that install outside the package manager:

```bash
# Walk the filesystem, report files rpm doesn't know about
sudo find /opt /usr/local /etc /var -type f 2>/dev/null | while read f; do
  rpm -qf "$f" &>/dev/null || echo "UNOWNED: $f"
done
```

Kafka and NiFi are typically unpacked tarballs in `/opt/kafka`, `/opt/nifi`, or `/usr/local/`, so they'll show as unowned. Their data dirs (`/var/lib/...`, log dirs) and any systemd unit files you wrote also surface here.

## 4. Services / systemd units added

```bash
# All enabled units (your app services appear here)
systemctl list-unit-files --state=enabled

# Unit files NOT shipped by a package (manually created)
for u in /etc/systemd/system/*.service; do
  rpm -qf "$u" &>/dev/null || echo "CUSTOM UNIT: $u"
done

# Currently listening ports → maps services to network exposure
sudo ss -tlnp
```

Kafka (9092), Zookeeper (2181), NiFi (8080/8443) will show in `ss` output, tying the running process back to its install location.

## 5. RPM verification — what changed in packaged files

For files that *did* come from packages but were modified after install:

```bash
# Flags every packaged file whose size/hash/perms changed (look for lines starting with S, 5, M, etc.)
sudo rpm -Va 2>/dev/null
```

## Practical combined approach

For a tarball app like Kafka or NiFi, the fast path is:

1. `find / -xdev -newer /etc/machine-id` → everything touched since build
2. Filter to `/opt`, `/usr/local`, `/etc`, `/var/lib` → where apps land
3. `systemctl list-unit-files --state=enabled` + `ss -tlnp` → the services and their ports
4. `rpm -qf` loop → confirm what's manual vs packaged

One caveat: timestamp-based detection assumes the clock and mtimes weren't deliberately reset, and `/etc/machine-id` is a decent baseline proxy but not exact. If you need a *precise* diff, the rigorous method is to launch the **original base AMI** alongside your modified instance and compare file manifests:

```bash
# On each instance, generate a sorted manifest, then diff offline
sudo find / -xdev -type f 2>/dev/null | sort > /tmp/manifest.txt
```

`diff base-manifest.txt modified-manifest.txt` gives you the authoritative list of added files.

Want a single script that bundles all of this into one report (added packages + unowned files + custom services + open ports)?
