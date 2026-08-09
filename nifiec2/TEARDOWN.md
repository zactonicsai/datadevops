# TEARDOWN — Destroying the NiFi Stack, in Order

Everything you built has to come down in a specific order. This document
explains that order, gives the scripts, and gives the raw AWS CLI commands if
you would rather type them yourself.

---

## 1. Why order matters

AWS will not delete a thing while another thing is still holding onto it. If
you try, you get errors like `DependencyViolation` or `DeleteConflict`.

The chain looks like this — arrows mean "depends on":

```
   VPC ◀── subnet ◀── network interface ◀── EC2 instance ──▶ EBS volume
    ▲        ▲                                    ▲
    │        └── route table association          └── Elastic IP
    ├── route table
    ├── internet gateway   (must be DETACHED before deletion)
    └── security group

   IAM role ◀── instance profile ◀── EC2 instance
```

So you always work from the **outside in**: kill the instance first, wait for
it to *actually* be gone, then unpick everything that was attached to it. The
VPC — which everything else lives inside — goes last.

**The correct order:**

| # | Delete | Why here |
| --- | --- | --- |
| 0 | *(back up first)* | The disk is destroyed in step 1 and does not come back |
| 1 | EC2 instance | Everything else is attached to it |
| 2 | Leftover EBS volumes | Only survive if `DeleteOnTermination=false` |
| 3 | Elastic IP | **Billed hourly even when unattached** — never forget this one |
| 4 | Orphan network interfaces | Blocks both the security group *and* the subnet |
| 5 | Security group | Cannot be deleted while an ENI uses it |
| 6 | Subnets | Cannot be deleted while anything lives in them |
| 7 | Route tables | Must be disassociated first; the **main** table can't be deleted at all |
| 8 | Internet gateway | **Detach from the VPC, then delete** — two separate calls |
| 9 | VPC | Only once it is empty. Its default SG, main route table and NACL go automatically |
| 10 | Key pair | Independent; tidy up the `.pem` on your laptop too |
| 11 | Instance profile, then role | Role must leave the profile before either can go |
| 12 | Snapshots (optional) | Your only rollback — delete on purpose, not by accident |

> 🛡️ **The VPC is only deleted if the scripts created it.** `02-network.sh`
> records `CREATED_VPC=true` in `.deploy-state` when it builds one. If you set
> `REUSE_DEFAULT_VPC="true"`, teardown skips steps 6–9 entirely and your
> default VPC is never touched. `--keep-vpc` forces the same behaviour.

---

## 2. If you added Keycloak

Tear Keycloak down **before** the main stack, because its script restores
NiFi's original login first — deleting the identity server while NiFi still
points at it leaves a NiFi nobody can enter:

```bash
cd ../keycloak
./99-kc-teardown.sh --dry-run
./99-kc-teardown.sh
```

Forgot, and did the main teardown first? Everything is deleted either way —
the Keycloak instance carries the same `Project=nifi-demo` tag, and step 5
removes every non-default security group in the VPC. You just lose the chance
to restore NiFi's old config, which no longer matters once NiFi is gone.

## 3. The scripts

```bash
cd nifi-ec2/scripts

./90-backup.sh                 # 1. save flow.json.gz + take an EBS snapshot
./99-teardown.sh --dry-run     # 2. see exactly what would be deleted
./99-teardown.sh               # 3. do it (asks you to type 'delete')
```

| Script | What it does |
| --- | --- |
| `90-backup.sh` | Pulls `conf/flow.json.gz`, `nifi.properties`, users/authorizations down to `./backups/<timestamp>/`, and starts an EBS snapshot. Optional S3 upload: `./90-backup.sh s3://my-bucket` |
| `98-stop.sh` | **Not** a delete. Stops the instance so compute billing pauses; `--start` brings it back and repairs `nifi.web.proxy.host` for the new IP |
| `99-teardown.sh` | The ordered destroy, including the VPC it built. Flags: `--dry-run`, `--yes`, `--snapshots`, `--keep-iam`, `--keep-vpc` |
| `99b-force-cleanup.sh` | Finds resources by **tag** instead of the state file, VPC and subnets included. For when you lost `.deploy-state`, deployed twice, or something is still billing. `--all-regions` scans everywhere |

### Stop vs. terminate — pick the right one

