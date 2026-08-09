# Deploying Apache NiFi 1.28 on AWS EC2 with the AWS CLI

A complete, copy-and-paste tutorial. You will end up with a running NiFi server
you can open in your browser, plus a set of shell scripts you can re-run,
share, or put in Git.

---

## 1. What are we actually building?

Think of **Apache NiFi** as a set of digital pipes. You drag boxes onto a
screen, connect them with arrows, and data starts flowing: pull a file off an
FTP server, rename it, filter out the bad rows, drop the result in S3. NiFi
does the moving, remembers every step, and retries when something breaks. The
whole thing is controlled from a web page.

**Amazon EC2** is a rented computer in Amazon's data center. You ask for one,
it appears in about 60 seconds, and you pay by the hour.

**The AWS CLI** is a program on your laptop that talks to Amazon by typing
commands instead of clicking in the web console. Commands can be saved in a
file, which means your setup is repeatable — that is the whole point of this
tutorial.

Here is the finished picture:

```
  Your laptop                    AWS region us-east-1
 ┌───────────┐   ┌──────────────────────────────────────────────────────┐
 │  AWS CLI  │   │  VPC  nifi-demo-vpc   10.20.0.0/16                   │
 │  browser  │   │                                                      │
 └─────┬─────┘   │   [Internet Gateway]                                 │
       │         │           │                                          │
       │  HTTPS  │   ┌───────┴────────────────────────────────┐         │
       └────────▶│   │ public route table  0.0.0.0/0 -> igw   │         │
        :8443    │   └───┬────────────────────────┬───────────┘         │
                 │       │                        │                     │
                 │  ┌────▼─────────────┐   ┌──────▼───────────┐         │
                 │  │ public-1  AZ-a   │   │ public-2  AZ-b   │         │
                 │  │ 10.20.1.0/24     │   │ 10.20.2.0/24     │         │
                 │  │  ┌────────────┐  │   │  (spare: ALB,    │         │
                 │  │  │ EC2        │  │   │   2nd node)      │         │
                 │  │  │ t3.large   │  │   └──────────────────┘         │
                 │  │  │ AL2023     │  │                                │
                 │  │  │ Java 11    │  │   ┌──────────────────┐         │
                 │  │  │ NiFi 1.28.1│  │   │ private-1 AZ-a   │         │
                 │  │  │ 40GB enc.  │  │   │ 10.20.11.0/24    │         │
                 │  │  └────────────┘  │   │ private-2 AZ-b   │         │
                 │  │  SG: 22,8443     │   │ 10.20.12.0/24    │         │
                 │  │  from YOUR ip    │   │ no internet route│         │
                 │  └──────────────────┘   └──────────────────┘         │
                 │            ▲ IAM role -> SSM (shell without SSH)     │
                 └────────────┼─────────────────────────────────────────┘
```

---

## 2. Read this before you start: which NiFi version?

**Apache NiFi 1.28 is the last minor release of the NiFi 1.x family.** The
final patch is **1.28.1** (November 2024). The project has moved on to the 2.x
line, which is where all new features and security fixes now go.

So use 1.28 **only** when you have a reason:

| Reason to stay on 1.28 | Reason to move to NiFi 2.x |
| --- | --- |
| You have existing 1.x flows using processors removed in 2.0 | Active development and security patches |
| A vendor product (older Cloudera CFM, etc.) requires 1.x | Python-based processors, rules engine, modern UI |
| You run Java 8 or 11 and cannot upgrade | Runs on Java 21, better performance |
| Your team knows the 1.x UI and you need it today | No migration debt piling up |

These scripts default to `1.28.1`. Set `NIFI_VERSION="1.28.0"` in the config
if you truly need that exact build.

> ⚠️ **Java matters here.** NiFi 1.x officially supports **Java 8 and Java 11
> only**. Java 17 or 21 will look like it works and then fail in strange ways.
> The scripts install Amazon Corretto 11. NiFi 2.x is the opposite — it
> *requires* Java 21.

---

## 3. Tools you need

| Tool | Why | Install |
| --- | --- | --- |
| AWS CLI **v2** | Talks to AWS | macOS `brew install awscli` · Linux: see AWS docs · Windows: MSI installer |
| `jq` | Reads JSON answers from AWS | `brew install jq` / `sudo dnf install jq` |
| `curl` | Health checks, IP lookup | Usually already there |
| `bash` 4+ | Runs the scripts | macOS ships bash 3.2 — `brew install bash` or use Linux/WSL |
| An AWS account | Somewhere to put the server | Free tier will *not* cover a t3.large |
| A web browser | The NiFi UI | Any modern one |

