# Best-Practice Guide: Scaling Disk Space for Auto Scaling Group Workloads

**Audience:** Platform / infrastructure teams supporting application teams that periodically need more disk space for new releases, larger artifacts, growing caches, or expanding datasets.

**Goal:** Give app teams a safe, repeatable, low-friction way to increase per-instance disk capacity in an Auto Scaling Group (ASG) — without data loss, without rebuilding AMIs for every bump, and without downtime.

---

## TL;DR recommendations

1. **Use EBS, not instance store, for anything that needs to grow.** EBS volumes can be resized live; instance store cannot be resized at all.
2. **Put growth in the Launch Template, not the AMI.** Parameterize the volume size so bumping capacity is a one-line change plus an instance refresh — no AMI rebake.
3. **Separate the OS from application data.** Keep a modest root volume; put artifacts/data on a dedicated EBS data volume with its own filesystem. This makes resizing safe and isolates app growth from the OS.
4. **Automate filesystem growth at boot** with `growpart` + `resize2fs`/`xfs_growfs` so new instances automatically use the full requested size.
5. **Prefer `gp3`** for predictable cost and independently tunable IOPS/throughput.
6. **Roll out with an instance refresh** using health checks and warmup so capacity changes are zero-downtime.

---

## Why EBS over instance store (the core decision)

| Dimension | EBS (recommended) | Instance store (ephemeral) |
|-----------|-------------------|----------------------------|
| Resizable | Yes — live, no downtime (Elastic Volumes) | No — fixed by instance type |
| Persistence | Survives stop/start, termination optional | Wiped on stop, terminate, or hardware failure |
| Increase capacity | Change one number, refresh | Must move to a larger-storage instance type |
| Snapshots/backup | Native EBS snapshots | None |
| Cost model | Pay per GB-month provisioned | Bundled into instance price |
| Best for | App data, artifacts, anything that grows | Pure scratch/cache you can lose |

For teams whose disk needs **increase over time with releases**, EBS is the correct foundation. The rest of this guide assumes EBS.

---

## Architecture pattern

```
┌─────────────────────── EC2 Instance (from ASG) ───────────────────────┐
│                                                                        │
│  /dev/xvda (or nvme0n1)   Root volume   — OS + runtime  (e.g. 20 GB)   │
│      └── /                                                              │
│                                                                        │
│  /dev/xvdf (or nvme1n1)   Data volume   — app artifacts (e.g. 100 GB)  │
│      └── /data            resizable independently of the OS            │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

App teams request more `/data` by bumping the data-volume size in the Launch Template. The OS volume is left alone.

---

## Method comparison: how to give teams "more disk"

There are four viable methods. Recommendation: **Method A as the default**, Method B for reactive/urgent growth on live instances, Method C when you want teams to self-serve without touching infra code, and Method D only for pure scratch.

### Method A — Parameterized data volume in the Launch Template (recommended default)

Bump the data-volume size in the launch template, publish a new version, and roll it out with an instance refresh. Filesystem auto-grows at boot.

**Pros**
- Declarative and version-controlled; every size change is auditable.
- Zero-downtime via instance refresh.
- New instances always launch at the correct size — no drift.
- No AMI rebuild required.

**Cons**
- New instances are replaced to pick up the size (that's the point, but it's a rollout, not instant).
- Requires the boot-time grow script to be baked into the AMI or user data.

### Method B — Live resize of existing volumes (Elastic Volumes)

Use `modify-volume` to grow the EBS volume attached to a running instance, then grow the filesystem in place — no reboot, no replacement.

**Pros**
- Immediate relief for an instance that's filling up **right now**.
- No instance replacement, no downtime, connections preserved.

**Cons**
- Operates on individual live instances; not the source of truth. **Always also update the Launch Template** or the next scaled instance reverts to the old size.
- A volume can only be modified once every 6 hours.
- More manual; scripting across the fleet is on you.

### Method C — Self-service via a Launch Template parameter / SSM parameter

Expose the size as an SSM Parameter Store value (or IaC variable) that app teams can change through a controlled pipeline, decoupling "request more disk" from editing infra directly.

**Pros**
- App teams self-serve within guardrails; platform team sets min/max.
- Clean audit trail; integrates with CI/CD and change control.

**Cons**
- Requires plumbing (pipeline, validation, and an instance refresh trigger).
- Slightly more upfront engineering.

### Method D — Larger instance type with more instance store (scratch only)

Move to an instance type with bigger local NVMe. Only appropriate for disposable scratch data.

**Pros**
- Very high throughput/IOPS from local NVMe.
- No per-GB EBS charge.

**Cons**
- **Not resizable**; data is **lost** on every replacement — unsuitable for release artifacts you keep.
- Capacity is quantized to instance types.

---

## Implementation

The following shows the recommended pattern end-to-end. It uses a `gp3` data volume mounted at `/data`, auto-grown at boot.

### Step 1 — Boot-time filesystem growth (bake into AMI or user data)

New instances get a raw or under-sized filesystem; this makes them use the full provisioned size automatically. Works for a fresh data volume and for one restored from a snapshot.

`userdata.sh`:

```bash
#!/bin/bash
set -euo pipefail