| | Compute charge | Disk charge | Your flow | Public IP |
| --- | --- | --- | --- | --- |
| `./98-stop.sh` | stops | **still billed** (~$3.20/mo for 40 GB) | kept | changes on restart (unless Elastic IP) |
| `./99-teardown.sh` | stops | stops | **gone** | released |

If you are coming back tomorrow, stop it. If you are done, tear it down.

### Dry run first, always

```bash
./99-teardown.sh --dry-run
```

Prints the plan and every command it *would* run, and changes nothing. Read it,
then run for real.

### Full non-interactive destroy (CI, or you are certain)

```bash
./99-teardown.sh --yes --snapshots
```

`--snapshots` also deletes the EBS snapshots. Without it, snapshots survive on
purpose — they are the only way back.

### The sweeper

```bash
./99b-force-cleanup.sh --dry-run --all-regions
```

Scans every enabled region for anything tagged `Project=nifi-demo`. Slow
(about a minute) but it is the honest answer to "am I still paying for
something?"

---

## 4. The same thing as raw AWS CLI commands

Set these once:

```bash
REGION=us-east-1
export AWS_PAGER=""

INSTANCE_ID=i-0123456789abcdef0
SG_ID=sg-0123456789abcdef0
KEY_NAME=nifi-demo-key
ROLE=nifi-demo-role
PROFILE=nifi-demo-instance-profile
```

Do not know the IDs? Find them by tag:

```bash
aws ec2 describe-instances --region $REGION \
  --filters Name=tag:Project,Values=nifi-demo \
            Name=instance-state-name,Values=running,stopped \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PublicIpAddress]' \
  --output table

aws ec2 describe-security-groups --region $REGION \
  --filters Name=group-name,Values=nifi-demo-sg \
  --query 'SecurityGroups[].GroupId' --output text
```

### Step 0 — Back up (skip only if you truly do not care)

```bash
# a) copy the dataflow definition off the box
aws ssm start-session --region $REGION --target $INSTANCE_ID
  sudo cp /opt/nifi/current/conf/flow.json.gz /tmp/
  sudo chmod 644 /tmp/flow.json.gz
  aws s3 cp /tmp/flow.json.gz s3://my-bucket/nifi-backups/
  exit

# b) or snapshot the whole disk
VOL_ID=$(aws ec2 describe-instances --region $REGION --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
aws ec2 create-snapshot --region $REGION --volume-id $VOL_ID \
  --description "nifi pre-teardown" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Project,Value=nifi-demo}]'
```

### Step 1 — Stop NiFi cleanly, then terminate the instance

```bash
# graceful application shutdown (lets NiFi checkpoint its queues)
aws ssm send-command --region $REGION --instance-ids $INSTANCE_ID \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl stop nifi"]'
sleep 30

# clear termination protection in case it was ever enabled
aws ec2 modify-instance-attribute --region $REGION \
  --instance-id $INSTANCE_ID --no-disable-api-termination

# terminate, then WAIT — the next steps fail if you rush
aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --region $REGION --instance-ids $INSTANCE_ID
```

### Step 2 — Any volume that survived

```bash
aws ec2 describe-volumes --region $REGION \
  --filters Name=tag:Project,Values=nifi-demo Name=status,Values=available \
  --query 'Volumes[].VolumeId' --output text

aws ec2 delete-volume --region $REGION --volume-id vol-0123456789abcdef0
```

### Step 3 — Elastic IP (the expensive one to forget)

```bash
aws ec2 describe-addresses --region $REGION \
  --filters Name=tag:Project,Values=nifi-demo \
  --query 'Addresses[].[AllocationId,AssociationId,PublicIp]' --output table

aws ec2 disassociate-address --region $REGION --association-id eipassoc-0123...
aws ec2 release-address     --region $REGION --allocation-id  eipalloc-0123...
```

### Step 4 — Orphan network interfaces

```bash
aws ec2 describe-network-interfaces --region $REGION \
  --filters Name=group-id,Values=$SG_ID Name=status,Values=available \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text

aws ec2 delete-network-interface --region $REGION --network-interface-id eni-0123...
```

### Step 5 — Security group (retry; ENI cleanup lags)

```bash
aws ec2 delete-security-group --region $REGION --group-id $SG_ID

# if it says DependencyViolation, wait and try again:
for i in $(seq 1 12); do
  aws ec2 delete-security-group --region $REGION --group-id $SG_ID 2>/dev/null && break
  echo "still in use, retrying in 10s..."; sleep 10
done
```