Windows users: run everything inside **WSL2** or Git Bash. These are bash
scripts, not PowerShell.

Set up credentials once:

```bash
aws configure                 # access key + secret + region
# or, for AWS SSO / IAM Identity Center:
aws sso login --profile my-profile
aws sts get-caller-identity   # should print your account number
```

**Permissions you need:** create/terminate EC2 instances, create security
groups and key pairs, create IAM roles and instance profiles, read SSM
parameters, and run SSM commands. `PowerUserAccess` plus IAM role creation is
enough in a sandbox account. In a locked-down account, ask your admin for
`ec2:*`, `iam:CreateRole`, `iam:PassRole`, `iam:CreateInstanceProfile`,
`ssm:GetParameters`, `ssm:SendCommand`, `ssm:StartSession`.

---

## 4. Part 1 — The 10-minute walkthrough

This is the one worked example. Do it exactly, then read Part 2 to learn what
each piece did.

### Step 0 — Get the scripts

```bash
unzip nifi-ec2-scripts.zip     # or copy the folder from this chat
cd nifi-ec2/scripts
chmod +x *.sh
ls
# 00-config.sh  01-preflight.sh  02-network.sh  03-launch.sh
# 04-verify.sh  05-set-credentials.sh  99-teardown.sh
# deploy-all.sh  user-data.sh.tmpl
```

### Step 1 — Edit the one file that matters

```bash
nano 00-config.sh
```

Change at minimum:

```bash
export AWS_REGION="us-east-1"                  # your region
export NIFI_PASSWORD="MyV3ry-L0ng-Pass!"       # 12+ characters, required
```

Everything else has a sensible default. This is the **only** file you edit;
the other scripts read their settings from it.

### Step 2 — Preflight (30 seconds, creates nothing)

```bash
./01-preflight.sh
```

It checks your tools, your credentials, that your password is long enough, and
that the NiFi download URL is alive. It also finds your public IP so the
firewall can be locked to just you.

### Step 3 — Build the network, key, firewall, and IAM role

```bash
./02-network.sh
```

This builds a **dedicated VPC** — it does not borrow your default one, so
nothing it creates or deletes can affect anything else in the account:

| Created | Value |
| --- | --- |
| VPC | `10.20.0.0/16`, with DNS support and DNS hostnames turned on |
| Internet gateway | attached to the VPC |
| Public subnets | `10.20.1.0/24` and `10.20.2.0/24`, in two different AZs, auto-assigning public IPs |
| Public route table | `0.0.0.0/0` → internet gateway, associated with both public subnets |
| Private subnets | `10.20.11.0/24` and `10.20.12.0/24`, in two AZs, no public IPs |
| Private route table | local routes only — deliberately no internet access |
| Key pair | ed25519, saved to `~/.ssh/nifi-demo-key.pem` with mode `400` |
| Security group | TCP 8443 and 22 **from your IP only** |
| IAM role + profile | so SSM can manage the box without any SSH key |

Why two of each subnet? NiFi itself only needs one, but almost anything you
add later — a load balancer, an RDS subnet group, a second cluster node —
requires two Availability Zones. Building them now costs nothing; subnets are
free.

The private subnets have **no NAT gateway**, so nothing in them can reach the
internet. That is deliberate: a NAT gateway costs about $32/month. Add one
only when you actually need outbound access from a private instance.

Prefer to use your existing default VPC instead? Set
`REUSE_DEFAULT_VPC="true"` in `00-config.sh`. Teardown will then leave the
VPC alone, since it is not ours to delete.

### Step 4 — Launch the server

```bash
./03-launch.sh
```

This renders the bootstrap script, looks up the newest Amazon Linux 2023 image,
and starts a `t3.large` with a 40 GB encrypted disk and IMDSv2 required. It
waits until EC2 reports healthy, then prints your URL.

### Step 5 — Wait for NiFi to install itself

```bash
./04-verify.sh --follow
```

The NiFi archive is about **1.2 GB**, so expect **5–10 minutes**. The script
polls until the UI answers. If you get bored:

```bash
./04-verify.sh --logs      # tails /var/log/nifi-bootstrap.log on the server
```

### Step 6 — Log in

Open the URL it printed:

```
https://<your-public-ip>:8443/nifi
```

- Your browser shows a **certificate warning**. This is expected — NiFi made
  its own self-signed certificate. Click *Advanced → Proceed*.
- Username: `admin` (or whatever you set)
- Password: your `NIFI_PASSWORD`

You should see the empty NiFi canvas.

### Step 7 — Prove it works with a 2-minute flow

1. Drag the **Processor** icon (top-left toolbar) onto the canvas.
2. Search `GenerateFlowFile`, add it. Double-click → **Scheduling** → set
   *Run Schedule* to `5 sec` → **Properties** → *Custom Text* = `hello nifi`.
3. Drag another processor: `LogAttribute`. Double-click → **Settings** → tick
   *Automatically Terminate Relationships: success*.
4. Hover over GenerateFlowFile, drag the arrow onto LogAttribute, click **Add**.
5. Select both (Ctrl+A) and press the **Start** ▶ button.

Watch the counters climb. To see the log entries:

```bash
aws ssm start-session --region us-east-1 --target <instance-id>
sudo tail -f /opt/nifi/current/logs/nifi-app.log
```

### Step 7b — Optional: real logins with Keycloak

The single shared password is fine for a lab, not for a team. The
`../keycloak` directory stands up a Keycloak identity server next to NiFi and
switches NiFi to single sign-on, so every person gets their own account:

```bash
cd ../keycloak
nano 00-kc-config.sh          # set your email and two passwords
./01-kc-launch.sh             # Keycloak on t3.small, in public subnet 2
./02-kc-verify.sh --follow
./03-nifi-oidc.sh             # backs NiFi up, then switches it over
```

Changed your mind? `./04-nifi-restore.sh` puts NiFi back exactly as it was,
from the backup `03-nifi-oidc.sh` made before touching anything. See
**keycloak/README.md** for the full walkthrough.

### Step 8 — Delete it all when you are done

```bash
./90-backup.sh              # save conf/flow.json.gz + snapshot the disk first
./99-teardown.sh --dry-run  # see the plan, change nothing
./99-teardown.sh            # type 'delete' to confirm
```

This removes, in dependency order: the instance, its disk, any Elastic IP,
orphan network interfaces, the security group, **all four subnets, the route
tables, the internet gateway and the VPC**, then the key pair and the IAM
objects — and finally re-queries AWS to prove nothing is left.

The VPC is only deleted because these scripts created it. If you set
`REUSE_DEFAULT_VPC="true"`, or pass `--keep-vpc`, the network is left intact.
Full details and the raw CLI equivalents are in **TEARDOWN.md**.

Not finished, just pausing? `./98-stop.sh` stops the instance (keeps your
flow, still pays for the disk) and `./98-stop.sh --start` brings it back.

> 💸 A `t3.large` costs roughly **$0.083/hour** (~$60/month) in `us-east-1`,
> plus about **$3.20/month** for the 40 GB gp3 disk and about **$3.60/month**
> for the public IPv4 address. A stopped instance still bills for its disk.
> Only a terminate stops everything.

---

## 5. Part 2 — What each script does

### `00-config.sh` — the settings file

Sourced by every other script. It also defines four tiny helpers used
throughout: `log`, `ok`, `warn`, `die`, plus `save_state` / `load_state`, which
write resource IDs into a hidden file called `.deploy-state`. That is how
`03-launch.sh` knows which security group `02-network.sh` created, and how
`99-teardown.sh` knows what to delete.

```bash
export AWS_PAGER=""   # without this, every AWS command opens "less". Annoying.
```

### `01-preflight.sh` — fail early, fail cheap

Checks are ordered from cheapest to most expensive. The password length check
is here on purpose: NiFi rejects passwords under 12 characters, and finding
that out *after* a 10-minute install is miserable.

### `02-network.sh` — the surroundings

Every step is **idempotent** — safe to run twice. It looks a thing up before
creating it, so a half-finished run can just be re-run.

Notable choices:

| Choice | Why |
| --- | --- |
| Build our own VPC | Deleting it later is then safe; deleting a shared default VPC is not |
| `--enable-dns-hostnames` | A hand-made VPC has this **off**, and without it the instance gets no public DNS name and SSM/package lookups turn flaky |
| A dedicated public route table | Editing the VPC's *main* table would be harder to unwind — the main table cannot be deleted |
| Two AZs | Load balancers and RDS subnet groups both demand it; subnets are free |
| Private subnets with no NAT | Ready for future use without the ~$32/month NAT gateway bill |
| `--key-type ed25519` | Shorter and stronger than RSA; supported by modern OpenSSH |
| firewall scoped to `YOUR.IP/32` | The single most important security decision here |
| IAM role with `AmazonSSMManagedInstanceCore` | Lets you get a shell without opening port 22 |
| `sleep 12` after creating the instance profile | IAM is *eventually consistent*; launching too fast throws "Invalid IAM Instance Profile" |

Each resource it creates is recorded in `.deploy-state` with a `CREATED_*`
flag. That flag is what teardown consults: **it deletes what it made, and
nothing else.**

### `03-launch.sh` — the launch

Three interesting details:

**Finding the AMI.** Never hard-code an AMI ID; they are region-specific and go
stale. Amazon publishes the current one as a public SSM parameter:

```bash
aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text
```

**IMDSv2 required.** `--metadata-options HttpTokens=required` forces the
token-based metadata service. This blocks a whole class of SSRF attacks where a
tricked web app reads the instance's credentials.

**User-data.** `--user-data file://build/user-data.sh` hands a shell script to
the new machine. Cloud-init runs it once, as root, on first boot. The hard
limit is 16 KB (ours is ~5 KB).

### `user-data.sh.tmpl` — the install itself

Nine labelled stages, all logged to `/var/log/nifi-bootstrap.log`:

1. **OS packages** — `unzip` is *not* on Amazon Linux 2023 by default.
2. **Java 11** — Corretto, because NiFi 1.x supports 8 and 11 only.
3. **Service account** — a `nifi` system user with no login shell. Never run
   NiFi as root; if a flow is compromised, root owns your whole machine.
4. **Download** — with `--retry 5`, because `archive.apache.org` rate-limits.
5. **Checksum** — compares SHA-512 against Apache's published value and aborts
   on mismatch. Do not skip this, ever.
6. **Install** — unzip to `/opt/nifi/nifi-1.28.1`, then symlink
   `/opt/nifi/current`. The symlink means upgrading later is a one-line switch.
7. **Configure** — the two settings people always get wrong:

   ```properties
   nifi.web.https.host=0.0.0.0
   nifi.web.proxy.host=localhost:8443,10.0.1.5:8443,54.x.x.x:8443,ec2-...:8443
   ```

   NiFi 1.x binds to `127.0.0.1` by default, so without the first line you get
   *connection refused* from outside. And NiFi refuses any request whose `Host`
   header it does not recognise, so without the second line you get a blank
   page or **"System Error"**. The script pulls the public IP and DNS name from
   instance metadata and lists both, with the port.

8. **Credentials** — `nifi.sh set-single-user-credentials <user> <pass>`.
9. **systemd** — a unit using `nifi.sh run` (foreground) rather than
   `nifi.sh start` (background). Foreground lets systemd genuinely supervise
   the process, so `Restart=on-failure` works. `SuccessExitStatus=143` stops
   systemd treating a normal SIGTERM shutdown as a crash.

### `04-verify.sh` — is it alive?

Uses **SSM Run Command** to execute shell commands on the instance without a
network connection from you to it. Note `curl -sk` — the `-k` skips
certificate validation, which is correct here only because we *know* the
certificate is self-signed.

### `90-backup.sh`, `98-stop.sh`, `99-teardown.sh`, `99b-force-cleanup.sh` — the way out

Destroying is not one command, it is an ordered sequence:

```
instance → volumes → Elastic IP → network interfaces → security group
 → subnets → route tables → internet gateway (detach, then delete) → VPC
 → key pair → IAM → snapshots → local state
```

AWS refuses to delete anything another resource still points at, so the order
is forced on you. The VPC goes last because everything else lives inside it.

`99-teardown.sh` runs that sequence with `--dry-run`, `--yes`, `--snapshots`,
`--keep-iam` and `--keep-vpc` flags, retries the security group, subnets and
VPC while network interfaces finish detaching, then verifies by re-querying
AWS. `99b-force-cleanup.sh` does the same by **tag** when the state file is
gone, optionally across every region.