DATA_DEVICE_CANDIDATES=("/dev/nvme1n1" "/dev/xvdf")
MOUNT_POINT="/data"
FSTYPE="xfs"   # or ext4

# Find the attached data device (name differs by Nitro vs Xen).
DATA_DEVICE=""
for dev in "${DATA_DEVICE_CANDIDATES[@]}"; do
  if [ -b "$dev" ]; then DATA_DEVICE="$dev"; break; fi
done
[ -n "$DATA_DEVICE" ] || { echo "No data device found"; exit 1; }

mkdir -p "$MOUNT_POINT"

# Create filesystem only if the device has none (first launch, empty volume).
if ! blkid "$DATA_DEVICE" >/dev/null 2>&1; then
  mkfs -t "$FSTYPE" "$DATA_DEVICE"
fi

mount "$DATA_DEVICE" "$MOUNT_POINT"

# Grow the filesystem to fill the (possibly enlarged) volume.
if [ "$FSTYPE" = "xfs" ]; then
  xfs_growfs "$MOUNT_POINT"
else
  resize2fs "$DATA_DEVICE"
fi

# Persist mount across reboots; nofail prevents boot hangs if the volume is absent.
grep -q "$MOUNT_POINT" /etc/fstab || \
  echo "$DATA_DEVICE $MOUNT_POINT $FSTYPE defaults,nofail 0 2" >> /etc/fstab

echo "Data volume ready at $MOUNT_POINT"
```

> If the data volume is partitioned (e.g. `/dev/nvme1n1p1`) rather than raw, add `growpart /dev/nvme1n1 1` before the filesystem grow, and target the partition in `mkfs`/`resize2fs`. The example above uses a whole raw device, which is simplest for a dedicated data volume.

### Step 2 — Create the Launch Template with a sized data volume

The data volume size is the single value teams change to get more disk.

#### CLI

Put the launch template data in a file to keep things readable:

`lt-data.json`:

```json
{
  "ImageId": "ami-0abcd1234example",
  "InstanceType": "m6i.large",
  "BlockDeviceMappings": [
    {
      "DeviceName": "/dev/xvda",
      "Ebs": { "VolumeSize": 20, "VolumeType": "gp3", "DeleteOnTermination": true }
    },
    {
      "DeviceName": "/dev/xvdf",
      "Ebs": {
        "VolumeSize": 100,
        "VolumeType": "gp3",
        "Iops": 3000,
        "Throughput": 125,
        "DeleteOnTermination": true,
        "Encrypted": true
      }
    }
  ]
}
```

```bash
# Encode user data
USERDATA_B64=$(base64 -w0 userdata.sh)

# Create the template (inject user data into the JSON)
aws ec2 create-launch-template \
  --launch-template-name app-team-lt \
  --version-description "baseline: 100GB /data" \
  --launch-template-data "$(jq --arg ud "$USERDATA_B64" '. + {UserData:$ud}' lt-data.json)"
```

#### Console

1. **EC2 → Launch Templates → Create launch template.**
2. Name it `app-team-lt`.
3. Under **AMI** and **Instance type**, choose your baseline.
4. Under **Storage (Volumes)**:
   - Volume 1 (root): `/dev/xvda`, `gp3`, e.g. 20 GiB.
   - Click **Add new volume** → set device name `/dev/xvdf`, type `gp3`, size **100 GiB**, IOPS 3000, throughput 125, **Encrypted: Yes**, Delete on termination as desired.
5. Expand **Advanced details → User data** and paste `userdata.sh`.
6. **Create launch template.**

### Step 3 — Attach the Launch Template to the ASG

#### CLI

```bash
# New ASG
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name app-team-asg \
  --launch-template "LaunchTemplateName=app-team-lt,Version=\$Latest" \
  --min-size 2 --max-size 10 --desired-capacity 2 \
  --health-check-type ELB --health-check-grace-period 300 \
  --vpc-zone-identifier "subnet-aaa,subnet-bbb"

# Existing ASG — point at the template
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name app-team-asg \
  --launch-template "LaunchTemplateName=app-team-lt,Version=\$Latest"
```

#### Console

1. **EC2 → Auto Scaling Groups → Create** (or select an existing ASG → **Edit**).
2. **Launch template:** select `app-team-lt`, version **Latest**.
3. Set network/subnets, group size, and health checks.
4. **Create / Update.**

---

## The recurring workflow: "we need more disk for the next release"

### Option 1 (default): bump the template, then refresh — CLI

```bash
# 1. Create a new template version with a larger /data volume (e.g. 100 -> 250 GB).
aws ec2 create-launch-template-version \
  --launch-template-name app-team-lt \
  --version-description "release 2026.7: 250GB /data" \
  --source-version '$Latest' \
  --launch-template-data '{
    "BlockDeviceMappings": [
      { "DeviceName": "/dev/xvdf",
        "Ebs": { "VolumeSize": 250, "VolumeType": "gp3", "Iops": 3000, "Throughput": 125, "Encrypted": true, "DeleteOnTermination": true } }
    ]
  }'