### Step 6 — Subnets (only the ones you created)

```bash
VPC_ID=vpc-0123456789abcdef0

aws ec2 describe-subnets --region $REGION \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]' --output table

aws ec2 delete-subnet --region $REGION --subnet-id subnet-0123...
# repeat for every subnet — public and private
```

If this says `DependencyViolation`, something still lives in the subnet.
Find it:

```bash
aws ec2 describe-network-interfaces --region $REGION \
  --filters Name=subnet-id,Values=subnet-0123... \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description]' --output table
```

### Step 7 — Route tables

The VPC's **main** route table cannot be deleted — it disappears with the VPC.
Only delete the custom ones, and disassociate them first.

```bash
# list the non-main tables
aws ec2 describe-route-tables --region $REGION \
  --filters Name=vpc-id,Values=$VPC_ID \
  --query 'RouteTables[?!(Associations[?Main==`true`])].[RouteTableId]' --output text

# drop any remaining associations
aws ec2 describe-route-tables --region $REGION --route-table-ids rtb-0123... \
  --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' --output text
aws ec2 disassociate-route-table --region $REGION --association-id rtbassoc-0123...

aws ec2 delete-route-table --region $REGION --route-table-id rtb-0123...
```

### Step 8 — Internet gateway (detach, *then* delete)

Two calls. Deleting without detaching always fails.

```bash
IGW_ID=$(aws ec2 describe-internet-gateways --region $REGION \
  --filters Name=attachment.vpc-id,Values=$VPC_ID \
  --query 'InternetGateways[0].InternetGatewayId' --output text)

aws ec2 detach-internet-gateway --region $REGION \
  --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --region $REGION --internet-gateway-id $IGW_ID
```

### Step 9 — The VPC itself

```bash
aws ec2 delete-vpc --region $REGION --vpc-id $VPC_ID
```

Its default security group, main route table and default network ACL are
removed by AWS automatically. If it refuses, something is still inside:

```bash
aws ec2 describe-network-interfaces --region $REGION --filters Name=vpc-id,Values=$VPC_ID
aws ec2 describe-subnets            --region $REGION --filters Name=vpc-id,Values=$VPC_ID
aws ec2 describe-security-groups    --region $REGION --filters Name=vpc-id,Values=$VPC_ID
aws ec2 describe-nat-gateways       --region $REGION --filter  Name=vpc-id,Values=$VPC_ID
aws ec2 describe-vpc-endpoints      --region $REGION --filters Name=vpc-id,Values=$VPC_ID
```

> ⚠️ Never run `delete-vpc` on your account's **default** VPC unless you mean
> it. Other people's resources may be sitting in it, and recreating it
> (`aws ec2 create-default-vpc`) does not bring their configuration back.

### Step 10 — Key pair

```bash
aws ec2 delete-key-pair --region $REGION --key-name $KEY_NAME
rm -f ~/.ssh/${KEY_NAME}.pem
```

### Step 11 — IAM, strictly in this order

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name $PROFILE --role-name $ROLE
aws iam delete-instance-profile --instance-profile-name $PROFILE

aws iam detach-role-policy --role-name $ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam delete-role --role-name $ROLE
```

To be sure you detached everything first:

```bash
aws iam list-attached-role-policies --role-name $ROLE
aws iam list-role-policies --role-name $ROLE      # inline policies too
```

### Step 12 — Snapshots (only when you are truly finished)

```bash
aws ec2 describe-snapshots --region $REGION --owner-ids self \
  --filters Name=tag:Project,Values=nifi-demo \
  --query 'Snapshots[].[SnapshotId,StartTime,VolumeSize]' --output table

aws ec2 delete-snapshot --region $REGION --snapshot-id snap-0123456789abcdef0
```

### Step 13 — Local files

```bash
rm -f  nifi-ec2/scripts/.deploy-state
rm -rf nifi-ec2/scripts/build      # build/user-data.sh has your password in it
```

### Step 14 — Verify nothing is left

```bash
aws ec2 describe-instances --region $REGION \
  --filters Name=tag:Project,Values=nifi-demo \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text