**See TEARDOWN.md** for the full ordered explanation, the raw CLI commands, the
error messages you will hit, and a cost checklist.

---

## 6. Part 3 — The same thing, one command at a time

If you would rather type raw AWS CLI commands (to learn, or to adapt), here is
the equivalent sequence. Replace the bracketed values.

```bash
REGION=us-east-1
export AWS_PAGER=""

# --- 1. Build the VPC -----------------------------------------------------
VPC_ID=$(aws ec2 create-vpc --region $REGION --cidr-block 10.20.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=nifi-vpc}]' \
  --query Vpc.VpcId --output text)
aws ec2 wait vpc-available --region $REGION --vpc-ids $VPC_ID

# a hand-made VPC has DNS hostnames OFF; the instance needs them ON
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $VPC_ID --enable-dns-support  '{"Value":true}'
aws ec2 modify-vpc-attribute --region $REGION --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'

# --- 2. Internet gateway --------------------------------------------------
IGW_ID=$(aws ec2 create-internet-gateway --region $REGION \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=nifi-igw}]' \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --region $REGION \
  --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# --- 3. Two public subnets, in two AZs ------------------------------------
AZ1=$(aws ec2 describe-availability-zones --region $REGION \
  --query 'AvailabilityZones[0].ZoneName' --output text)
AZ2=$(aws ec2 describe-availability-zones --region $REGION \
  --query 'AvailabilityZones[1].ZoneName' --output text)

SUBNET_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID \
  --cidr-block 10.20.1.0/24 --availability-zone $AZ1 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=nifi-public-1}]' \
  --query Subnet.SubnetId --output text)
SUBNET2_ID=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID \
  --cidr-block 10.20.2.0/24 --availability-zone $AZ2 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=nifi-public-2}]' \
  --query Subnet.SubnetId --output text)

# "public" part 1: hand out public IPs automatically
aws ec2 modify-subnet-attribute --region $REGION --subnet-id $SUBNET_ID  --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --region $REGION --subnet-id $SUBNET2_ID --map-public-ip-on-launch

# "public" part 2: a route to the internet gateway
RTB_ID=$(aws ec2 create-route-table --region $REGION --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=nifi-public-rtb}]' \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --region $REGION --route-table-id $RTB_ID \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --region $REGION --route-table-id $RTB_ID --subnet-id $SUBNET_ID
aws ec2 associate-route-table --region $REGION --route-table-id $RTB_ID --subnet-id $SUBNET2_ID

# --- 4. Two private subnets (no internet route) ---------------------------
PRIV1=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID \
  --cidr-block 10.20.11.0/24 --availability-zone $AZ1 \
  --query Subnet.SubnetId --output text)
PRIV2=$(aws ec2 create-subnet --region $REGION --vpc-id $VPC_ID \
  --cidr-block 10.20.12.0/24 --availability-zone $AZ2 \
  --query Subnet.SubnetId --output text)
PRIV_RTB=$(aws ec2 create-route-table --region $REGION --vpc-id $VPC_ID \
  --query RouteTable.RouteTableId --output text)
aws ec2 associate-route-table --region $REGION --route-table-id $PRIV_RTB --subnet-id $PRIV1
aws ec2 associate-route-table --region $REGION --route-table-id $PRIV_RTB --subnet-id $PRIV2

# --- 5. Key pair ----------------------------------------------------------
aws ec2 create-key-pair --region $REGION --key-name nifi-key --key-type ed25519 \
  --query KeyMaterial --output text > ~/.ssh/nifi-key.pem
chmod 400 ~/.ssh/nifi-key.pem

# --- 6. Firewall ----------------------------------------------------------
MY_IP=$(curl -s https://checkip.amazonaws.com)
SG_ID=$(aws ec2 create-security-group --region $REGION \
  --group-name nifi-sg --description "NiFi" --vpc-id $VPC_ID \
  --query GroupId --output text)

aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID \
  --protocol tcp --port 8443 --cidr ${MY_IP}/32
aws ec2 authorize-security-group-ingress --region $REGION --group-id $SG_ID \
  --protocol tcp --port 22   --cidr ${MY_IP}/32

# --- 7. IAM role for SSM --------------------------------------------------
aws iam create-role --role-name nifi-role --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name nifi-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name nifi-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name nifi-profile --role-name nifi-role
sleep 15   # IAM propagation

# --- 8. Newest Amazon Linux 2023 image ------------------------------------
AMI_ID=$(aws ssm get-parameters --region $REGION \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)

# --- 9. Launch ------------------------------------------------------------
INSTANCE_ID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_ID --instance-type t3.large \
  --key-name nifi-key --subnet-id $SUBNET_ID --security-group-ids $SG_ID \
  --iam-instance-profile Name=nifi-profile --associate-public-ip-address \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":40,
      "VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
  --user-data file://user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nifi}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-status-ok --region $REGION --instance-ids $INSTANCE_ID

PUBLIC_IP=$(aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "https://${PUBLIC_IP}:8443/nifi"
```

