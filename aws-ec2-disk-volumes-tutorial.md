# AWS EC2 Disk Volumes: A Beginner's Tutorial

*Written in plain, middle-school-friendly language. No prior cloud experience needed.*

*Covers: EBS volumes, resizing, mounting, snapshots, data migration, network drives (EFS/FSx/S3), AWS CLI, and Terraform.*

---

## Table of Contents

1. [What Is This All About?](#1-what-is-this-all-about)
2. [Step-by-Step Example: Make Your Disk Bigger](#2-step-by-step-example-make-your-disk-bigger)
3. [Background: How Disks Work on EC2](#3-background-how-disks-work-on-ec2)
4. [Task: Adding a Brand-New Volume](#4-task-adding-a-brand-new-volume)
5. [Task: Mounting a Volume in Linux](#5-task-mounting-a-volume-in-linux)
6. [Task: Making the Mount Survive a Reboot](#6-task-making-the-mount-survive-a-reboot)
7. [Task: Growing a Data Volume (Not the Root)](#7-task-growing-a-data-volume-not-the-root)
8. [Task: Removing a Volume Safely](#8-task-removing-a-volume-safely)
9. [Snapshots: Backup, Copy, and Restore](#9-snapshots-backup-copy-and-restore)
10. [Moving and Copying Data Between Volumes](#10-moving-and-copying-data-between-volumes)
11. [Network Drives: EFS, FSx, and S3 Mounts](#11-network-drives-efs-fsx-and-s3-mounts)
12. [AWS CLI Deep Dive](#12-aws-cli-deep-dive)
13. [Terraform Examples](#13-terraform-examples)
14. [Cheat Sheet: Commands to Check Things](#14-cheat-sheet-commands-to-check-things)
15. [Volume Types: Pros and Cons](#15-volume-types-pros-and-cons)
16. [File System Choices: ext4 vs XFS](#16-file-system-choices-ext4-vs-xfs)
17. [Best Practices](#17-best-practices)
18. [Common Mistakes and How to Fix Them](#18-common-mistakes-and-how-to-fix-them)
19. [Glossary](#19-glossary)

---

## 1. What Is This All About?

Imagine you rent a computer that lives in an Amazon data center. That rented computer is called an **EC2 instance**. Just like your laptop, it needs a hard drive to store files. On AWS, that hard drive is called an **EBS volume** (EBS = Elastic Block Store).

The word "elastic" is a big hint: you can **stretch** these disks to make them bigger, **add** more of them, and **move** them between computers. This tutorial teaches you how to do all of that, plus how to peek inside Linux to check what's going on.

**What you'll need to follow along:**

- An AWS account and one running EC2 instance (Amazon Linux 2023 or Ubuntu are perfect)
- A way to log in to it (SSH or the browser-based "EC2 Instance Connect")
- Permission to type commands with `sudo` (which means "do this as the boss/administrator")

> **Tip:** Every command in this tutorial that starts with `sudo` needs administrator power. If you forget `sudo`, Linux will usually say "Permission denied."

---

## 2. Step-by-Step Example: Make Your Disk Bigger

This is the number-one most common task, so we'll start here. Our story: your server started with an 8 GB root disk, it's almost full, and you want to grow it to 20 GB. **You can do this while the server is running. No shutdown needed.**

### Step 1: Look at what you have now

Log in to your instance and run:

```bash
df -h
```

`df` means "disk free" and `-h` means "human-readable" (shows GB instead of giant numbers). You'll see something like:

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1  8.0G  7.2G  800M  90%  /
```

Translation: the disk called `/dev/nvme0n1p1` is 8 GB, 90% full, and it's the main disk (`/`).

Now check the *physical* disk and its partitions:

```bash
lsblk
```

```
NAME         MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
nvme0n1      259:0    0   8G  0 disk
├─nvme0n1p1  259:1    0   8G  0 part /
└─nvme0n1p128 259:2   0   1M  0 part
```

`lsblk` = "list block devices." Think of the disk (`nvme0n1`) as a pizza and the partitions (`nvme0n1p1`) as the slices. Right now the pizza is 8 GB and one slice takes up almost all of it.

### Step 2: Make the volume bigger in the AWS Console

1. Open the **AWS Console** → **EC2** → in the left menu click **Volumes** (under "Elastic Block Store").
2. Find the volume attached to your instance. (Click your instance first under **Instances**, then the **Storage** tab, to see which volume ID belongs to it.)
3. Select the volume → click **Actions** → **Modify volume**.
4. Change **Size** from `8` to `20`. Click **Modify**, then **Confirm**.
5. Wait until the **Volume state** shows `in-use - optimizing` or `in-use - completed`. Optimizing is fine; you can keep going.

> **You can also do it from the command line** (if you have the AWS CLI installed):
> ```bash
> aws ec2 modify-volume --volume-id vol-0123456789abcdef0 --size 20
> ```

### Step 3: Tell Linux the disk grew

Go back to your terminal and run `lsblk` again:

```
NAME         SIZE TYPE MOUNTPOINT
nvme0n1       20G disk
├─nvme0n1p1    8G part /
└─nvme0n1p128  1M part
```

See the problem? The pizza is now 20 GB, but the slice is still only 8 GB. We have to stretch the slice (partition) too:

```bash
sudo growpart /dev/nvme0n1 1
```

Read that carefully: the disk name is `/dev/nvme0n1`, then a **space**, then the partition **number** `1`. That's a common typo spot.

You'll see something like `CHANGED: partition=1 start=4096 old: size=16773087 end=16777183 new: size=41938911 end=41943007`.

> **If `growpart` isn't installed:**
> - Amazon Linux: `sudo dnf install -y cloud-utils-growpart`
> - Ubuntu/Debian: `sudo apt install -y cloud-guest-utils`

### Step 4: Stretch the file system

Now the slice is 20 GB, but the "shelving" inside it (the **file system**) is still 8 GB. One more stretch. First find out which file system you have:

```bash
df -hT /
```

The `T` adds a **Type** column. It will say either `xfs` or `ext4`.

**If it says `xfs`** (Amazon Linux default):

```bash
sudo xfs_growfs /
```

**If it says `ext4`** (Ubuntu default):

```bash
sudo resize2fs /dev/nvme0n1p1
```

### Step 5: Check your work

```bash
df -h /
```

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1   20G  7.2G   13G  36%  /
```

Done! Your server now has 20 GB and you never had to shut it down.

### Quick summary of the whole flow

```
AWS Console: Modify volume (make it bigger)
        ↓
lsblk                          ← confirm Linux sees the bigger disk
        ↓
sudo growpart /dev/nvme0n1 1   ← stretch the partition
        ↓
sudo xfs_growfs /              ← stretch the file system (XFS)
   or
sudo resize2fs /dev/nvme0n1p1  ← stretch the file system (ext4)
        ↓
df -h                          ← verify
```

> **Important rule:** You can make EBS volumes **bigger**, but AWS does **not** let you make them **smaller**. If you need a smaller disk, you have to create a new smaller volume and copy your data over. Also, after modifying a volume, you must wait **at least 6 hours** before you can modify that same volume again.

---

## 3. Background: How Disks Work on EC2

### The three layers

Think of storage like a library:

| Layer | Library analogy | Linux name | Tool that changes it |
|---|---|---|---|
| **Volume / Disk** | The building | `/dev/nvme1n1` | AWS Console or `aws ec2 modify-volume` |
| **Partition** | A floor of the building | `/dev/nvme1n1p1` | `growpart`, `fdisk`, `parted` |
| **File system** | The shelves that hold books | ext4 or XFS | `mkfs`, `xfs_growfs`, `resize2fs` |

When you grow a disk, you have to grow **each layer** from the outside in. That's why Section 2 had three separate stretch steps.

### Why the names look weird: `nvme0n1`, `xvda`, `sda`

Modern EC2 instances (anything built on the "Nitro" system, which is nearly every current type) show disks as **NVMe** devices:

- `nvme0n1` = first disk
- `nvme1n1` = second disk
- `nvme0n1p1` = first partition on the first disk

Older instance types show `/dev/xvda`, `/dev/xvdf`, etc. And when you attach a volume in the AWS Console, it may *ask* you for a name like `/dev/sdf`, but inside Linux it will show up as `nvme1n1`. This is confusing but normal. **Always use `lsblk` to see what Linux actually calls the disk.**

To match an NVMe device to its AWS volume ID:

```bash
sudo nvme list
```

or on Amazon Linux:

```bash
sudo ebsnvme-id /dev/nvme1n1
```

### Root volume vs. data volumes

- **Root volume:** the disk Linux boots from. Mounted at `/`. Every instance has exactly one.
- **Data volume:** extra disks you attach for storing stuff (databases, uploads, backups). Mounted wherever you want, like `/data` or `/mnt/backup`.

### Instance Store: the "disappearing" disk

Some instance types come with a free **Instance Store** disk. It's super fast but it's **erased every time the instance stops**. Never keep anything important on it. EBS volumes are the ones that stick around.

### Deeper background: what EBS really is

Here's a surprise: an EBS volume is **not** a hard drive sitting inside your server. It's actually a chunk of storage on separate storage servers in the same data center, connected to your instance over a super-fast private network. That's why:

- You can **detach** a volume from one instance and attach it to another in seconds (nothing physically moves).
- Your data **survives** even if the physical machine running your instance dies. AWS just reattaches the volume to a new machine.
- Every volume is automatically **replicated** (copied) to multiple physical drives inside its Availability Zone, so a single dead drive never loses your data.
- A volume is locked to **one Availability Zone**. It can't attach to an instance in a different zone because the network path only exists inside that zone.

So think of EBS as a "network hard drive that pretends to be local." Linux treats it like a normal disk, but under the hood it's a network service.

### The storage family on AWS (where does EBS fit?)

| Kind | AWS service | Feels like | Shared between servers? | Best for |
|---|---|---|---|---|
| **Block storage** | EBS | A hard drive | Normally no (one instance at a time; io2 supports "Multi-Attach" for special cluster software) | Boot disks, databases, anything needing a normal file system |
| **Local disk** | Instance Store | A hard drive that forgets everything on stop | No | Caches, scratch space, temp files |
| **Network file system** | EFS, FSx | A shared folder | **Yes**, many servers at once | Shared uploads, home folders, web content, HPC |
| **Object storage** | S3 | A giant bucket of files reached by API | Yes, from anywhere | Backups, media, data lakes, static websites |

This tutorial is mostly about the first row (EBS), with Section 11 covering the third row (network file systems).

### Speed words: IOPS, throughput, and latency

When people talk about disk speed they mean three different things:

- **IOPS** (I/O operations per second): how many separate read/write requests the disk can handle each second. Databases care about this because they do tons of tiny reads.
- **Throughput** (MB/s): how much data flows per second. Video processing and big file copies care about this.
- **Latency** (milliseconds): how long one request waits. Usually under 1 ms for SSD volumes.

Example: gp3 gives you 3,000 IOPS and 125 MB/s for free. If you're copying one huge 10 GB file, you're limited by throughput (125 MB/s → about 80 seconds). If you're running a database doing 5,000 small writes per second, you're limited by IOPS and would need to pay for more.

The instance type has its own limit too. A tiny `t3.micro` can't push 2,000 MB/s no matter how fast the volume is. Check the "EBS bandwidth" column in the instance type table when it matters.

### Encryption in one paragraph

EBS encryption uses AWS KMS keys. When it's on, everything is encrypted: the volume, its snapshots, and data moving between the volume and the instance. The instance never sees the key; a special chip on the Nitro hardware does the encrypting and decrypting, so there's **no speed penalty**. You can't turn encryption on for an existing volume; you snapshot it, copy the snapshot with encryption, and make a new volume. The easiest path is to turn on **Encryption by default** in EC2 Settings so every new volume is encrypted automatically.

### What happens when an instance stops or terminates?

- **Stop:** the instance is powered off. All EBS volumes stay attached and keep their data. Instance Store is wiped.
- **Terminate:** the instance is deleted. Each volume has a "Delete on termination" flag. The root volume defaults to **true** (it gets deleted); extra data volumes default to **false** (they stick around as "available" volumes). You can change either flag, and you should double-check it before terminating anything important.


---

## 4. Task: Adding a Brand-New Volume

Let's say you want a separate 50 GB disk for storing project files.

### Step 1: Create the volume

1. **EC2 Console** → **Volumes** → **Create volume**.
2. **Volume type:** `gp3` (the best default; see Section 15).
3. **Size:** `50` GiB.
4. **Availability Zone:** This **must match your instance's zone** (for example `us-east-1a`). A volume in one zone cannot attach to an instance in another. Check your instance's zone on the Instances page.
5. Leave IOPS at 3000 and Throughput at 125 (the free defaults for gp3).
6. Turn on **Encrypt this volume** (highly recommended; it's free and has no speed cost).
7. Click **Create volume**.

**CLI version:**

```bash
aws ec2 create-volume \
  --volume-type gp3 \
  --size 50 \
  --availability-zone us-east-1a \
  --encrypted \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=project-data}]'
```

### Step 2: Attach it to your instance

1. Select the new volume → **Actions** → **Attach volume**.
2. Choose your instance.
3. Device name: accept the suggestion (usually `/dev/sdf`).
4. Click **Attach**.

**CLI version:**

```bash
aws ec2 attach-volume \
  --volume-id vol-0abc123def456 \
  --instance-id i-0123456789abcdef0 \
  --device /dev/sdf
```

### Step 3: See it in Linux

```bash
lsblk
```

```
NAME         SIZE TYPE MOUNTPOINT
nvme0n1       20G disk
└─nvme0n1p1   20G part /
nvme1n1       50G disk            ← the new one! No mountpoint yet.
```

The new disk is there but it's a blank slab. It has no file system and isn't mounted. Section 5 fixes that.

---

## 5. Task: Mounting a Volume in Linux

"Mounting" means connecting a disk to a folder so you can use it. It's like plugging in a USB stick: the stick exists, but you can't open files until the computer gives it a spot (like drive `E:` on Windows or a folder on Linux).

### Step 1: Make sure it's really blank

```bash
sudo file -s /dev/nvme1n1
```

- If it says `/dev/nvme1n1: data` → it's **blank**. Safe to format. Continue.
- If it says anything about `XFS`, `ext4`, or a filesystem → it **already has data**. **Do NOT format it** or you'll erase everything. Skip to Step 3.

You can double-check with:

```bash
lsblk -f
```

The `-f` shows file system types. A blank disk shows an empty FSTYPE column.

### Step 2: Format it (create a file system)

Pick one:

```bash
# XFS (recommended, Amazon's default)
sudo mkfs -t xfs /dev/nvme1n1

# OR ext4
sudo mkfs -t ext4 /dev/nvme1n1
```

> `mkfs` = "make file system." This is the **destructive** step. Only do it once, only on a blank disk.

### Step 3: Create a folder to mount it on

```bash
sudo mkdir -p /data
```

The folder can be named anything. `/data`, `/mnt/projects`, `/srv/files` are all common.

### Step 4: Mount it

```bash
sudo mount /dev/nvme1n1 /data
```

### Step 5: Check it worked

```bash
df -h /data
```

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme1n1     50G  390M   50G   1%  /data
```

Try writing a file:

```bash
sudo touch /data/hello.txt
ls -l /data
```

### Step 6: Give yourself permission to use it

By default only root can write there. To let your normal user (like `ec2-user` or `ubuntu`) use it:

```bash
sudo chown ec2-user:ec2-user /data     # Amazon Linux
sudo chown ubuntu:ubuntu /data         # Ubuntu
```

> **Warning:** This mount is temporary. If the instance reboots, `/data` will be an empty folder again (the disk is still there, just not mounted). Section 6 fixes that.

---

## 6. Task: Making the Mount Survive a Reboot

Linux has a file called `/etc/fstab` ("file system table"). At boot, Linux reads it and mounts everything listed.

### Step 1: Get the disk's UUID

Never use `/dev/nvme1n1` in fstab, because that name can change if you add or remove disks. Instead use the **UUID**, a unique ID that never changes:

```bash
sudo blkid /dev/nvme1n1
```

```
/dev/nvme1n1: UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890" TYPE="xfs"
```

Copy that UUID.

### Step 2: Back up fstab first

A broken fstab can stop your server from booting. Always back it up:

```bash
sudo cp /etc/fstab /etc/fstab.backup
```

### Step 3: Add a line to fstab

```bash
sudo nano /etc/fstab
```

Add this line at the bottom (use your real UUID and file system type):

```
UUID=a1b2c3d4-e5f6-7890-abcd-ef1234567890  /data  xfs  defaults,nofail  0  2
```

What each part means:

| Part | Meaning |
|---|---|
| `UUID=...` | Which disk |
| `/data` | Where to mount it |
| `xfs` | File system type (`xfs` or `ext4`) |
| `defaults,nofail` | Normal options. **`nofail` is the important one**: if the disk is missing, boot anyway instead of getting stuck |
| `0` | Don't use the old `dump` backup tool |
| `2` | Check this disk for errors at boot, after the root disk (which is `1`) |

Save with `Ctrl+O`, `Enter`, then exit with `Ctrl+X`.

### Step 4: Test it WITHOUT rebooting

```bash
sudo umount /data          # unmount it
sudo mount -a              # mount everything in fstab
df -h /data                # is it back?
```

If `mount -a` prints no errors and `df -h` shows `/data`, you're safe. If you see an error, fix the line (or restore with `sudo cp /etc/fstab.backup /etc/fstab`) **before** rebooting.

---

## 7. Task: Growing a Data Volume (Not the Root)

This is the same idea as Section 2 but simpler, because data volumes usually have **no partition**. You formatted the whole disk directly (`/dev/nvme1n1`, not `nvme1n1p1`), so there's one less layer to stretch.

1. **AWS Console** → Volumes → Modify volume → new size → Modify.
2. Check Linux sees it:
   ```bash
   lsblk
   ```
3. Grow the file system (no `growpart` needed since there's no partition):
   ```bash
   # XFS: point at the MOUNT FOLDER
   sudo xfs_growfs /data

   # ext4: point at the DEVICE
   sudo resize2fs /dev/nvme1n1
   ```
4. Verify:
   ```bash
   df -h /data
   ```

> **Notice the difference:** `xfs_growfs` wants the **folder** (`/data`), while `resize2fs` wants the **device** (`/dev/nvme1n1`). Mixing them up is a classic mistake.

If your data volume *does* have a partition (you'll see `nvme1n1p1` in `lsblk`), then add the `growpart` step: `sudo growpart /dev/nvme1n1 1`.

---

## 8. Task: Removing a Volume Safely

Order matters. Doing this backwards can corrupt data.

```bash
# 1. Make sure nothing is using it
sudo lsof +f -- /data          # lists open files; should be empty

# 2. Unmount
sudo umount /data

# 3. Remove its line from /etc/fstab (or the next boot may hang without nofail)
sudo nano /etc/fstab
```

Then in the **AWS Console**: select the volume → **Actions** → **Detach volume**. Once it says `available`, you can **Delete** it (if you're sure) or keep it around to attach elsewhere.

> If `umount` says "target is busy," something is still using the folder. Run `sudo lsof +f -- /data` or `sudo fuser -vm /data` to find out what, close it, and try again. Or `cd` out of the folder if your own terminal is sitting inside it!

---

## 9. Snapshots: Backup, Copy, and Restore

A **snapshot** is a photo of a whole volume at one moment in time. It's stored in S3 behind the scenes (you never see the files; AWS handles it). Snapshots are how you back up, copy, clone, and move disks on AWS.

Cool facts about snapshots:

- **They're incremental.** The first snapshot copies everything. Every later snapshot only saves the blocks that changed. So taking one every day is cheap.
- **They work on a running instance.** For a data volume that's actively being written to, it's safer to pause writes first (see the "consistent snapshot" tip below).
- **They can cross Regions and even AWS accounts.** That's the secret to disaster recovery and to moving a server from, say, Virginia to Oregon.
- **You can delete old snapshots without breaking newer ones.** AWS quietly keeps whatever blocks the remaining snapshots still need.

### 9.1 Take a snapshot

**Console:** EC2 → **Volumes** → select volume → **Actions** → **Create snapshot** → give it a description → **Create snapshot**.

**CLI:**

```bash
aws ec2 create-snapshot \
  --volume-id vol-0abc123def456 \
  --description "project-data before upgrade" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=project-data-2026-09-07}]'
```

Watch its progress (it says `pending` then `completed`):

```bash
aws ec2 describe-snapshots --snapshot-ids snap-0123456789abcdef0 \
  --query 'Snapshots[].{ID:SnapshotId,State:State,Progress:Progress}' --output table
```

> **Consistent snapshot tip (data volumes):** If a database or app is writing to the disk, freeze it for a second so the snapshot isn't half-written:
> ```bash
> sudo fsfreeze --freeze /data      # pause writes
> aws ec2 create-snapshot --volume-id vol-0abc123def456 --description "clean"
> sudo fsfreeze --unfreeze /data    # resume (do this IMMEDIATELY; the snapshot keeps going in the background)
> ```
> **Never** freeze the root volume `/`. You'll lock yourself out. For root, just take the snapshot; it's fine for most cases, or stop the instance first for a perfect copy.

**Snapshot every volume on an instance at once** (all disks stay consistent with each other):

```bash
aws ec2 create-snapshots \
  --instance-specification InstanceId=i-0123456789abcdef0 \
  --description "full server backup"
```

### 9.2 Copy a snapshot

Why copy a snapshot?

| Reason | Example |
|---|---|
| **Disaster recovery** | Keep a copy in another Region in case a whole Region has problems |
| **Move a server** | Copy to the Region where you want the new instance |
| **Encrypt an old unencrypted disk** | Copying is the only way to turn encryption on |
| **Share with another account** | Copy into a different AWS account |

**Copy to another Region (Console):** EC2 → **Snapshots** → select it → **Actions** → **Copy snapshot** → choose **Destination Region** → optionally tick **Encrypt** → **Copy snapshot**.

**CLI** (run this *in the destination region*, telling it where the source is):

```bash
aws ec2 copy-snapshot \
  --source-region us-east-1 \
  --source-snapshot-id snap-0123456789abcdef0 \
  --region us-west-2 \
  --description "DR copy of project-data" \
  --encrypted
```

**Copy within the same Region but add encryption:**

```bash
aws ec2 copy-snapshot \
  --source-region us-east-1 \
  --source-snapshot-id snap-0123456789abcdef0 \
  --encrypted \
  --kms-key-id alias/aws/ebs
```

**Share a snapshot with another AWS account** (then that account copies it):

```bash
aws ec2 modify-snapshot-attribute \
  --snapshot-id snap-0123456789abcdef0 \
  --attribute createVolumePermission \
  --operation-type add \
  --user-ids 111122223333
```

> Encrypted snapshots can only be shared if they use a **customer-managed KMS key** (not the default `aws/ebs` key), and you must share the key too.

### 9.3 Restore from a snapshot (create a new volume)

Restoring means: **make a new volume from the snapshot, then attach and mount it**. The snapshot itself never changes.

**Console:** EC2 → **Snapshots** → select it → **Actions** → **Create volume from snapshot** → pick **Availability Zone** (must match your instance!) → optionally make **Size** bigger → **Create volume**. Then attach and mount exactly like Section 4 and 5 (but **skip `mkfs`**; the restored disk already has a file system and data on it).

**CLI:**

```bash
# 1. Create the volume from the snapshot (can be bigger than the original, never smaller)
aws ec2 create-volume \
  --snapshot-id snap-0123456789abcdef0 \
  --availability-zone us-east-1a \
  --volume-type gp3 \
  --size 100 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=project-data-restored}]'

# 2. Attach it
aws ec2 attach-volume --volume-id vol-0new111222333 --instance-id i-0123456789abcdef0 --device /dev/sdg

# 3. In Linux: find it, make a folder, mount it (NO mkfs!)
lsblk
sudo mkdir -p /restore
sudo mount /dev/nvme2n1 /restore
ls /restore
```

If you made the restored volume bigger than the snapshot, grow the file system afterward (`sudo xfs_growfs /restore` or `sudo resize2fs /dev/nvme2n1`).

> **XFS "UUID already exists" gotcha:** If you restore a snapshot of a volume and mount it on the **same instance where the original is still mounted**, XFS may refuse because both disks have the identical UUID. Fix with `sudo mount -o nouuid /dev/nvme2n1 /restore` for a one-time mount, or give the copy a new UUID permanently: `sudo xfs_admin -U generate /dev/nvme2n1` (only while unmounted). For ext4: `sudo tune2fs -U random /dev/nvme2n1`.

### 9.4 Restore a ROOT volume (server won't boot, or roll back a bad change)

1. **Stop** the instance (not terminate!).
2. Note its Availability Zone and the root device name (Instance → **Storage** tab → usually `/dev/xvda` or `/dev/sda1`).
3. Create a volume from your good snapshot **in that same AZ**.
4. **Detach** the old root volume (Volumes → Actions → Detach). Don't delete it yet.
5. **Attach** the new volume to the instance using the **exact same device name** from step 2.
6. **Start** the instance. Log in and confirm everything looks right.
7. Once you're happy, delete the old root volume (or keep it a few days, just in case).

### 9.5 Restore just a few files (not the whole disk)

You don't have to swap whole disks. Restore the snapshot to a *temporary* volume, mount it at `/restore`, copy out only what you need, then unmount and delete the temp volume:

```bash
sudo mount -o nouuid /dev/nvme2n1 /restore       # nouuid only needed for XFS same-instance case
sudo cp -a /restore/home/ec2-user/report.docx /home/ec2-user/
sudo umount /restore
```

### 9.6 Turn a snapshot into a whole new server (AMI)

If you snapshot a **root** volume, you can register it as an **AMI** (Amazon Machine Image) and launch as many clones of the server as you want:

```bash
aws ec2 register-image \
  --name "my-webserver-2026-09-07" \
  --root-device-name /dev/xvda \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"SnapshotId":"snap-0123456789abcdef0"}}]' \
  --architecture x86_64 \
  --virtualization-type hvm \
  --ena-support
```

Easier: Instance → **Actions** → **Image and templates** → **Create image**. That snapshots every attached volume and builds the AMI in one click.

### 9.7 Automate it: Data Lifecycle Manager (DLM)

Don't rely on remembering. EC2 → **Lifecycle Manager** → **Create lifecycle policy** → "EBS snapshot policy" → choose volumes by **tag** (e.g. `Backup=daily`) → schedule (e.g. every 24 h, keep 7) → optionally **cross-Region copy**. Now backups happen by themselves and old ones auto-delete.

### 9.8 Useful snapshot check commands

```bash
# All snapshots you own, newest first
aws ec2 describe-snapshots --owner-ids self \
  --query 'reverse(sort_by(Snapshots,&StartTime))[].{ID:SnapshotId,Vol:VolumeId,Size:VolumeSize,State:State,Date:StartTime,Desc:Description}' \
  --output table

# Snapshots for one specific volume
aws ec2 describe-snapshots --owner-ids self --filters Name=volume-id,Values=vol-0abc123def456 --output table

# Delete a snapshot you no longer need
aws ec2 delete-snapshot --snapshot-id snap-0123456789abcdef0
```

### Snapshot pros and cons

| | Pros | Cons |
|---|---|---|
| **EBS snapshots** | Built-in, incremental, cheap, cross-Region, can become AMIs | Whole-volume only (restoring one file means mounting a temp volume); first snapshot of a big disk is slow; restored volumes are "lazy loaded" so first reads are slower until blocks arrive (fix: **Fast Snapshot Restore**, costs extra, or run `sudo fio`/`dd` to pre-warm) |
| **File-level backup (rsync to S3, etc.)** | Restore single files fast; keeps history of individual files | You build and maintain it yourself; not a bootable image |

**Best answer for most people:** DLM snapshots for the whole disk **plus** `aws s3 sync` for the important folders.

---

## 10. Moving and Copying Data Between Volumes

Sometimes you need to shuffle files rather than whole disks: move `/var/lib/mysql` to a new bigger volume, copy a folder to another server, or migrate from an old ext4 disk to a new XFS one.

### 10.1 The golden rules

1. **Use `rsync`, not `cp`, for big jobs.** It can resume if interrupted, shows progress, and only copies what changed if you run it again.
2. **Use `-a` (archive) to keep permissions, owners, timestamps, and symlinks.** Without it, your copied files may all be owned by root with the wrong dates.
3. **Watch the trailing slash.** `rsync -a /data/ /newdata/` copies the *contents* of `/data` into `/newdata`. `rsync -a /data /newdata/` creates `/newdata/data`. That slash is the #1 rsync mistake.
4. **Verify before you delete the original.**

### 10.2 Copy between two volumes on the SAME instance

Scenario: your old 50 GB `/data` is full. You attached and mounted a new 200 GB volume at `/newdata` (Sections 4 and 5). Now move everything over.

```bash
# 1. Dry run first: see what WOULD happen, copy nothing
sudo rsync -aHAXv --dry-run /data/ /newdata/ | head -40

# 2. The real copy, with progress
sudo rsync -aHAXv --info=progress2 /data/ /newdata/

# 3. Stop any app using /data, then run rsync ONE MORE TIME to grab last-second changes
sudo systemctl stop myapp
sudo rsync -aHAXv --delete /data/ /newdata/

# 4. Verify: same number of files, same total size
sudo find /data -type f | wc -l
sudo find /newdata -type f | wc -l
sudo du -sh /data /newdata

# 5. Swap the mount points
sudo umount /newdata
sudo umount /data
sudo mount /dev/nvme2n1 /data        # the NEW disk now lives at /data
sudo systemctl start myapp

# 6. Update /etc/fstab so the new UUID is the one mounted at /data (see Section 6)
sudo blkid /dev/nvme2n1
sudo nano /etc/fstab
```

What the flags mean:

| Flag | Meaning |
|---|---|
| `-a` | Archive: keep permissions, owner, timestamps, symlinks, recurse into folders |
| `-H` | Keep hard links |
| `-A` | Keep ACLs (extra permission rules) |
| `-X` | Keep extended attributes (SELinux labels, etc.) |
| `-v` | Verbose: list files as they go |
| `--info=progress2` | One overall progress bar instead of a wall of text |
| `--dry-run` | Pretend; touch nothing |
| `--delete` | Make the destination an exact mirror by deleting files that no longer exist in the source. **Careful with this one.** |

### 10.3 Copy to a DIFFERENT instance over the network

`rsync` works over SSH, so you can copy straight from one server to another. Run this **on the source server**:

```bash
sudo rsync -aHAXv --info=progress2 -e "ssh -i ~/mykey.pem" \
  /data/ ec2-user@10.0.1.25:/data/
```

Or **pull** from the destination server:

```bash
sudo rsync -aHAXv --info=progress2 -e "ssh -i ~/mykey.pem" \
  ec2-user@10.0.1.10:/data/ /data/
```

Tips:

- Use the **private IP** (10.x.x.x) if both servers are in the same VPC. It's faster and free. Public IPs cost data-transfer money.
- The security group on the destination must allow SSH (port 22) from the source.
- For huge transfers, run inside `tmux` or `screen` so a dropped SSH session doesn't kill the copy: `tmux new -s copy`, run rsync, detach with `Ctrl+B` then `D`.
- Add `-z` to compress on the wire if the files are text and the network is the bottleneck. Skip `-z` for already-compressed stuff (videos, zips).

**Alternative: `scp`** for a quick one-off file (no resume, no progress on folders):

```bash
scp -i ~/mykey.pem -r /data/reports ec2-user@10.0.1.25:/data/
```

### 10.4 Move a whole VOLUME to another instance (no copying at all)

If both instances are in the **same Availability Zone**, you can just unplug the disk from one and plug it into the other. Nothing gets copied, so it takes seconds no matter how big the disk is.

```bash
# On the OLD instance
sudo umount /data
# remove its line from /etc/fstab

# From your laptop / anywhere with AWS CLI
aws ec2 detach-volume --volume-id vol-0abc123def456
aws ec2 attach-volume --volume-id vol-0abc123def456 --instance-id i-0NEW-INSTANCE --device /dev/sdf

# On the NEW instance
lsblk
sudo mkdir -p /data
sudo mount /dev/nvme1n1 /data      # NO mkfs; the data is already there
# add it to /etc/fstab with its UUID
```

If the instances are in **different AZs or Regions**, you can't attach directly. Do this instead: snapshot the volume → (copy the snapshot to the other Region if needed) → create a volume from the snapshot in the target AZ → attach. That's Section 9.2 and 9.3.

### 10.5 Copy an entire disk block-by-block with `dd`

`dd` clones the raw disk, byte for byte, including the partition table. Use it when you need an *exact* clone of a disk that isn't easy to snapshot (or to migrate a disk to a different file system size layout). It's slow and dangerous, so mostly prefer snapshots.

```bash
# Both disks UNMOUNTED. if= is the source, of= is the destination. Triple-check them: dd will happily overwrite the wrong disk.
sudo dd if=/dev/nvme1n1 of=/dev/nvme2n1 bs=64M status=progress
sync
```

> Destination must be the same size or bigger. After cloning to a bigger disk, grow the partition/file system as in Section 2. And remember the XFS duplicate-UUID gotcha from Section 9.3.

### 10.6 Move data to or from S3

S3 is great as a middle stop (cheap, durable, reachable from any Region or instance). Your instance needs an IAM role with S3 permission.

```bash
# Upload a folder (only changed files get copied on repeat runs)
aws s3 sync /data/ s3://my-bucket/data-backup/

# Download it somewhere else
aws s3 sync s3://my-bucket/data-backup/ /data/

# Copy a single big file
aws s3 cp /data/big-archive.tar.gz s3://my-bucket/
```

### 10.7 Move a specific system folder to a new volume (example: `/var/log`)

A classic admin task: the root disk is filling up with logs, so put `/var/log` on its own disk.

```bash
# 1. Attach + format + mount new volume temporarily
sudo mkfs -t xfs /dev/nvme1n1
sudo mkdir /mnt/newlog
sudo mount /dev/nvme1n1 /mnt/newlog

# 2. Copy the logs over (keep permissions!)
sudo rsync -aHAX /var/log/ /mnt/newlog/

# 3. Swap it in
sudo mv /var/log /var/log.old
sudo mkdir /var/log
sudo umount /mnt/newlog
sudo mount /dev/nvme1n1 /var/log

# 4. Make it permanent in /etc/fstab (UUID + nofail), then restart services that write logs
sudo systemctl restart rsyslog

# 5. After a day of confirming everything works, reclaim the space
sudo rm -rf /var/log.old
```

The same recipe works for `/home`, `/var/lib/docker`, `/var/lib/mysql`, and so on (stop the related service first for database folders).

### 10.8 Check commands for copying jobs

| Command | What it tells you |
|---|---|
| `sudo du -sh /data /newdata` | Are the two sides the same size? |
| `sudo find /data -type f \| wc -l` | How many files (compare both sides) |
| `sudo rsync -aHAXn --itemize-changes /data/ /newdata/` | Lists exactly what still differs (`-n` = dry run). Empty output = identical |
| `sudo diff -rq /data /newdata` | Another way to list differences (slower, reads every byte) |
| `sudo sha256sum /data/file.bin /newdata/file.bin` | Confirm one specific file copied perfectly |
| `iostat -xz 1` | Is the disk the bottleneck during a copy? |
| `iftop` or `nload` | Is the network the bottleneck? (install first) |
| `progress` | Shows progress of a running `cp`/`dd`/`mv` (install first) |

### Copy methods: pros and cons

| Method | Best for | Pros | Cons |
|---|---|---|---|
| **rsync** | Folders, any size, same or different server | Resumable, keeps permissions, incremental, progress | Slightly more to learn |
| **cp -a** | Small quick copies | Simple | No resume, no progress, no incremental |
| **scp** | One file to another server | Simple | No resume; slow for many small files |
| **Detach/attach volume** | Whole disk, same AZ | Instant, no copying | Same AZ only; volume is offline during the move |
| **Snapshot → new volume** | Whole disk, any AZ/Region | Works everywhere, also a backup | Takes time for big disks; restored disk is lazy-loaded |
| **dd** | Exact byte clone | Copies everything incl. partition table | Slow; extremely easy to nuke the wrong disk; must be unmounted |
| **aws s3 sync** | Long-term storage or many destinations | Cheap, durable, incremental | Needs IAM role; no permissions/ownership preserved by default |

---

## 11. Network Drives: EFS, FSx, and S3 Mounts

Everything so far was about EBS, which is a disk for **one** server. But what if five web servers all need the same uploads folder? Or a hundred compute nodes all need to read the same dataset? For that you need a **network drive**: a shared folder that lives on the network and that many servers can mount at the same time. On your laptop the equivalent is a shared folder from a NAS or a Windows file server.

### 11.1 The choices

| Service | Protocol | Who can mount it | Think of it as | Best for |
|---|---|---|---|---|
| **EFS** (Elastic File System) | NFS v4.1 | Linux (EC2, containers, Lambda, on-prem via VPN) | A shared Linux folder that grows automatically | Shared web content, uploads, home directories, CMS, containers |
| **FSx for Lustre** | Lustre | Linux | A screaming-fast shared scratch disk | HPC, machine learning, video rendering, big-data |
| **FSx for Windows File Server** | SMB | Windows and Linux | A Windows file share with Active Directory permissions | Windows apps, user shares, anything needing SMB |
| **FSx for NetApp ONTAP** | NFS, SMB, iSCSI | Both | An enterprise NAS in the cloud | Multi-protocol, snapshots, dedup, lift-and-shift from NetApp |
| **FSx for OpenZFS** | NFS | Linux | A very fast NFS server with ZFS features | Low-latency NFS, dev/test, databases that want NFS |
| **Mountpoint for S3** | S3 API presented as a folder | Linux | A read-mostly view of an S3 bucket as a folder | Reading big datasets directly from S3; ML training data |

**Simple rule:** need a shared Linux folder → **EFS**. Need Windows/SMB → **FSx for Windows**. Need ridiculous speed for HPC → **FSx for Lustre**. Just want to *look* at an S3 bucket as files → **Mountpoint for S3**.

### 11.2 EFS vs EBS: the big picture

| | EBS | EFS |
|---|---|---|
| Servers at once | One (Multi-Attach only with io2) | Thousands |
| Size | You pick; you must grow it yourself | Automatic; grows and shrinks as you add/delete files, no limit |
| Zone | Locked to one AZ | Available in every AZ of the Region (Regional) or one AZ (One Zone) |
| Speed feel | Like a local SSD; sub-ms latency | Higher latency (a few ms); great for big files, slower for millions of tiny files |
| Price | Per GB you *provisioned* (even if empty) | Per GB you *actually use* (but higher per-GB) |
| Boot from it? | Yes | No |
| Backups | Snapshots | AWS Backup built in |

### 11.3 Step-by-step: create and mount an EFS file system

**Step 1: Create the file system**

Console: **EFS** → **Create file system** → name it → pick your VPC → **Create**. (The Customize button lets you pick One Zone, lifecycle rules, and throughput mode.)

CLI:

```bash
aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode elastic \
  --encrypted \
  --tags Key=Name,Value=shared-uploads
```

Note the file system ID it returns, like `fs-0123456789abcdef0`.

**Step 2: Create mount targets**

A mount target is EFS's "network plug" inside each Availability Zone. Your instance connects to the mount target in its own AZ. You need one per AZ where you have instances.

```bash
aws efs create-mount-target \
  --file-system-id fs-0123456789abcdef0 \
  --subnet-id subnet-0aaa111bbb222 \
  --security-groups sg-0efs1234
```

**Step 3: Open the firewall (security group)**

NFS uses **TCP port 2049**. The mount target's security group must allow inbound 2049 from your instances' security group:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0efs1234 \
  --protocol tcp --port 2049 \
  --source-group sg-0instances5678
```

> The #1 EFS problem is a mount that hangs forever. Nine times out of ten it's this port not being open.

**Step 4: Install the EFS helper on the instance**

```bash
# Amazon Linux 2023
sudo dnf install -y amazon-efs-utils

# Ubuntu (build from source; Amazon documents this)
sudo apt install -y git binutils rustc cargo pkg-config libssl-dev
git clone https://github.com/aws/efs-utils
cd efs-utils && ./build-deb.sh && sudo apt install -y ./build/amazon-efs-utils*.deb
```

**Step 5: Mount it**

```bash
sudo mkdir -p /mnt/efs

# Recommended: the EFS helper with encryption in transit (TLS)
sudo mount -t efs -o tls fs-0123456789abcdef0:/ /mnt/efs

# Alternative: plain NFS (no helper needed, no in-transit encryption)
sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport \
  fs-0123456789abcdef0.efs.us-east-1.amazonaws.com:/ /mnt/efs
```

**Step 6: Check it**

```bash
df -hT /mnt/efs
```

```
Filesystem                                   Type  Size  Used Avail Use% Mounted on
127.0.0.1:/                                  nfs4  8.0E     0  8.0E   0% /mnt/efs
```

Yes, that says **8.0E** = 8 exabytes. EFS reports a huge fake size because it has no fixed limit.

**Step 7: Make it permanent in `/etc/fstab`**

```
fs-0123456789abcdef0:/  /mnt/efs  efs  _netdev,tls,nofail  0  0
```

The `_netdev` option tells Linux "wait for the network before trying to mount this." Without it, boot can hang or the mount can fail because it's tried before networking is up. Then test with `sudo mount -a`.

**Step 8: Do the same on every other server**

That's the whole point. Mount the same file system on server #2, #3, #4, and they all see the same files instantly.

### 11.4 EFS access points (per-app front doors)

An **access point** is like a separate entrance into one EFS file system with its own root folder and forced user/group IDs. It lets you give each app or container its own sandbox without creating separate file systems.

```bash
aws efs create-access-point \
  --file-system-id fs-0123456789abcdef0 \
  --posix-user Uid=1000,Gid=1000 \
  --root-directory 'Path=/app1,CreationInfo={OwnerUid=1000,OwnerGid=1000,Permissions=755}'

# Mount through it
sudo mount -t efs -o tls,accesspoint=fsap-0123456789abcdef0 fs-0123456789abcdef0:/ /mnt/app1
```

### 11.5 EFS performance and cost knobs

- **Storage classes:** Standard (fast), Infrequent Access (cheaper, small fee per read), Archive (cheapest). A **lifecycle policy** moves files you haven't touched in N days to the cheaper tier automatically. Turn it on; it's usually a big saving.
- **Throughput mode:** **Elastic** (default; pay for what you use, scales instantly) is right for almost everyone. **Provisioned** is for steady, predictable heavy loads. **Bursting** is the legacy mode tied to size.
- **Performance mode:** General Purpose. (Max I/O is legacy and only for very specific workloads.)
- **One Zone:** about half price, but if that AZ has an outage your files are unreachable. Fine for dev/test or data you can rebuild.
- **Many tiny files are slow on any NFS.** If your app needs to open 100,000 tiny files, EFS will feel sluggish compared to EBS. Big files stream beautifully.

### 11.6 FSx for Lustre (HPC and ML speed)

Lustre is a parallel file system used by supercomputers. FSx for Lustre can link to an S3 bucket, so it looks like the bucket's files are already on disk.

```bash
# Install the client (Amazon Linux 2023)
sudo dnf install -y lustre-client

# Mount (values come from the FSx console: DNS name and mount name)
sudo mkdir -p /fsx
sudo mount -t lustre -o relatime,flock \
  fs-0123456789abcdef0.fsx.us-east-1.amazonaws.com@tcp:/abcdefgh /fsx

# fstab
fs-0123456789abcdef0.fsx.us-east-1.amazonaws.com@tcp:/abcdefgh /fsx lustre defaults,relatime,flock,_netdev,x-systemd.automount 0 0
```

Security group: Lustre uses **TCP 988** (and 1018-1023 for some versions).

### 11.7 FSx for Windows File Server (SMB) from Linux

```bash
sudo dnf install -y cifs-utils
sudo mkdir -p /mnt/winshare
sudo mount -t cifs //amznfsxabcd1234.corp.example.com/share /mnt/winshare \
  -o username=svc_account,password='S3cret!',domain=CORP,vers=3.0

# fstab (store the password in a file only root can read)
//amznfsxabcd1234.corp.example.com/share /mnt/winshare cifs credentials=/root/.smbcreds,vers=3.0,_netdev,nofail 0 0
```

Security group: **TCP 445**.

### 11.8 Mountpoint for S3 (see a bucket as a folder)

Mountpoint is AWS's official tool that presents an S3 bucket as a folder. It's great for reading big files and for writing *new* files, but it's not a normal file system: you can't edit an existing file in place, rename, or use it as a database disk.

```bash
# Install (Amazon Linux / RHEL)
sudo dnf install -y https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.rpm

# Mount (instance needs an IAM role with s3:GetObject / s3:PutObject / s3:ListBucket on the bucket)
sudo mkdir -p /mnt/s3data
mount-s3 my-bucket /mnt/s3data --allow-other

# Read-only and cache to a local disk for speed
mount-s3 my-bucket /mnt/s3data --read-only --cache /tmp/mp-cache

# Unmount
sudo umount /mnt/s3data
```

For general purpose read/write "S3 as a drive," consider **AWS Storage Gateway (File Gateway)** or **AWS DataSync** for scheduled copies instead.

### 11.9 Network-drive check commands

| Command | What it tells you |
|---|---|
| `df -hT` | Shows type `nfs4`, `efs`, `lustre`, or `cifs` for network mounts |
| `findmnt -t nfs4,nfs,cifs,lustre,fuse` | Only the network mounts |
| `nfsstat -m` | NFS mount options actually in use |
| `nfsstat -c` | NFS client stats (retransmits = network trouble) |
| `sudo ss -tnp \| grep 2049` | Is there an open NFS connection? |
| `nc -zv fs-xxxx.efs.us-east-1.amazonaws.com 2049` | Can I even reach the mount target? (Timeout = security group or route problem) |
| `dig fs-xxxx.efs.us-east-1.amazonaws.com` | Does DNS resolve? (Needs VPC DNS enabled) |
| `sudo journalctl -u amazon-efs-mount-watchdog` | EFS helper logs (TLS tunnel problems) |
| `sudo cat /var/log/amazon/efs/mount.log` | Detailed EFS mount log |
| `aws efs describe-file-systems --output table` | List EFS file systems, size, and state |
| `aws efs describe-mount-targets --file-system-id fs-xxx` | Mount targets and their state (must be `available`) |
| `aws fsx describe-file-systems --output table` | FSx file systems |

### 11.10 Common network-drive mistakes

- **Mount hangs:** port 2049 (EFS) / 988 (Lustre) / 445 (SMB) blocked, or the instance is in an AZ with no mount target. Test with `nc -zv`.
- **"Permission denied" writing to EFS:** the root of a new EFS file system is owned by root with mode 755. Either `sudo chown` it once, or use an access point that forces a UID/GID.
- **Boot hangs after adding a network mount to fstab:** missing `_netdev` or `nofail`.
- **Slow with many small files:** expected on NFS. Cache locally, batch operations, or use EBS for that workload.
- **Deleted the mount target while mounted:** every server freezes on that path. Unmount with `sudo umount -l /mnt/efs` (lazy unmount) to recover.

### Network drives: pros and cons

| | Pros | Cons |
|---|---|---|
| **EFS** | Shared, elastic, multi-AZ, no capacity planning, AWS Backup built in | Higher per-GB cost; latency higher than EBS; slow on tiny files; Linux only |
| **FSx for Lustre** | Fastest option by far; S3 integration | Expensive; specialized client; overkill for normal apps |
| **FSx for Windows** | Real SMB with AD; Windows apps "just work" | Needs Active Directory; Windows-flavored pricing |
| **Mountpoint for S3** | Cheapest storage; instant access to S3 data | Not POSIX: no in-place edits, no locking, no rename |

---

## 12. AWS CLI Deep Dive

The **AWS CLI** is a program you type commands into instead of clicking around the Console. It's faster once you learn it, you can script it, and every Console button has a matching CLI command.

### 12.1 Install and set up

```bash
# Amazon Linux 2023 has it preinstalled. Check:
aws --version        # want aws-cli/2.x

# Install v2 on other Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# macOS
brew install awscli
```

**Give it permission.** Two ways:

1. **IAM role on the instance (best).** Attach an IAM role to the EC2 instance with a policy allowing the EC2/EBS actions you need. No keys to leak. The CLI picks up the role automatically. This is what you should use on servers.
2. **Access keys on your laptop.** `aws configure` and paste an access key, secret key, default Region, and output format. Even better: `aws configure sso` if your company uses IAM Identity Center.

```bash
aws configure                 # sets ~/.aws/credentials and ~/.aws/config
aws configure set region us-east-1
aws sts get-caller-identity   # "who am I?" Great first test.
```

**Profiles** let you keep several accounts:

```bash
aws configure --profile prod
aws ec2 describe-volumes --profile prod
export AWS_PROFILE=prod       # or set it for the whole shell session
```

**Use the instance's own metadata** to avoid hard-coding IDs in scripts (IMDSv2 style):

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=${AZ%?}    # chop the last letter: us-east-1a -> us-east-1
echo $INSTANCE_ID $AZ $REGION
```

### 12.2 Reading the output: `--query`, `--output`, and `jq`

CLI answers come back as big JSON blobs. Tame them:

```bash
# Pretty table
aws ec2 describe-volumes --output table

# Pick only the fields you want (JMESPath query language)
aws ec2 describe-volumes \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Type:VolumeType,State:State,AZ:AvailabilityZone,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# Just one value, no quotes (great for scripts)
aws ec2 describe-volumes --volume-ids vol-0abc123 --query 'Volumes[0].Size' --output text

# Filter server-side with --filters
aws ec2 describe-volumes --filters Name=status,Values=available     # unattached (wasting money!)
aws ec2 describe-volumes --filters Name=tag:Env,Values=prod Name=volume-type,Values=gp2

# Same with jq if you prefer
aws ec2 describe-volumes | jq -r '.Volumes[] | "\(.VolumeId) \(.Size)GB \(.VolumeType) \(.State)"'
```

### 12.3 Volume commands (full reference)

```bash
# ---- Look ----
aws ec2 describe-volumes
aws ec2 describe-volumes --volume-ids vol-0abc123
aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=i-0123
aws ec2 describe-volume-status --volume-ids vol-0abc123          # health checks (ok / impaired)
aws ec2 describe-volumes-modifications --volume-ids vol-0abc123  # resize progress
aws ec2 describe-volume-attribute --volume-id vol-0abc123 --attribute autoEnableIO

# ---- Create ----
aws ec2 create-volume --availability-zone us-east-1a --size 100 --volume-type gp3 --encrypted \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=data1},{Key=Env,Value=prod}]'
aws ec2 create-volume --availability-zone us-east-1a --volume-type gp3 --iops 6000 --throughput 500 --size 500
aws ec2 create-volume --availability-zone us-east-1a --volume-type io2 --iops 20000 --size 1000
aws ec2 create-volume --availability-zone us-east-1a --snapshot-id snap-0123 --volume-type gp3

# ---- Attach / detach ----
aws ec2 attach-volume --volume-id vol-0abc123 --instance-id i-0123 --device /dev/sdf
aws ec2 detach-volume --volume-id vol-0abc123
aws ec2 detach-volume --volume-id vol-0abc123 --force      # last resort if the instance is hung

# ---- Modify (live) ----
aws ec2 modify-volume --volume-id vol-0abc123 --size 200
aws ec2 modify-volume --volume-id vol-0abc123 --volume-type gp3           # gp2 -> gp3 migration
aws ec2 modify-volume --volume-id vol-0abc123 --iops 10000 --throughput 750
aws ec2 modify-volume --volume-id vol-0abc123 --size 500 --volume-type io2 --iops 16000

# ---- Delete on termination flag ----
aws ec2 modify-instance-attribute --instance-id i-0123 \
  --block-device-mappings '[{"DeviceName":"/dev/sdf","Ebs":{"DeleteOnTermination":false}}]'

# ---- Tags ----
aws ec2 create-tags --resources vol-0abc123 --tags Key=Backup,Value=daily
aws ec2 delete-tags --resources vol-0abc123 --tags Key=Backup

# ---- Delete ----
aws ec2 delete-volume --volume-id vol-0abc123      # must be in "available" (detached) state

# ---- Wait for state changes in scripts ----
aws ec2 wait volume-available --volume-ids vol-0abc123
aws ec2 wait volume-in-use --volume-ids vol-0abc123
aws ec2 wait snapshot-completed --snapshot-ids snap-0123
```

### 12.4 Snapshot commands (full reference)

```bash
aws ec2 create-snapshot --volume-id vol-0abc123 --description "nightly"
aws ec2 create-snapshots --instance-specification InstanceId=i-0123,ExcludeBootVolume=true
aws ec2 describe-snapshots --owner-ids self
aws ec2 describe-snapshots --snapshot-ids snap-0123 --query 'Snapshots[0].Progress'
aws ec2 copy-snapshot --source-region us-east-1 --source-snapshot-id snap-0123 --region eu-west-1 --encrypted
aws ec2 modify-snapshot-attribute --snapshot-id snap-0123 --attribute createVolumePermission --operation-type add --user-ids 111122223333
aws ec2 describe-snapshot-attribute --snapshot-id snap-0123 --attribute createVolumePermission
aws ec2 enable-fast-snapshot-restores --availability-zones us-east-1a --source-snapshot-ids snap-0123
aws ec2 delete-snapshot --snapshot-id snap-0123
aws ec2 describe-snapshot-tier-status                       # archived snapshots
aws ec2 modify-snapshot-tier --snapshot-id snap-0123 --storage-tier archive    # move to cheap archive tier
```

### 12.5 Account-wide settings

```bash
# Turn on encryption by default for the Region
aws ec2 enable-ebs-encryption-by-default
aws ec2 get-ebs-encryption-by-default
aws ec2 modify-ebs-default-kms-key-id --kms-key-id alias/my-ebs-key

# Block public snapshot sharing (do this!)
aws ec2 enable-snapshot-block-public-access --state block-all-sharing
```

### 12.6 Handy one-line audits

```bash
# Unattached volumes (you're paying for these)
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Created:CreateTime}' --output table

# Still on gp2? Migrate them.
aws ec2 describe-volumes --filters Name=volume-type,Values=gp2 --query 'Volumes[].VolumeId' --output text

# Unencrypted volumes
aws ec2 describe-volumes --filters Name=encrypted,Values=false --query 'Volumes[].VolumeId' --output text

# Snapshots older than 90 days
aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[?StartTime<='$(date -d '90 days ago' +%Y-%m-%d)'].{ID:SnapshotId,Date:StartTime,Size:VolumeSize}" --output table

# Total GB of all your volumes
aws ec2 describe-volumes --query 'sum(Volumes[].Size)'
```

### 12.7 A complete script: add, format, and mount a volume automatically

```bash
#!/bin/bash
# add-volume.sh  -- run ON the instance, needs an IAM role with EC2 volume permissions
set -euo pipefail
SIZE=${1:-100}
MOUNT=${2:-/data}
DEVICE=/dev/sdf

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
MD="curl -s -H X-aws-ec2-metadata-token:$TOKEN http://169.254.169.254/latest/meta-data"
INSTANCE_ID=$($MD/instance-id)
AZ=$($MD/placement/availability-zone)
export AWS_DEFAULT_REGION=${AZ%?}

echo "Creating ${SIZE}G gp3 volume in $AZ..."
VOL=$(aws ec2 create-volume --availability-zone "$AZ" --size "$SIZE" --volume-type gp3 --encrypted \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$INSTANCE_ID-$(basename $MOUNT)}]" \
  --query VolumeId --output text)
aws ec2 wait volume-available --volume-ids "$VOL"

echo "Attaching $VOL..."
aws ec2 attach-volume --volume-id "$VOL" --instance-id "$INSTANCE_ID" --device "$DEVICE" >/dev/null
aws ec2 wait volume-in-use --volume-ids "$VOL"

# Find the NVMe device that matches this volume ID
for i in $(seq 1 30); do
  DEV=$(lsblk -dno NAME,SERIAL | awk -v v="${VOL/-/}" '$2==v {print "/dev/"$1}')
  [ -n "$DEV" ] && break; sleep 2
done
[ -z "$DEV" ] && { echo "Device not found"; exit 1; }
echo "Linux sees it as $DEV"

if [ "$(sudo file -s $DEV)" = "$DEV: data" ]; then
  sudo mkfs -t xfs -q "$DEV"
fi
sudo mkdir -p "$MOUNT"
sudo mount "$DEV" "$MOUNT"
UUID=$(sudo blkid -s UUID -o value "$DEV")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MOUNT xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
df -h "$MOUNT"
```

Run it: `bash add-volume.sh 200 /data`. (The `lsblk -o SERIAL` trick works because on Nitro instances the NVMe serial number equals the volume ID without the dash.)

### 12.8 A complete script: snapshot every volume on this instance

```bash
#!/bin/bash
# snap-me.sh -- snapshot all volumes attached to this instance, tag them, delete ones older than N days
set -euo pipefail
KEEP_DAYS=${1:-7}
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token:$TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token:$TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
export AWS_DEFAULT_REGION=${AZ%?}

sync   # flush file system buffers to disk first
aws ec2 create-snapshots --instance-specification InstanceId=$INSTANCE_ID \
  --description "auto $(date +%F)" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=AutoSnap,Value=$INSTANCE_ID}]" \
  --query 'Snapshots[].SnapshotId' --output text

CUTOFF=$(date -d "$KEEP_DAYS days ago" +%Y-%m-%dT%H:%M:%S)
for s in $(aws ec2 describe-snapshots --owner-ids self \
    --filters Name=tag:AutoSnap,Values=$INSTANCE_ID \
    --query "Snapshots[?StartTime<='$CUTOFF'].SnapshotId" --output text); do
  echo "Deleting old snapshot $s"; aws ec2 delete-snapshot --snapshot-id "$s"
done
```

Put it in cron for nightly backups: `0 2 * * * /usr/local/bin/snap-me.sh 7 >> /var/log/snap-me.log 2>&1`

### 12.9 EFS commands

```bash
aws efs create-file-system --encrypted --throughput-mode elastic --tags Key=Name,Value=shared
aws efs describe-file-systems --query 'FileSystems[].{ID:FileSystemId,Name:Name,SizeGB:SizeInBytes.Value,State:LifeCycleState}' --output table
aws efs create-mount-target --file-system-id fs-0123 --subnet-id subnet-0aaa --security-groups sg-0efs
aws efs describe-mount-targets --file-system-id fs-0123
aws efs put-lifecycle-configuration --file-system-id fs-0123 \
  --lifecycle-policies '[{"TransitionToIA":"AFTER_30_DAYS"},{"TransitionToArchive":"AFTER_90_DAYS"}]'
aws efs put-backup-policy --file-system-id fs-0123 --backup-policy Status=ENABLED
aws efs create-access-point --file-system-id fs-0123 --posix-user Uid=1000,Gid=1000 --root-directory Path=/app1
aws efs delete-mount-target --mount-target-id fsmt-0123
aws efs delete-file-system --file-system-id fs-0123
```

### 12.10 CLI pros and cons

| | Pros | Cons |
|---|---|---|
| **Console (clicking)** | Easy to learn; see everything visually | Slow to repeat; easy to misclick; not reproducible |
| **AWS CLI** | Fast, scriptable, works in cron and CI, same on every machine | Learning curve; JSON output takes practice; easy to run the wrong command in the wrong account (use profiles!) |
| **Terraform / IaC** (next section) | Reproducible, reviewable, version-controlled, can rebuild everything | Most to learn; state file to manage |

---

## 13. Terraform Examples

**Terraform** is a tool where you *describe* what you want ("one instance, a 100 GB gp3 volume attached at /dev/sdf, an EFS file system") in text files, and Terraform makes it real. Run it again and it only changes what's different. This is called **Infrastructure as Code (IaC)**. It's the grown-up way to manage AWS because your whole setup lives in files you can review, share, and put in git.

### 13.1 Install and the four commands you'll use forever

```bash
# Install (Amazon Linux / RHEL)
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo dnf install -y terraform

# macOS
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

terraform -version
```

| Command | What it does |
|---|---|
| `terraform init` | Downloads the AWS provider plugin. Run once per folder (and again if you add providers) |
| `terraform plan` | Shows what it *would* create/change/destroy. Always read this first |
| `terraform apply` | Does it (asks yes/no first) |
| `terraform destroy` | Deletes everything it created |
| `terraform fmt` | Tidies your code formatting |
| `terraform validate` | Checks for syntax mistakes |
| `terraform state list` | Lists what Terraform is managing |
| `terraform show` | Prints the current state in detail |

Terraform uses the same credentials as the AWS CLI (IAM role, `~/.aws/credentials`, or `AWS_PROFILE`).

### 13.2 Example 1: instance with a bigger root disk and one data volume

Create a folder, put these files in it, run `terraform init` then `terraform apply`.

**`versions.tf`**

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}
```

**`variables.tf`**

```hcl
variable "region"        { default = "us-east-1" }
variable "instance_type" { default = "t3.small" }
variable "data_size_gb"  { default = 100 }
variable "key_name"      { default = "my-keypair" }   # an existing EC2 key pair name
```

**`main.tf`**

```hcl
# Latest Amazon Linux 2023 AMI (no hard-coded ami-xxxx IDs)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Pick one subnet and remember its AZ so the volume lands in the same zone
data "aws_subnet" "chosen" {
  id = tolist(data.aws_subnets.default.ids)[0]
}

resource "aws_security_group" "ssh" {
  name   = "tutorial-ssh"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # narrow this to your IP in real life
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.chosen.id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.ssh.id]

  # The ROOT disk: make it 30 GB gp3 and encrypted instead of the 8 GB default
  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "app-root" }
  }

  # cloud-init script that formats and mounts the data disk on first boot
  user_data = file("${path.module}/mount-data.sh")

  tags = { Name = "tutorial-app" }
}

# A separate DATA volume, created in the same AZ as the instance
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.chosen.availability_zone
  size              = var.data_size_gb
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true
  tags              = { Name = "app-data", Backup = "daily" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id

  # Tell Terraform to unmount-safely style detach (stops the instance if needed) rather than force
  stop_instance_before_detaching = true
}
```

**`mount-data.sh`** (the user_data script; runs once at first boot as root)

```bash
#!/bin/bash
set -euo pipefail
MOUNT=/data

# Wait up to 2 minutes for the extra disk to show up
for i in $(seq 1 60); do
  DEV=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"' | awk '{print $1}' | while read d; do
          # skip the root disk (it has a mounted partition)
          lsblk -no MOUNTPOINT "$d" | grep -q '^/$' || echo "$d"; done | head -1)
  [ -n "$DEV" ] && break; sleep 2
done
[ -z "$DEV" ] && exit 1

if [ "$(file -s $DEV)" = "$DEV: data" ]; then
  mkfs -t xfs -q "$DEV"
fi
mkdir -p $MOUNT
UUID=$(blkid -s UUID -o value "$DEV")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID $MOUNT xfs defaults,nofail 0 2" >> /etc/fstab
mount -a
chown ec2-user:ec2-user $MOUNT
```

**`outputs.tf`**

```hcl
output "public_ip"   { value = aws_instance.app.public_ip }
output "data_volume" { value = aws_ebs_volume.data.id }
output "az"          { value = data.aws_subnet.chosen.availability_zone }
```

Run:

```bash
terraform init
terraform plan
terraform apply       # type yes
ssh -i my-keypair.pem ec2-user@$(terraform output -raw public_ip) df -h /data
```

**To grow the data volume later:** change `data_size_gb` to `200`, run `terraform apply`. Terraform calls Modify Volume for you. Then SSH in and run `sudo xfs_growfs /data` (Terraform can't reach inside the OS to do that part).

### 13.3 Example 2: EFS shared file system with mount targets in every AZ

**`efs.tf`**

```hcl
resource "aws_security_group" "efs" {
  name   = "tutorial-efs"
  vpc_id = data.aws_vpc.default.id
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ssh.id]   # only our instances may connect
  }
}

resource "aws_efs_file_system" "shared" {
  creation_token   = "tutorial-shared"
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
  lifecycle_policy {
    transition_to_archive = "AFTER_90_DAYS"
  }

  tags = { Name = "tutorial-shared" }
}

# One mount target per subnet/AZ
resource "aws_efs_mount_target" "shared" {
  for_each        = toset(data.aws_subnets.default.ids)
  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_backup_policy" "shared" {
  file_system_id = aws_efs_file_system.shared.id
  backup_policy { status = "ENABLED" }
}

resource "aws_efs_access_point" "app1" {
  file_system_id = aws_efs_file_system.shared.id
  posix_user {
    uid = 1000
    gid = 1000
  }
  root_directory {
    path = "/app1"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }
}

output "efs_id" { value = aws_efs_file_system.shared.id }
```

Then on any instance in that security group:

```bash
sudo dnf install -y amazon-efs-utils
sudo mkdir -p /mnt/efs
echo "$(terraform output -raw efs_id):/ /mnt/efs efs _netdev,tls,nofail 0 0" | sudo tee -a /etc/fstab
sudo mount -a
```

Or bake it into `user_data` with a template so it happens automatically:

```hcl
user_data = templatefile("${path.module}/mount-efs.sh.tftpl", {
  efs_id = aws_efs_file_system.shared.id
})
```

**`mount-efs.sh.tftpl`**

```bash
#!/bin/bash
dnf install -y amazon-efs-utils
mkdir -p /mnt/efs
echo "${efs_id}:/ /mnt/efs efs _netdev,tls,nofail 0 0" >> /etc/fstab
mount -a
```

### 13.4 Example 3: automatic daily snapshots with Data Lifecycle Manager

```hcl
resource "aws_iam_role" "dlm" {
  name = "dlm-lifecycle-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "daily" {
  description        = "Daily snapshots of volumes tagged Backup=daily, keep 7, copy to Oregon"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Backup = "daily" }

    schedule {
      name = "daily-2am"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["02:00"]
      }
      retain_rule { count = 7 }
      copy_tags = true
      tags_to_add = { SnapshotCreator = "DLM" }

      cross_region_copy_rule {
        target    = "us-west-2"
        encrypted = true
        retain_rule {
          interval      = 30
          interval_unit = "DAYS"
        }
      }
    }
  }
}
```

Any volume with the tag `Backup = daily` (like our `aws_ebs_volume.data`) is now backed up every night without you doing anything.

### 13.5 Example 4: one-off snapshot, copy it, restore a volume from it

```hcl
# Take a snapshot of the data volume
resource "aws_ebs_snapshot" "data_backup" {
  volume_id   = aws_ebs_volume.data.id
  description = "manual backup before upgrade"
  tags        = { Name = "app-data-backup" }
}

# Copy it to another Region (needs a second provider alias)
provider "aws" {
  alias  = "oregon"
  region = "us-west-2"
}

resource "aws_ebs_snapshot_copy" "data_backup_dr" {
  provider           = aws.oregon
  source_snapshot_id = aws_ebs_snapshot.data_backup.id
  source_region      = var.region
  encrypted          = true
  tags               = { Name = "app-data-backup-dr" }
}

# Restore: a brand-new (bigger) volume built from the snapshot
resource "aws_ebs_volume" "restored" {
  availability_zone = data.aws_subnet.chosen.availability_zone
  snapshot_id       = aws_ebs_snapshot.data_backup.id
  size              = 200          # can be larger than the snapshot
  type              = "gp3"
  tags              = { Name = "app-data-restored" }
}

resource "aws_volume_attachment" "restored" {
  device_name = "/dev/sdg"
  volume_id   = aws_ebs_volume.restored.id
  instance_id = aws_instance.app.id
}
```

After `apply`, SSH in and mount it (no `mkfs`; remember the XFS `nouuid` trick from Section 9.3):

```bash
lsblk
sudo mkdir -p /restore
sudo mount -o nouuid /dev/nvme2n1 /restore
```

### 13.6 Example 5: several data volumes from a list

```hcl
variable "extra_disks" {
  default = {
    logs = { size = 50,  device = "/dev/sdg" }
    db   = { size = 500, device = "/dev/sdh", iops = 6000, throughput = 500 }
  }
}

resource "aws_ebs_volume" "extra" {
  for_each          = var.extra_disks
  availability_zone = data.aws_subnet.chosen.availability_zone
  size              = each.value.size
  type              = "gp3"
  iops              = try(each.value.iops, 3000)
  throughput        = try(each.value.throughput, 125)
  encrypted         = true
  tags              = { Name = "app-${each.key}" }
}

resource "aws_volume_attachment" "extra" {
  for_each    = var.extra_disks
  device_name = each.value.device
  volume_id   = aws_ebs_volume.extra[each.key].id
  instance_id = aws_instance.app.id
}
```

### 13.7 Terraform tips and gotchas for storage

- **Never let Terraform destroy a data volume by accident.** Add a lifecycle guard:
  ```hcl
  resource "aws_ebs_volume" "data" {
    # ...
    lifecycle { prevent_destroy = true }
  }
  ```
  Now `terraform destroy` refuses until you remove the line on purpose.
- **Changing `availability_zone`, `snapshot_id`, or `encrypted` forces a brand-new volume** (Terraform will show `-/+` in the plan and delete the old one). Read every plan that touches storage.
- **`size`, `type`, `iops`, `throughput` change in place** (Modify Volume). Remember the 6-hour cooldown; a second apply within 6 hours will error.
- **Terraform can't run `xfs_growfs` for you.** Either do it by hand after growing, or add a tiny systemd service / cron job on the instance that runs `xfs_growfs` on every boot (it's harmless when there's nothing to grow).
- **Root volume changes.** Changing `root_block_device.volume_size` grows the root disk in place; Amazon Linux and Ubuntu cloud-init auto-grow the root file system on the next boot.
- **Device names.** You write `/dev/sdf` in Terraform; Linux still shows `nvme1n1`. Use the SERIAL-matching trick from Section 12.7 in scripts.
- **Keep your state file safe.** Use an S3 backend with locking:
  ```hcl
  terraform {
    backend "s3" {
      bucket       = "my-terraform-state"
      key          = "tutorial/terraform.tfstate"
      region       = "us-east-1"
      encrypt      = true
      use_lockfile = true
    }
  }
  ```
- **Import existing volumes** you made by hand so Terraform manages them:
  ```bash
  terraform import aws_ebs_volume.data vol-0abc123def456
  ```
- **Preview a resize without applying:** `terraform plan -var data_size_gb=200`.

### Terraform pros and cons

| | Pros | Cons |
|---|---|---|
| **Terraform** | Whole environment in reviewable files; repeatable; drift detection; works across clouds | Learning curve; state file must be protected; can't manage inside-the-OS steps like `mkfs`/`growfs` (use user_data or config management for those) |
| **CloudFormation** (AWS-native IaC) | No state file to manage; deep AWS integration | AWS-only; YAML/JSON is more verbose |
| **Hand-clicking** | Zero setup | Not repeatable; no history; easy to forget what you did |

---

## 14. Cheat Sheet: Commands to Check Things

### Space and disks

| Command | What it tells you |
|---|---|
| `df -h` | How much space is used/free on every mounted disk |
| `df -hT` | Same, plus file system type (xfs/ext4) |
| `df -i` | Inode usage (number of files; can fill up before space does) |
| `lsblk` | All disks and partitions, sizes, and where they're mounted |
| `lsblk -f` | Same, plus file system type and UUID |
| `sudo fdisk -l` | Detailed partition tables |
| `sudo blkid` | UUIDs and types for every disk |
| `sudo file -s /dev/nvme1n1` | Does this disk have a file system or is it blank? |
| `sudo nvme list` | Match NVMe device names to EBS volume IDs |

### What's taking up space?

| Command | What it tells you |
|---|---|
| `sudo du -sh /var/*` | Size of each folder inside `/var` |
| `sudo du -sh /* 2>/dev/null \| sort -h` | Size of every top-level folder, sorted smallest → biggest |
| `sudo du -ah /data \| sort -rh \| head -20` | The 20 biggest files/folders in `/data` |
| `sudo find / -size +500M 2>/dev/null` | Every file bigger than 500 MB |
| `sudo ncdu /` | Interactive space explorer (install with `dnf`/`apt install ncdu`) |

### Mounts

| Command | What it tells you |
|---|---|
| `mount` | Everything currently mounted (long list) |
| `findmnt` | Same info, as a neat tree |
| `findmnt /data` | Details for one mount point |
| `cat /etc/fstab` | What will be mounted at boot |
| `sudo mount -a` | Mount everything in fstab now (great for testing) |

### Health and activity

| Command | What it tells you |
|---|---|
| `iostat -xz 1` | Live disk read/write activity (install `sysstat` if missing) |
| `sudo dmesg \| grep -i nvme` | Kernel messages about disks (errors, new disks detected) |
| `sudo xfs_repair -n /dev/nvme1n1` | Check an **unmounted** XFS disk for errors (`-n` = look only, don't fix) |
| `sudo fsck -n /dev/nvme1n1` | Same for ext4 (**unmounted** only) |
| `sudo lsof +f -- /data` | What programs have files open on this disk |

### From the AWS side (CLI)

```bash
# List volumes attached to one instance
aws ec2 describe-volumes \
  --filters Name=attachment.instance-id,Values=i-0123456789abcdef0 \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Type:VolumeType,State:State}' \
  --output table

# Check progress of a resize
aws ec2 describe-volumes-modifications --volume-id vol-0abc123def456

# Take a snapshot (backup) before risky changes
aws ec2 create-snapshot --volume-id vol-0abc123def456 --description "before resize"
```

---

## 15. Volume Types: Pros and Cons

AWS offers several EBS volume types. Here's how to pick:

| Type | Best for | Pros | Cons |
|---|---|---|---|
| **gp3** (General Purpose SSD) | Almost everything. **Use this by default.** | Cheapest SSD; 3,000 IOPS and 125 MB/s included free; you can buy more speed separately from size | None for most people |
| **gp2** (older General Purpose SSD) | Nothing new; legacy only | Widely known | Costs ~20% more than gp3; speed is tied to size (small = slow). **Migrate gp2 → gp3** using Modify volume; it's free and instant |
| **io2 Block Express** (Provisioned IOPS SSD) | Big databases needing guaranteed high speed | Up to 256,000 IOPS; 99.999% durability; sub-millisecond latency | Expensive; overkill for most workloads |
| **st1** (Throughput HDD) | Big sequential files: logs, big-data, streaming | Cheap per GB for large files | Can't be a root volume; slow for small random reads; minimum 125 GB |
| **sc1** (Cold HDD) | Rarely-touched archive data | Cheapest EBS option | Slowest; can't be a root volume; minimum 125 GB |

**Simple rule:** Start with **gp3**. If a database team complains about speed, look at **io2**. If you're storing huge files you rarely read, look at **st1/sc1**.

### Key numbers (current limits)

- Max size per volume: **64 TiB** for gp3, io2, st1, sc1 (recently raised from 16 TiB; older accounts or regions may still show 16 TiB)
- gp3 baseline: 3,000 IOPS + 125 MB/s free; can pay to raise up to 80,000 IOPS and 2,000 MB/s
- You can change **size, type, IOPS, and throughput** live with Modify volume, then wait 6 hours before modifying again

---

## 16. File System Choices: ext4 vs XFS

| | **XFS** | **ext4** |
|---|---|---|
| Default on | Amazon Linux, RHEL, Rocky | Ubuntu, Debian |
| Grow while mounted? | Yes | Yes |
| **Shrink?** | **No** | Yes (but must unmount) |
| Big files / big disks | Excellent | Good |
| Many tiny files | Good | Slightly better |
| Grow command | `xfs_growfs /mountpoint` | `resize2fs /dev/device` |
| Check tool | `xfs_repair` | `fsck.ext4` |

**Advice:** Just use whatever your Linux distro defaults to. Both are rock-solid. If you specifically need to shrink a file system someday, ext4 is your only option (but on AWS you'd usually just make a new smaller volume anyway).

---

## 17. Best Practices

1. **Snapshot before you touch anything.** A snapshot is a backup of the whole volume. It takes seconds to start, costs pennies, and turns a disaster into a "no big deal." Console: Volumes → Actions → Create snapshot.
2. **Use gp3, not gp2.** Cheaper and faster. Convert old gp2 volumes with Modify volume.
3. **Turn on encryption** when creating volumes. It's free, invisible, and often required by company policy. (Tip: you can enable "encryption by default" for your whole region in EC2 → Settings → EBS encryption.)
4. **Always use UUIDs in `/etc/fstab`**, never device names.
5. **Always add `nofail`** in fstab for data volumes so a missing disk can't block booting.
6. **Test with `sudo mount -a` before rebooting.**
7. **Don't format a disk without checking `sudo file -s` first.** Once you `mkfs`, the old data is gone.
8. **Keep the root volume small and put big data on separate data volumes.** Easier to back up, resize, and move.
9. **Tag your volumes** with a `Name` so you can tell them apart in the Console. A page full of `vol-0a1b2c...` IDs is painful.
10. **Set up a CloudWatch alarm** or a simple cron job with `df -h` so you find out about a full disk *before* your app crashes.
11. **Enable Data Lifecycle Manager (DLM)** for automatic scheduled snapshots so you don't have to remember.
12. **Delete detached volumes you don't need.** AWS charges for them even when they're not attached to anything.
13. **Back up snapshots to a second Region** for anything you can't afford to lose (Section 9.2).
14. **Always `--dry-run` rsync first** and never `--delete` until you've checked the output.
15. **Turn off "Delete on termination" for data volumes** (Instance → Storage tab) if you want the data to outlive the instance.

---

## 18. Common Mistakes and How to Fix Them

### "I grew the volume in AWS but `df -h` still shows the old size"
You forgot to grow the partition and/or file system. Run `lsblk`: if the disk is bigger than the partition, run `growpart`. Then run `xfs_growfs` or `resize2fs`. See Section 2.

### "growpart says NOCHANGE"
The partition already fills the disk. Skip to the file system step.

### "xfs_growfs: not a mounted XFS filesystem"
You gave it a device (`/dev/nvme1n1`) instead of a folder (`/data`). XFS wants the mount point.

### "resize2fs: Bad magic number in super-block"
You ran `resize2fs` on an XFS file system. Use `xfs_growfs` instead. Check with `df -hT`.

### "mount: wrong fs type, bad option, bad superblock"
The disk has no file system yet (you skipped `mkfs`), or you wrote the wrong type in fstab. Check with `sudo file -s /dev/nvme1n1`.

### "The volume won't attach"
It's in a different Availability Zone than the instance. Take a snapshot, then create a new volume from that snapshot in the correct zone.

### "Server won't boot after I edited fstab"
A bad fstab line without `nofail` is blocking the boot. Fix: stop the instance, detach its root volume, attach it to a healthy instance as a data volume, mount it, fix `/etc/fstab`, unmount, detach, reattach to the original instance as `/dev/xvda` (or `/dev/sda1`), and boot. Alternatively, use **EC2 Serial Console** to get an emergency shell. This is why `nofail` and a backup copy of fstab matter.

### "Disk is 100% full but I deleted the big file and it's still full"
A program still has the deleted file open. Find it with `sudo lsof | grep deleted` and restart that program.

### "df -h says there's space but I get 'No space left on device'"
You ran out of **inodes** (file slots), not bytes. Check `df -i`. Usually caused by millions of tiny files, like a stuffed cache or mail spool.

### "Modify volume is greyed out / says try again later"
You changed this volume less than 6 hours ago. Wait it out.

---

## 19. Glossary

| Term | Plain-English meaning |
|---|---|
| **EC2** | A rented virtual computer in Amazon's data center |
| **EBS** | Elastic Block Store: Amazon's hard drives for EC2 |
| **Volume** | One EBS hard drive |
| **Root volume** | The drive Linux boots from, mounted at `/` |
| **Snapshot** | A saved copy (backup) of a volume at one moment in time |
| **Availability Zone (AZ)** | One physical data center building. Volumes and instances must be in the same one |
| **Partition** | A slice of a disk |
| **File system** | The organizing structure (ext4, XFS) that turns raw space into files and folders |
| **Mount** | Connect a disk to a folder so you can use it |
| **Mount point** | The folder where a disk is connected (like `/data`) |
| **fstab** | `/etc/fstab`, the list of disks Linux mounts at boot |
| **UUID** | A unique, permanent ID for a file system |
| **NVMe** | The fast disk interface modern EC2 uses; why disks are named `nvme0n1` |
| **IOPS** | Input/Output Operations Per Second: how many reads/writes a disk can do per second |
| **Throughput** | How many megabytes per second a disk can move |
| **Inode** | A "slot" for one file. Run out of inodes and you can't make new files even with free space |
| **sudo** | "Super-user do": run a command as administrator |
| **Instance Store** | Free temporary disk on some instances; wiped when the instance stops |
| **Nitro** | The hardware/software system under modern EC2 instances |
| **AMI** | Amazon Machine Image: a saved server template you can launch copies from |
| **DLM** | Data Lifecycle Manager: AWS's automatic snapshot scheduler |
| **rsync** | The go-to Linux tool for copying/syncing folders, locally or over SSH |
| **S3** | Amazon's object storage; a good middle stop for moving data |
| **EFS** | Elastic File System: a shared network folder many servers can mount at once |
| **NFS** | Network File System: the protocol EFS uses (port 2049) |
| **FSx** | AWS's family of managed high-performance file systems (Lustre, Windows, ONTAP, OpenZFS) |
| **Mount target** | EFS's network endpoint inside one Availability Zone |
| **AWS CLI** | The command-line program for controlling AWS |
| **IAM role** | A permission badge you attach to an instance so it can call AWS without stored keys |
| **Terraform** | A tool that builds AWS resources from text files (Infrastructure as Code) |
| **IaC** | Infrastructure as Code: describing servers and disks in files instead of clicking |
| **user_data** | A script EC2 runs automatically on an instance's first boot |
| **KMS key** | The encryption key AWS uses to lock a volume or snapshot |

---

*You made it! You now know how to grow, add, mount, check, and remove disks on EC2. Keep the cheat sheet in Section 14 handy; it's the part you'll come back to most.*