aws ec2 describe-volumes    --region $REGION --filters Name=tag:Project,Values=nifi-demo --query 'Volumes[].VolumeId'      --output text
aws ec2 describe-addresses  --region $REGION --filters Name=tag:Project,Values=nifi-demo --query 'Addresses[].AllocationId' --output text
aws ec2 describe-vpcs       --region $REGION --filters Name=tag:Project,Values=nifi-demo --query 'Vpcs[].VpcId'            --output text
aws ec2 describe-subnets    --region $REGION --filters Name=tag:Project,Values=nifi-demo --query 'Subnets[].SubnetId'      --output text
aws ec2 describe-route-tables --region $REGION --filters Name=tag:Project,Values=nifi-demo --query 'RouteTables[].RouteTableId' --output text
aws ec2 describe-internet-gateways --region $REGION --filters Name=tag:Project,Values=nifi-demo --query 'InternetGateways[].InternetGatewayId' --output text
aws ec2 describe-snapshots  --region $REGION --owner-ids self --filters Name=tag:Project,Values=nifi-demo --query 'Snapshots[].SnapshotId' --output text
aws ec2 describe-security-groups --region $REGION --filters Name=group-name,Values=nifi-demo-sg --query 'SecurityGroups[].GroupId' --output text
aws iam get-role --role-name $ROLE 2>&1 | head -1
```

All empty (and `NoSuchEntity` for the role) means you are done.

---

## 5. One-liner: destroy everything tagged, no prompts

Handy in a sandbox account. **Dangerous anywhere else** — it deletes by tag,
so anything sharing that tag goes too.

```bash
REGION=us-east-1; TAG=Project,Values=nifi-demo
IDS=$(aws ec2 describe-instances --region $REGION \
  --filters Name=tag:$TAG Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$IDS" ] && aws ec2 terminate-instances --region $REGION --instance-ids $IDS \
  && aws ec2 wait instance-terminated --region $REGION --instance-ids $IDS
```

---

## 6. Errors you will hit, and what they mean

| Error | Meaning | Fix |
| --- | --- | --- |
| `DependencyViolation: resource sg-... has a dependent object` | An ENI still uses the security group | Wait 30–90 s after termination and retry; or delete the ENI (step 4) |
| `DeleteConflict: Cannot delete entity, must remove roles from instance profile first` | You tried to delete the role too early | Run `remove-role-from-instance-profile` first |
| `DeleteConflict: must detach all policies first` | Managed policy still attached | `detach-role-policy`, and check inline with `list-role-policies` |
| `OperationNotPermitted: may not be detached ... disableApiTermination` | Termination protection is on | `modify-instance-attribute --no-disable-api-termination` |
| `VolumeInUse` | Volume still attached to a live instance | Terminate/detach first, then delete |
| `DependencyViolation: The vpc ... has dependencies` | Something is still inside the VPC | Delete subnets, route tables, gateway, endpoints first — see step 9's list |
| `DependencyViolation` on the internet gateway | You skipped the detach | `detach-internet-gateway`, then `delete-internet-gateway` |
| `DependencyViolation` on a subnet | An ENI still lives in it | Terminate the instance and wait; then delete the ENI |
| `InvalidParameterValue: cannot delete the main route table` | You tried to delete the main table | You cannot — it goes with the VPC |
| `InvalidAllocationID.NotFound` | Elastic IP already released | Nothing to do |
| `IncorrectState: ... available` | You tried to disassociate an unattached EIP | Skip straight to `release-address` |
| `AuthFailure` / `UnauthorizedOperation` | Your IAM user lacks that delete permission | The message names the exact action to request |

---

## 7. Cost checklist after teardown

Things that keep charging if you miss them:

- ☐ **Elastic IP not released** — billed hourly whether attached or not
- ☐ **EBS volume in `available` state** — a detached disk is still a paid disk
- ☐ **Snapshots** — ~$0.05 per GB-month, forever, quietly
- ☐ **A second instance from a repeat deploy** — run `99b-force-cleanup.sh --all-regions`
- ☐ **Resources in a region you forgot** — same sweeper, same flag
- ☐ **NAT gateway** — ~$32/month if you ever add one to the private subnets:
  `aws ec2 describe-nat-gateways --region $REGION --filter Name=vpc-id,Values=$VPC_ID`
- ☐ **VPC endpoints** — interface endpoints bill hourly and block VPC deletion
- ☐ **CloudWatch log groups** — if you added the agent:
  `aws logs delete-log-group --region $REGION --log-group-name /nifi/app`

Then confirm with the console's **Billing → Cost Explorer**, filtered to the
last day. Zero EC2 usage tomorrow means you got it all.