And the manual version of what happens **on the box** (if you prefer SSH-ing in
and installing by hand instead of using user-data):

```bash
ssh -i ~/.ssh/nifi-key.pem ec2-user@$PUBLIC_IP

sudo dnf -y install unzip java-11-amazon-corretto-headless
sudo useradd --system --create-home --shell /sbin/nologin nifi

V=1.28.1
cd /tmp
curl -fLO https://archive.apache.org/dist/nifi/$V/nifi-$V-bin.zip
curl -fLO https://archive.apache.org/dist/nifi/$V/nifi-$V-bin.zip.sha512
sha512sum -c <(echo "$(cat nifi-$V-bin.zip.sha512 | sed 's/.*=//' | tr -d ' \n')  nifi-$V-bin.zip")

sudo unzip -q nifi-$V-bin.zip -d /opt/nifi
sudo ln -sfn /opt/nifi/nifi-$V /opt/nifi/current
sudo chown -R nifi:nifi /opt/nifi

sudo sed -i 's|^nifi.web.https.host=.*|nifi.web.https.host=0.0.0.0|' \
  /opt/nifi/current/conf/nifi.properties
sudo sed -i "s|^nifi.web.proxy.host=.*|nifi.web.proxy.host=${PUBLIC_IP}:8443|" \
  /opt/nifi/current/conf/nifi.properties
sudo sed -i 's|^java.arg.3=.*|java.arg.3=-Xmx2g|' \
  /opt/nifi/current/conf/bootstrap.conf

sudo runuser -u nifi -- /opt/nifi/current/bin/nifi.sh \
  set-single-user-credentials admin MyV3ry-L0ng-Pass!
sudo runuser -u nifi -- /opt/nifi/current/bin/nifi.sh start
tail -f /opt/nifi/current/logs/nifi-app.log
```

---

## 7. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Browser spins forever | Security group, or your IP changed (café, VPN, home router reboot) | `./01-preflight.sh` then `./02-network.sh` re-adds a rule for your new IP |
| `ERR_CONNECTION_REFUSED` | NiFi still binding to `127.0.0.1` | Check `nifi.web.https.host=0.0.0.0` in `nifi.properties`, restart |
| Blank page or **"System Error"** after login | `nifi.web.proxy.host` missing the name/IP you typed | Add `<host>:8443` to that property, `sudo systemctl restart nifi` |
| Login rejected | Password under 12 chars, or credentials set while NiFi was running | `./05-set-credentials.sh admin AnotherLongPass123` |
| Service dies after ~30 s | Wrong Java (17/21), or heap larger than RAM | `java -version` must say 11; lower `-Xmx` in `bootstrap.conf` |
| Download fails in user-data | `archive.apache.org` rate limit | Retry, or host the zip in your own S3 bucket and change `NIFI_MIRROR` |
| `Invalid IAM Instance Profile name` | Launched before IAM propagated | Wait 15 s and re-run `./03-launch.sh` |
| `UnauthorizedOperation` | Your IAM user lacks a permission | The message names the exact action — ask your admin for it |
| Public IP changed after stop/start | Normal for non-Elastic IPs | Set `ALLOCATE_EIP="true"`, or re-run the proxy-host fix |
| Disk full | Content/provenance repositories grew | Bigger volume, or shrink retention in `nifi.properties` |

Useful one-liners:

```bash
aws ssm start-session --region us-east-1 --target <instance-id>   # shell, no SSH
sudo systemctl status nifi
sudo journalctl -u nifi -f
sudo tail -100 /var/log/nifi-bootstrap.log
sudo tail -f /opt/nifi/current/logs/nifi-app.log
sudo tail -f /opt/nifi/current/logs/nifi-bootstrap.log
aws ec2 get-console-output --region us-east-1 --instance-id <id> --output text | tail -50
```

