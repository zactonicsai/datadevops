## In the AWS Console

**1. Note the instance's AZ**
EC2 → Instances → select your instance → Details tab → **Availability Zone** (e.g. `us-east-1a`).

**2. Create the volume**
EC2 → left sidebar **Elastic Block Store → Volumes** → **Create volume**
- Volume type: `gp3`
- Size: `500` GiB
- Availability Zone: must match step 1
- Tags: add `Name = data-vol` (optional but helps)
- **Create volume**

**3. Attach it**
Select the new volume (wait for state `Available`) → **Actions → Attach volume**
- Instance: pick yours from the dropdown
- Device name: leave the default (`/dev/sdf`)
- **Attach**

State should change to `In-use`.

## On the instance (SSH or Session Manager)

Console can't format or mount — that part is always on the box.

```bash
lsblk
```

Find the 500G disk with no mountpoint. On Nitro instances it appears as `/dev/nvme1n1`, not `/dev/sdf`.

```bash
sudo mkfs -t xfs /dev/nvme1n1
sudo mkdir -p /data
sudo mount /dev/nvme1n1 /data
```

Then persist it:

```bash
sudo blkid /dev/nvme1n1
echo 'UUID=<uuid>  /data  xfs  defaults,nofail  0  2' | sudo tee -a /etc/fstab
sudo mount -a
```

Run `mkfs` only on the new empty volume, and confirm `mount -a` succeeds before rebooting.