AWS Amazon Linux 2023 Patching: A Complete Guide

Let me explain how to patch (update and fix) Amazon Linux 2023 servers, step by step, like you’re learning it for the first time.

Background: What Is Patching and Why Does It Matter?

Think of your server like a phone. Apps get updates that fix bugs and security holes. Patching is the same idea — updating the software on a Linux server so hackers can’t sneak in through known weaknesses.

A security patch release is a bundle of fixes that closes those holes. Skipping patches is like leaving your front door unlocked.

Amazon Linux 2023 (AL2023) is Amazon’s own version of Linux, built to run smoothly on AWS. It’s the successor to Amazon Linux 2.

Key Concept: How AL2023 Is Different (This Is Important)

AL2023 introduced a big change called “deterministic upgrades through versioned repositories.” Here’s what that means in plain language:

In old systems, typing “update everything” pulled the newest version of every package, which could surprise you. AL2023 instead locks every server to a specific repository version — like freezing a snapshot in time. Two servers locked to the same version will always get the exact same packages. This makes patching predictable and repeatable.

This is the single most important AL2023-specific idea, so keep it in mind.

The Tools You’ll Use



|Tool                                       |What it does                                                                                                             |
|-------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
|**dnf**                                    |The main package manager in AL2023 (replaces the old `yum`). `yum` still works as an alias, but `dnf` is the real engine.|
|**dnf history**                            |Shows past changes and lets you undo them.                                                                               |
|**needs-restarting**                       |Tells you if a reboot is required after patching.                                                                        |
|**AWS Systems Manager (SSM) Patch Manager**|Patches many servers at once from the AWS console — no logging in one by one.                                            |
|**rpm**                                    |Inspects individual installed packages.                                                                                  |

PART 1: Patching One Server by Hand (Step by Step)

Step 1 — Connect to your server

ssh ec2-user@your-server-ip


Step 2 — See what version you’re locked to

dnf --version


The bottom shows your releasever (the version lock), something like 2023.4.20240319.

Step 3 — Check what updates are available (the “diff”)

This is your diff — comparing what you have now versus what’s available.

# List all available updates
dnf check-update

# See ONLY security updates
dnf check-update --security

# Get a summary count of security fixes
dnf updateinfo summary --security


How to read this: Each line shows a package name, the new version, and the repository it comes from. If nothing prints after check-update, you’re fully patched.

To see details about what a security update fixes:

dnf updateinfo list --security


Step 4 — Apply ONLY security patches

This is the safest, most common task — fix security holes without touching everything else.

sudo dnf upgrade --security


To confirm before it runs, it lists everything and waits for you to type y.

Step 5 — (Alternative) Upgrade everything

sudo dnf upgrade


Step 6 — The AL2023 special move: lock to a specific version

Because AL2023 uses versioned repos, you can patch to an exact known-good release:

# Upgrade to a specific repository version
sudo dnf upgrade --releasever=2023.4.20240416


This is how teams make sure dev, test, and production servers are identical. This is a core AL2023 capability that older Linux versions didn’t have.

To see which versions exist:

dnf check-release-update


Step 7 — Check if you need to reboot

Some updates (like the Linux kernel) only take effect after a restart.

# Is a reboot needed?
needs-restarting -r

# Which specific services need restarting?
needs-restarting -s


If it says a reboot is required:

sudo reboot


PART 2: How to VERIFY the Patch Worked

Don’t just trust that it worked — verify. Here’s your checklist.

Verify 1 — Re-run the diff (should be empty now)

dnf check-update --security


If nothing shows up, your security patches are applied.

Verify 2 — Look at the history log

# See the list of all transactions
sudo dnf history

# See full details of the most recent one
sudo dnf history info last


This shows exactly what was upgraded, when, and the command used.

Verify 3 — Confirm a specific package version

Say a security alert was about openssl. Check it directly:

rpm -q openssl


Compare the number shown against the fixed version in the security bulletin.

Verify 4 — Confirm the kernel after reboot

uname -r


This shows the running kernel. Make sure it matches the patched version, not the old one.