---

## 8. Best practices

**Security**

- Never open `8443` to `0.0.0.0/0`. The self-signed certificate and a single
  shared password are not internet-grade protection.
- Better still: give the instance **no public IP**, put it in a private subnet,
  and reach the UI through SSM port forwarding:

  ```bash
  aws ssm start-session --target <id> \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
  # then browse https://localhost:8443/nifi
  ```

- Keep secrets out of Git. `NIFI_PASSWORD` in `00-config.sh` is fine for a lab;
  in production pull it from **AWS Secrets Manager** inside user-data instead.
- Encrypt the EBS volume (done) and require IMDSv2 (done).
- Turn on **sensitive properties encryption**: set
  `nifi.sensitive.props.key` to a long random value *before* first start, so
  passwords inside your flow definitions are not stored weakly.

**Operations**

- Put NiFi's repositories on a **separate EBS volume** from the OS. The
  content and provenance repositories can fill a disk fast, and a full root
  volume takes the whole machine down.
- Back up `conf/flow.json.gz` (and `flow.xml.gz`) — that file *is* your
  dataflow. Copy it to S3 on a schedule.
- Even better, run **NiFi Registry** so flows are versioned like code.
- Snapshot the EBS volume with **AWS Backup** before every upgrade.
- Send `nifi-app.log` to **CloudWatch Logs** with the CloudWatch agent, and
  alarm on EC2 `StatusCheckFailed` plus disk usage.

**Sizing**

| Workload | Instance | Heap (`-Xmx`) | Disk |
| --- | --- | --- | --- |
| Learning / demo | `t3.large` (2 vCPU, 8 GB) | 2 GB | 40 GB gp3 |
| Small production | `m6i.xlarge` (4 vCPU, 16 GB) | 4–6 GB | 100 GB+ gp3, separate volume |
| Heavy throughput | `m6i.2xlarge`+ | 8–16 GB | provisioned-IOPS or multiple volumes |

Rule of thumb: heap no more than half of RAM, and rarely above 16 GB —
NiFi leans on the OS page cache and on disk, not on a giant heap. Avoid `t2`
burstable instances for sustained flows; you will run out of CPU credits.

---

## 9. Options and trade-offs

**Where to run NiFi**

| Option | Pros | Cons |
| --- | --- | --- |
| **Single EC2 instance** (this guide) | Simplest; full control; cheapest to start | One machine = one point of failure; you patch it |
| EC2 cluster (3+ nodes, ZooKeeper) | High availability, more throughput | Much more config; ZooKeeper to run; costs multiply |
| Containers (ECS/EKS) | Fits existing container platforms; easy image pinning | NiFi is stateful; persistent volumes and clustering get fiddly |
| Cloudera CFM / DataFlow | Vendor support and tooling | Licence cost; opinionated versions |
| AWS-native alternatives (Glue, MWAA, Step Functions, Kinesis) | Managed, no servers | Different model; rewriting flows; not drag-and-drop |

**How to install onto the instance**

| Option | Pros | Cons |
| --- | --- | --- |
| **User-data script** (this guide) | Nothing extra to install; readable; version-controllable | Runs once; 16 KB limit; ~8 min boot |
| Pre-baked AMI (Packer) | Boots in ~60 s; identical every time | Extra build pipeline; images to maintain |
| Ansible / Chef | Reusable across fleets; ongoing config drift control | Another tool and control node |
| CloudFormation / Terraform / CDK | Real state tracking, drift detection, easy multi-env | Steeper learning curve than plain CLI |

*The scripts here are deliberately plain CLI so you can see every API call.
For anything long-lived, port them to Terraform or CloudFormation.*

**Authentication**

| Option | Pros | Cons |
| --- | --- | --- |
| **Single user** (this guide) | Zero setup; works immediately | One shared account; no audit trail per person |
| OIDC (Cognito, Okta, Entra ID) | Real identities, MFA, central control | Requires a real DNS name and certificate |
| LDAP / Active Directory | Uses existing corporate accounts | LDAP config is fiddly |
| Client certificates | Very strong; used for node-to-node | Certificate distribution is a chore |

**Certificates**