# 2. Make it the default (optional if ASG tracks $Latest).
aws ec2 modify-launch-template \
  --launch-template-name app-team-lt \
  --default-version '$Latest'

# 3. Roll it out with zero downtime.
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name app-team-asg \
  --preferences '{"MinHealthyPercentage": 90, "InstanceWarmup": 300}'

# 4. Watch progress.
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name app-team-asg \
  --query "InstanceRefreshes[0].{Status:Status,Pct:PercentageComplete}"
```

New instances launch with a 250 GB `/data`, and the boot script grows the filesystem automatically.

### Option 1 — Console

1. **EC2 → Launch Templates → `app-team-lt` → Actions → Modify template (Create new version).**
2. Under **Storage**, change the `/dev/xvdf` volume size to **250 GiB**. Create the version, and set it as **Default** if desired.
3. **Auto Scaling Groups → `app-team-asg` → Instance refresh → Start instance refresh.**
4. Set **Minimum healthy percentage** (e.g. 90%) and **Instance warmup** (e.g. 300s), then **Start**.

### Option 2 (urgent): grow a live instance now — CLI

Use when an existing instance is running out of space before you can roll a refresh. **Do this and update the template**, so future instances inherit the size.

```bash
# 1. Find the data volume attached at /dev/xvdf on the instance.
VOLUME_ID=$(aws ec2 describe-volumes \
  --filters "Name=attachment.instance-id,Values=i-0123456789abcdef0" \
            "Name=attachment.device,Values=/dev/xvdf" \
  --query "Volumes[0].VolumeId" --output text)

# 2. Grow the volume (e.g. to 250 GB). Only once per 6h per volume.
aws ec2 modify-volume --volume-id "$VOLUME_ID" --size 250

# 3. Watch the modification reach 'optimizing'/'completed'.
aws ec2 describe-volumes-modifications --volume-id "$VOLUME_ID" \
  --query "VolumesModifications[0].{State:ModificationState,Pct:Progress}"

# 4. On the instance: grow partition (if any) and filesystem — no reboot.
#    Whole raw device:
sudo xfs_growfs /data        # xfs
# sudo resize2fs /dev/xvdf    # ext4
#    Partitioned device:
# sudo growpart /dev/nvme1n1 1 && sudo xfs_growfs /data
```

### Option 2 — Console

1. **EC2 → Volumes**, find the volume attached to the instance at `/dev/xvdf`.
2. **Actions → Modify volume**, set new **Size**, **Modify**.
3. Wait until state is *In-use - optimizing (completed)*.
4. Connect to the instance (SSM Session Manager or SSH) and run `xfs_growfs /data` (or `resize2fs`), plus `growpart` first if partitioned.
5. **Then** update the Launch Template (Option 1, steps 1–2) so scaled instances match.

---

## Verification

On any instance:

```bash
lsblk                 # see devices and sizes
df -h /data           # confirm mounted size reflects the new capacity
findmnt /data         # confirm mount source and options
```

Fleet-level check that new instances launched at the right size:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names app-team-asg \
  --query "AutoScalingGroups[0].Instances[].InstanceId" --output text
# then describe-volumes per instance, or inspect via SSM run-command
```

---

## Guardrails and best practices for supporting app teams

- **Set min/max sizes.** Enforce a floor and ceiling on the data volume so a typo can't provision 16 TB. Validate in the pipeline (Method C) or via SCP/IAM conditions.
- **One change path.** Make the Launch Template (or its SSM parameter) the single source of truth. Live resizes (Option 2) must be followed by a template update to prevent drift.
- **Always encrypt** data volumes (`Encrypted: true`) and standardize on a KMS key.
- **Right-size, then grow.** `gp3` lets you raise IOPS/throughput independently — don't over-provision size just to get performance.
- **Snapshot before big releases.** If the data volume holds state you care about, take an EBS snapshot before a large rollout so you can roll back.
- **Zero-downtime rollouts only.** Use instance refresh with `MinHealthyPercentage` and `InstanceWarmup`; wire ELB health checks so unhealthy new instances don't take traffic.
- **Grow at boot, never trust the AMI size.** The `growpart`/`resize2fs`/`xfs_growfs` step guarantees instances use the requested size even when the base AMI or snapshot was smaller.
- **Remember the 6-hour rule.** An individual EBS volume can only be modified once per 6 hours — plan urgent resizes accordingly.
- **Monitor disk usage.** Publish a CloudWatch disk-utilization metric (via the CloudWatch agent) and alarm at, say, 80% so teams request capacity **before** they hit the wall.
- **Keep OS and data separate.** Never grow the root volume for application data; isolate app growth on `/data`.

---

## Quick decision guide

- **Data must persist / grows with releases** → EBS data volume, Method A (default). ✅
- **Instance is filling up right now** → Method B live resize, then update the template. ⚠️
- **Let teams self-serve within guardrails** → Method C (SSM parameter + pipeline). ✅
- **Pure disposable scratch, max throughput** → Method D instance store, accept data loss. ⚠️