Verify 5 — Make sure nothing broke

# Check that important services are still running
systemctl status sshd
systemctl --failed     # lists anything that failed to start


PART 3: The Safety Net — Undoing a Bad Patch

If a patch breaks something, AL2023 lets you roll back.

# Find the transaction ID you want to undo
sudo dnf history

# Undo that specific transaction (e.g., ID 15)
sudo dnf history undo 15

# Or roll the whole system back to how it was at transaction 12
sudo dnf history rollback 12


Pro tip: Before patching production, take an EBS snapshot or AMI backup so you have a full machine-level restore point:

aws ec2 create-image \
  --instance-id i-0abc123def456 \
  --name "before-patch-$(date +%Y%m%d)" \
  --no-reboot


PART 4: Patching MANY Servers at Once (AWS Systems Manager)

Logging into 200 servers by hand is impossible. SSM Patch Manager does it for you from the AWS console.

How it works (the big picture)

	1.	Patch Baseline — a rulebook saying which patches to install (e.g., “only Critical and Important security patches, and wait 7 days after release”).
	2.	Patch Group — a label (tag) on your servers that ties them to a baseline.
	3.	Maintenance Window — a scheduled time to patch (e.g., Sunday 2 AM) so it doesn’t disrupt users.

Step 1 — Tag your servers into a patch group

aws ec2 create-tags \
  --resources i-0abc123def456 \
  --tags Key=Patch Group,Value=Production-AL2023


Step 2 — Scan servers to see what’s missing (this is the fleet-wide “diff”)

aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=tag:Patch Group,Values=Production-AL2023" \
  --parameters "Operation=Scan"


Operation=Scan only checks — it doesn’t install anything yet.

Step 3 — Install the patches

aws ssm send-command \
  --document-name "AWS-RunPatchBaseline" \
  --targets "Key=tag:Patch Group,Values=Production-AL2023" \
  --parameters "Operation=Install"


Step 4 — Verify across the whole fleet

# Summary of compliant vs non-compliant servers
aws ssm describe-patch-group-state \
  --patch-group "Production-AL2023"

# Detailed compliance for one instance
aws ssm describe-instance-patch-states \
  --instance-ids i-0abc123def456


A server marked “Compliant” means it has all the patches your baseline requires.

PART 5: Limits and Gotchas (Real-World Cautions)

These are the things that trip people up:

Repository version limits. AWS keeps older AL2023 repository versions available, but very old snapshots may eventually age out. Don’t lock servers to an ancient version forever — plan to move forward periodically.

Reboots aren’t automatic. dnf upgrade --security installs the patch, but kernel fixes don’t activate until you reboot. A server can look “patched” but still be running the vulnerable kernel until restart.

--security depends on metadata. The security filter only works if AWS has tagged a package with security info. If a fix isn’t labeled as security-related, --security may skip it — sometimes a plain dnf upgrade is needed.

SSM requires the agent and IAM role. SSM Patch Manager only works if the server has the SSM Agent running (pre-installed on AL2023) and an IAM instance role with SSM permissions attached. No role, no patching.

Locked packages. If someone used dnf versionlock to pin a package, patches will skip it. Check with:

dnf versionlock list


Test first. Always patch a non-production “canary” server first, verify nothing breaks, then roll out to production using the same --releasever version.

Quick Reference: The Whole Workflow

# 1. DIFF — what's missing?
dnf check-update --security

# 2. BACKUP — safety net
aws ec2 create-image --instance-id i-xxx --name "pre-patch" --no-reboot

# 3. PATCH — apply security fixes
sudo dnf upgrade --security

# 4. REBOOT — if needed
needs-restarting -r && sudo reboot

# 5. VERIFY — confirm success
dnf check-update --security      # should be empty
sudo dnf history info last       # what changed
uname -r                         # kernel version
systemctl --failed               # nothing broken


Since patching details and AL2023 repository behavior do get updated by AWS over time, would you like me to search for the very latest official AWS documentation to confirm current version limits and any new commands? I answered from established knowledge here, but I can verify the freshest specifics if this is for production use.