| Option | Pros | Cons |
| --- | --- | --- |
| **Self-signed** (this guide) | Automatic, free, encrypted on the wire | Browser warnings; no identity guarantee |
| ACM certificate on an ALB in front | Trusted cert, clean DNS name, WAF options | ALB costs ~$16/month; extra `nifi.web.proxy.host` config |
| Let's Encrypt on the instance | Free and trusted | Needs port 80 open and a real domain; renewal cron |

---

## 10. Background: how NiFi is put together

A little vocabulary makes the config files readable.

- **FlowFile** — one piece of data moving through the system: the content plus
  attributes (filename, size, anything you add). Think of an envelope.
- **Processor** — a box that does one job: fetch, transform, route, publish.
  NiFi 1.28 ships hundreds.
- **Connection** — the arrow between processors. It is a real queue with
  back-pressure: when it fills up, the upstream processor pauses instead of
  crashing.
- **Process Group** — a folder of processors, so big flows stay readable.
- **Controller Service** — shared config, like a database connection pool.
- **Provenance** — NiFi's record of every event for every FlowFile. This is
  its superpower and also why the disk fills.

**Directories that matter** (under `/opt/nifi/current`):

| Path | What lives there |
| --- | --- |
| `conf/nifi.properties` | The main settings file |
| `conf/bootstrap.conf` | JVM settings, including heap |
| `conf/flow.json.gz` | Your actual dataflow — back this up |
| `logs/nifi-app.log` | The log you read when something is wrong |
| `content_repository/` | The bytes of in-flight data |
| `flowfile_repository/` | Attributes and queue state |
| `provenance_repository/` | The history; usually the biggest |
| `bin/nifi.sh` | `start`, `stop`, `restart`, `run`, `status`, `set-single-user-credentials` |

**Ports:** `8443` HTTPS UI and REST API (1.x also supports plain HTTP on 8080,
which the scripts deliberately disable). Clustered setups add ports for
cluster protocol, load balancing, and Site-to-Site.

**What "single user" mode actually does:** on first start with no security
configured, NiFi generates a self-signed certificate, turns on HTTPS, and
prints a random username and password into `nifi-app.log`. Because that is
awkward to automate, the scripts run `set-single-user-credentials` during boot
so you know the login in advance.

---

## 11. Upgrading later

Because the install uses a symlink, moving to a new 1.x patch is short:

```bash
sudo systemctl stop nifi
cd /tmp && curl -fLO https://archive.apache.org/dist/nifi/1.28.1/nifi-1.28.1-bin.zip
sudo unzip -q nifi-1.28.1-bin.zip -d /opt/nifi
# copy your settings across, then:
sudo cp -r /opt/nifi/nifi-1.28.0/conf/flow.json.gz /opt/nifi/nifi-1.28.1/conf/
sudo chown -R nifi:nifi /opt/nifi
sudo ln -sfn /opt/nifi/nifi-1.28.1 /opt/nifi/current
sudo systemctl start nifi
```

Going from **1.28 to 2.x is a migration, not an upgrade**: some processors
were removed, and 2.x needs Java 21. Read the project's "Migrating Deprecated
Components" notes first, test on a separate instance, and keep 1.28 running
until the new flows pass.

---

## 12. Where to go next

- **keycloak/** — swap the shared password for per-person single sign-on with
  Keycloak, with a one-command path back to the original login
- **TEARDOWN.md** — the ordered destroy, explained, with raw CLI equivalents

## 13. Cheat sheet

```bash
# deploy
./01-preflight.sh && ./02-network.sh && ./03-launch.sh && ./04-verify.sh --follow
./deploy-all.sh                       # same thing in one command

# day to day
./04-verify.sh                        # status
./04-verify.sh --logs                 # logs
./05-set-credentials.sh admin NewLongPassword1

# on the box
aws ssm start-session --region us-east-1 --target <instance-id>
sudo systemctl restart nifi

# pause the bill (disk still charged) / resume
./98-stop.sh                          # graceful NiFi stop, then instance stop
./98-stop.sh --start                  # start + auto-fix nifi.web.proxy.host

# destroy, in order
./90-backup.sh                        # flow.json.gz + EBS snapshot first
./99-teardown.sh --dry-run            # show the plan only
./99-teardown.sh                      # interactive
./99-teardown.sh --yes --snapshots    # unattended, delete snapshots too
./99b-force-cleanup.sh --all-regions  # sweep by tag when state is lost
```
