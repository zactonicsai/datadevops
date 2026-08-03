# AWS Routable vs. Non-Routable Subnets
### A complete, plain-English tutorial for data platform teams
*Covers Kafka/MSK, NiFi, Keycloak, OpenSearch, and data lakes*

---

## How to use this tutorial

This is written so a curious middle schooler could follow the ideas, and so a working cloud engineer could copy the commands straight into a terminal. Nothing is skipped or assumed.

**The order is deliberate:**

1. **Part 1** — You build one complete working example, step by step. Do this first, even if you don't understand every piece yet. Seeing it work makes everything else click.
2. **Parts 2–4** — The background. What these words actually mean and why anybody invented them.
3. **Parts 5–9** — The real engineering: where to put Kafka, NiFi, Keycloak, OpenSearch, and your data lake, how big to make everything, and what goes wrong.
4. **Parts 10–14** — Cost, troubleshooting, rescue plans, cheat sheets, glossary.

**Time to complete Part 1:** about 45 minutes.
**Cost to complete Part 1:** roughly $2–4 if you delete everything the same day (a NAT Gateway is about $0.045/hour). Part 1 ends with teardown commands. Please run them.

**What you need before you start:**

- An AWS account you're allowed to create networks in
- AWS CLI v2 installed (`aws --version` should print `aws-cli/2.x`)
- `jq` installed (used to pull IDs out of responses)
- Permission to create VPCs, subnets, NAT Gateways, and EC2 instances

---

# Table of Contents

- [Part 1: Build It First (step-by-step)](#part-1-build-it-first)
- [Part 2: The Background — What Is an IP Address, Really?](#part-2-the-background)
- [Part 3: What "Routable" and "Non-Routable" Actually Mean](#part-3-what-routable-and-non-routable-actually-mean)
- [Part 4: The Building Blocks in Detail](#part-4-the-building-blocks-in-detail)
- [Part 5: The Decision Rule](#part-5-the-decision-rule)
- [Part 6: Workload-by-Workload Guidance](#part-6-workload-by-workload-guidance)
- [Part 7: CIDR Sizing — The Master Plan](#part-7-cidr-sizing-the-master-plan)
- [Part 8: Pros and Cons of Every Option](#part-8-pros-and-cons-of-every-option)
- [Part 9: Best Practices and Anti-Patterns](#part-9-best-practices-and-anti-patterns)
- [Part 10: Cost](#part-10-cost)
- [Part 11: Troubleshooting Playbook](#part-11-troubleshooting-playbook)
- [Part 12: Rescue Plans — When You've Already Run Out](#part-12-rescue-plans)
- [Part 13: IPv6, IPAM, and Where This Is All Heading](#part-13-ipv6-ipam-and-the-future)
- [Part 14: Cheat Sheet and Glossary](#part-14-cheat-sheet-and-glossary)

---

<a name="part-1-build-it-first"></a>
# Part 1: Build It First

## What you're about to build

```
                          THE INTERNET / YOUR OFFICE NETWORK
                                       |
        ===============================|=====================================
        ||  VPC "tutorial-vpc"         |                                   ||
        ||                     [Internet Gateway]                          ||
        ||                             |                                   ||
        ||   +-------------------------|--------------------------+        ||
        ||   |  ROUTABLE SUBNET   10.20.0.0/24                    |        ||
        ||   |  "houses with street addresses"                    |        ||
        ||   |                                                     |        ||
        ||   |         [ NAT Gateway ] <--- the front office       |        ||
        ||   +--------------------|--------------------------------+        ||
        ||                        |                                        ||
        ||   +--------------------|--------------------------------+        ||
        ||   |  NON-ROUTABLE SUBNET   100.64.0.0/18               |        ||
        ||   |  "lockers - only meaningful inside the building"   |        ||
        ||   |                                                     |        ||
        ||   |    [ EC2 instance ] -- can reach OUT, but nothing   |        ||
        ||   |                        outside can reach IN         |        ||
        ||   +-----------------------------------------------------+        ||
        ||                                                                  ||
        ||   [ S3 Gateway Endpoint ] --- private shortcut to S3, free       ||
        =====================================================================
```

You'll create both kinds of subnet in one VPC, put a machine in the non-routable one, and prove two things with your own eyes:

- The machine **can** download things from the internet and reach S3.
- The machine's IP address is a "fake" one that nothing outside the VPC could ever route to.

---

## Step 0: Set your working variables

Open a terminal. Everything below assumes these are set.

```bash
export AWS_REGION="us-east-1"
export AWS_DEFAULT_REGION="us-east-1"

# Verify you're pointed at the right account
aws sts get-caller-identity
```

Expected output — check the account number is the one you meant:

```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/you"
}
```

> **Middle school translation:** This is like writing your name on your paper before the test. You're confirming who you are and which building you're working in.

---

## Step 1: Create the VPC with your "real" address range

A **VPC** (Virtual Private Cloud) is your own private network inside AWS. Think of it as your own building. Nobody else's stuff is in it.

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.20.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=tutorial-vpc}]' \
  --query 'Vpc.VpcId' --output text)

echo "VPC_ID=$VPC_ID"
```

Expected output:

```
VPC_ID=vpc-0a1b2c3d4e5f67890
```

`10.20.0.0/16` gives you 65,536 addresses. In a real company, a network team would have handed you this range and written it in a spreadsheet so nobody else uses it. **These are your precious, routable, real addresses.**

Turn on DNS so machines get hostnames (needed for almost everything later, including VPC endpoints):

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames '{"Value":true}'
```

---

## Step 2: Attach the "fake" address range as a secondary CIDR

This is the whole trick of this tutorial. One VPC can hold **more than one address range**.

```bash
aws ec2 associate-vpc-cidr-block \
  --vpc-id $VPC_ID \
  --cidr-block 100.64.0.0/16
```

Expected output:

```json
{
    "CidrBlockAssociation": {
        "AssociationId": "vpc-cidr-assoc-0abc...",
        "CidrBlock": "100.64.0.0/16",
        "CidrBlockState": { "State": "associating" }
    },
    "VpcId": "vpc-0a1b2c3d4e5f67890"
}
```

Confirm both ranges are attached:

```bash
aws ec2 describe-vpcs --vpc-ids $VPC_ID \
  --query 'Vpcs[0].CidrBlockAssociationSet[].[CidrBlock,CidrBlockState.State]' \
  --output table
```

```
------------------------------------
|           DescribeVpcs           |
+-------------------+--------------+
|  10.20.0.0/16     |  associated  |
|  100.64.0.0/16    |  associated  |
+-------------------+--------------+
```

> **Why 100.64?** That range is called **CGNAT space** (RFC 6598). Internet providers use it internally. It's almost never used inside a company network, which makes it a safe "fake" range — very low chance of clashing with something your company already owns. AWS itself recommends it for exactly this purpose in its EKS guidance. More on this in Part 3.

---

## Step 3: Create the routable subnet

```bash
SUBNET_ROUTABLE=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.20.0.0/24 \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=tutorial-routable-1a}]' \
  --query 'Subnet.SubnetId' --output text)

echo "SUBNET_ROUTABLE=$SUBNET_ROUTABLE"
```

This subnet holds 256 addresses, of which **251 are usable** — AWS reserves five in every subnet (Part 2 explains which five and why).

---

## Step 4: Create the non-routable subnet

```bash
SUBNET_NONROUTABLE=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 100.64.0.0/18 \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=tutorial-nonroutable-1a}]' \
  --query 'Subnet.SubnetId' --output text)

echo "SUBNET_NONROUTABLE=$SUBNET_NONROUTABLE"
```

Look at the difference in scale. The routable subnet has 251 usable addresses. This one has **16,379**. That's the point — you were stingy with the real addresses and generous with the fake ones.

List them side by side:

```bash
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailableIpAddressCount]' \
  --output table
```

```
--------------------------------------------------------------
|                       DescribeSubnets                       |
+-----------------------------+------------------+-----------+
|  tutorial-routable-1a       |  10.20.0.0/24    |  251      |
|  tutorial-nonroutable-1a    |  100.64.0.0/18   |  16379    |
+-----------------------------+------------------+-----------+
```

---

## Step 5: Create an Internet Gateway

The **Internet Gateway (IGW)** is the front door of the building. Without it, nothing in the VPC can reach the internet at all.

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=tutorial-igw}]' \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

echo "IGW_ID=$IGW_ID"
```

---

## Step 6: Allocate an Elastic IP and create the NAT Gateway

The **NAT Gateway** is the school front office from the story. Machines in the non-routable subnet send their mail to the office, and the office puts its own return address on the envelope.

The NAT Gateway itself needs a real address, so it lives in the **routable** subnet. This is the most commonly misunderstood part of the whole setup — read that sentence twice.

```bash
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=tutorial-nat-eip}]' \
  --query 'AllocationId' --output text)

NAT_GW=$(aws ec2 create-nat-gateway \
  --subnet-id $SUBNET_ROUTABLE \
  --allocation-id $EIP_ALLOC \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=tutorial-nat}]' \
  --query 'NatGateway.NatGatewayId' --output text)

echo "NAT_GW=$NAT_GW"
```

NAT Gateways take 1–3 minutes to become available. Wait for it:

```bash
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW
echo "NAT Gateway is ready."
```

> **Money warning:** From this moment you are being billed about **$0.045 per hour** plus about **$0.045 per gigabyte** processed. Don't forget Step 15 (teardown).

---

## Step 7: Build the route table for the routable subnet

A **route table** is the list of directions taped to the hallway wall. Every subnet follows exactly one route table.

```bash
RTB_ROUTABLE=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=tutorial-rtb-routable}]' \
  --query 'RouteTable.RouteTableId' --output text)

# "To reach anywhere on the internet, go out the front door."
aws ec2 create-route \
  --route-table-id $RTB_ROUTABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID

aws ec2 associate-route-table \
  --route-table-id $RTB_ROUTABLE \
  --subnet-id $SUBNET_ROUTABLE
```

`0.0.0.0/0` means "every address in the world that I don't have a more specific rule for." It's the default rule — the catch-all at the bottom of the list.

---

## Step 8: Build the route table for the non-routable subnet

```bash
RTB_NONROUTABLE=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=tutorial-rtb-nonroutable}]' \
  --query 'RouteTable.RouteTableId' --output text)

# "To reach anywhere outside, go through the front office."
aws ec2 create-route \
  --route-table-id $RTB_NONROUTABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_GW

aws ec2 associate-route-table \
  --route-table-id $RTB_NONROUTABLE \
  --subnet-id $SUBNET_NONROUTABLE
```

**Stop and notice this.** The two subnets are made of the exact same stuff. The *only* difference between "routable" and "non-routable" is these two route tables and the address ranges they use. That's it. There is no checkbox in AWS called "non-routable."

---

## Step 9: Add the free S3 shortcut

A **Gateway VPC Endpoint** lets traffic to S3 leave the VPC directly instead of going through the NAT Gateway. It costs nothing and saves you the per-gigabyte NAT fee. For a data lake this single command can save thousands of dollars a month.

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id $VPC_ID \
  --service-name com.amazonaws.${AWS_REGION}.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids $RTB_NONROUTABLE $RTB_ROUTABLE \
  --tag-specifications 'ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=tutorial-s3-endpoint}]'
```

Verify the route got added automatically:

```bash
aws ec2 describe-route-tables --route-table-ids $RTB_NONROUTABLE \
  --query 'RouteTables[0].Routes[].[DestinationCidrBlock,DestinationPrefixListId,NatGatewayId,GatewayId]' \
  --output table
```

You'll see a new line with a `pl-` prefix list ID. That's AWS's maintained list of every S3 IP address in the region, injected into your route table for free.

---

## Step 10: Create a security group

The route table decides *where traffic can go*. The **security group** decides *what traffic is allowed*. They're different jobs and you need both.

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name tutorial-sg \
  --description "Tutorial instance SG" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

echo "SG_ID=$SG_ID"
```

Notice we add **no inbound rules at all**. The instance will still be able to reach out, because security groups are *stateful* — replies to connections you started are automatically allowed back in.

---

## Step 11: Launch an instance in the non-routable subnet

We'll use SSM Session Manager to get a shell, so we don't need SSH keys or any inbound access. First, create the instance role:

```bash
cat > /tmp/trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role --role-name tutorial-ssm-role \
  --assume-role-policy-document file:///tmp/trust.json

aws iam attach-role-policy --role-name tutorial-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name tutorial-ssm-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name tutorial-ssm-profile --role-name tutorial-ssm-role

# IAM is eventually consistent; give it a moment
sleep 15
```

Now launch:

```bash
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.micro \
  --subnet-id $SUBNET_NONROUTABLE \
  --security-group-ids $SG_ID \
  --iam-instance-profile Name=tutorial-ssm-profile \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=tutorial-box}]' \
  --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID
echo "INSTANCE_ID=$INSTANCE_ID"
```

Look at the address it got:

```bash
aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress]' \
  --output table
```

```
------------------------------
|      DescribeInstances     |
+---------------+------------+
|  100.64.0.47  |  None      |
+---------------+------------+
```

**There it is.** `100.64.0.47` is a locker number. There is no public IP. Nothing on the internet, and nothing on your office network, can send a packet to that machine.

---

## Step 12: Prove it can still reach out

```bash
aws ssm start-session --target $INSTANCE_ID
```

Inside the session:

```bash
# What does the outside world think my address is?
curl -s https://checkip.amazonaws.com
```

You'll get back the NAT Gateway's public address — **not** `100.64.0.47`. The front office swapped the return address.

```bash
# Confirm my actual address is the fake one
hostname -I

# Confirm internet access works
curl -s -o /dev/null -w "%{http_code}\n" https://aws.amazon.com

# Confirm S3 works (this goes through the free endpoint, not the NAT)
aws s3 ls --region us-east-1
```

Type `exit` to leave.

> **This is the whole lesson in one screen.** The machine has a meaningless address, cannot be reached from outside, and yet works perfectly for everything it needs to do.

---

## Step 13: Prove the difference with route tables

Temporarily point the non-routable subnet at nothing:

```bash
aws ec2 delete-route \
  --route-table-id $RTB_NONROUTABLE \
  --destination-cidr-block 0.0.0.0/0
```

Reconnect and try `curl https://aws.amazon.com` — it hangs and fails. But `aws s3 ls` **still works**, because the S3 endpoint route is separate.

Put it back:

```bash
aws ec2 create-route \
  --route-table-id $RTB_NONROUTABLE \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_GW
```

You just proved that routability is a property of the **route table**, not of the machine or the subnet itself.

---

## Step 14: See how the addresses are being used

```bash
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,CIDR:CidrBlock,Free:AvailableIpAddressCount}' \
  --output table
```

The non-routable subnet lost one address. It has 16,378 left. The routable subnet lost one too (the NAT Gateway) and has 250 left. Imagine 500 Spark pods launching — now you understand why we did this.

---

## Step 15: Tear it all down

Run these in order. Skipping this costs real money.

```bash
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID

VPCE_ID=$(aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text)
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE_ID

aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW
aws ec2 wait nat-gateway-deleted --nat-gateway-ids $NAT_GW
aws ec2 release-address --allocation-id $EIP_ALLOC

aws ec2 detach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID

aws ec2 delete-security-group --group-id $SG_ID
aws ec2 delete-subnet --subnet-id $SUBNET_ROUTABLE
aws ec2 delete-subnet --subnet-id $SUBNET_NONROUTABLE
aws ec2 delete-route-table --route-table-id $RTB_ROUTABLE
aws ec2 delete-route-table --route-table-id $RTB_NONROUTABLE
aws ec2 delete-vpc --vpc-id $VPC_ID

aws iam remove-role-from-instance-profile \
  --instance-profile-name tutorial-ssm-profile --role-name tutorial-ssm-role
aws iam delete-instance-profile --instance-profile-name tutorial-ssm-profile
aws iam detach-role-policy --role-name tutorial-ssm-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name tutorial-ssm-role

echo "All clean."
```

**You've built it. Now let's understand it.**

---

<a name="part-2-the-background"></a>
# Part 2: The Background — What Is an IP Address, Really?

## Addresses and mail

Every computer on a network needs an address, for exactly the same reason every house needs an address. When one computer wants to send information to another, it wraps that information in a **packet** — an envelope — and writes two things on the outside: who it's from, and who it's going to.

An IPv4 address looks like `10.20.3.47`. Four numbers, each from 0 to 255. That gives about 4.3 billion possible addresses in total.

That sounded like plenty in 1981. It is not plenty now.

## The great address shortage

There are far more internet-connected devices than there are IPv4 addresses. The world ran out of fresh public addresses around 2011. The long-term fix is IPv6 (see Part 13), but most enterprise networks still run on IPv4 and will for years.

To cope, the internet's designers set aside some ranges as **private**. Anybody can use them, as many times as they like, because they're never used on the public internet. These are defined in a document called **RFC 1918**:

| Range | Size | Where you've seen it |
|---|---|---|
| `10.0.0.0/8` | 16.7 million addresses | Most corporate networks |
| `172.16.0.0/12` | 1 million addresses | Docker's default, some corporate |
| `192.168.0.0/16` | 65,536 addresses | Your home Wi-Fi router |

Your home router almost certainly hands out addresses like `192.168.1.5`. So does your neighbor's. So does your school's. That's fine — those addresses are only meaningful inside each building.

## Reading CIDR notation

That `/16` and `/8` business is **CIDR notation** (Classless Inter-Domain Routing, pronounced "cider"). It tells you how much of the address is fixed and how much is free to vary.

Think of it as **"how many digits of the address are locked?"**

- `10.20.0.0/16` — the first two numbers are locked. `10.20.anything.anything`. That's 65,536 addresses.
- `10.20.5.0/24` — the first three are locked. `10.20.5.anything`. That's 256 addresses.
- `10.20.5.0/28` — almost everything is locked. 16 addresses.

**The rule to memorize: bigger number after the slash = smaller network.** A `/24` is small. A `/8` is enormous. People get this backwards constantly.

Here's the full table you'll actually use:

| CIDR | Total addresses | Usable in AWS | Roughly right for |
|---|---|---|---|
| `/28` | 16 | 11 | Transit Gateway attachment, tiny endpoint subnet |
| `/27` | 32 | 27 | Minimum for an Application Load Balancer |
| `/26` | 64 | 59 | Kafka brokers, OpenSearch nodes, VPC endpoints |
| `/25` | 128 | 123 | NiFi cluster, medium app tier |
| `/24` | 256 | 251 | Load balancer subnet, general purpose |
| `/22` | 1,024 | 1,019 | Medium container platform |
| `/20` | 4,096 | 4,091 | Large container platform |
| `/18` | 16,384 | 16,379 | Big Spark / EKS pod subnet |
| `/16` | 65,536 | 65,531 | An entire VPC (this is AWS's max per subnet: /16) |

**AWS subnets must be between `/28` (smallest) and `/16` (largest).**

## The five addresses AWS steals

In every single subnet you create, AWS reserves five addresses. This trips people up when they carefully size a `/28` for exactly 14 machines and can only fit 11.

For a subnet `10.20.5.0/24`:

| Address | What AWS uses it for |
|---|---|
| `10.20.5.0` | Network address (always reserved everywhere, not just AWS) |
| `10.20.5.1` | The VPC router — your subnet's default gateway |
| `10.20.5.2` | The Amazon DNS server (`.2` of the VPC base range) |
| `10.20.5.3` | Reserved by AWS for future use |
| `10.20.5.255` | Broadcast address (AWS doesn't support broadcast, but reserves it anyway) |

So: **usable addresses = total − 5**. Always.

## What NAT is

**NAT** stands for **Network Address Translation**. It's the front-office trick.

When a machine at `100.64.0.47` wants to reach `example.com`, the packet goes to the NAT Gateway. The NAT Gateway rewrites the "from" field to its own real address, remembers in a table that "reply to port 51294 belongs to 100.64.0.47," and sends it on. When the reply comes back, it looks up the table and delivers it.

Two consequences follow directly from this, and they explain almost everything in the rest of this tutorial:

1. **Outbound works fine.** Any machine anywhere behind NAT can start a conversation with the outside world.
2. **Inbound is impossible.** If a stranger sends a packet to the NAT Gateway unprompted, there's no table entry, and it gets dropped. There's no way to know which of the 5,000 machines behind it was meant.

That second point is why Kafka has trouble and Keycloak doesn't. Hold that thought for Part 6.

## Stateful vs. stateless

Security groups are **stateful**. If your instance opens a connection out, the reply is allowed back automatically — you don't write a rule for it. This is why our tutorial instance with zero inbound rules still worked.

Network ACLs are **stateless**. They evaluate every packet independently, so you must write rules for both directions, including ephemeral return ports (1024–65535). This is the number one reason people break their own networks with NACLs.

---

<a name="part-3-what-routable-and-non-routable-actually-mean"></a>
# Part 3: What "Routable" and "Non-Routable" Actually Mean

## The definition

Here's the sentence that matters most in this entire document:

> **"Routable" and "non-routable" are not AWS features. They are agreements between you and your network team about which address ranges get advertised to the rest of the company.**

There is no API call, no flag, no setting. AWS will happily route between any two subnets in the same VPC regardless of what range they use. What makes a subnet "non-routable" is that:

1. You used a range that your network team deliberately does **not** advertise on-premises, and
2. You didn't put a route to the Transit Gateway in that subnet's route table.

That's the whole mechanism.

## Routable subnets

**Definition:** addresses drawn from your company's officially allocated, globally-unique-within-the-company address space. Your network team tracks them in an IPAM system or a spreadsheet. They're advertised over Direct Connect / VPN / Transit Gateway so the rest of the organization can find them.

**Real-world analogy:** a house with a street address. The mail carrier has it on the map. Anyone can send you a package. But Maple Street only has so many house numbers.

**Key property:** things outside the VPC can **initiate** a connection to resources here.

**What must live here:**

- Load balancers that on-prem users or other VPCs connect to
- Transit Gateway attachment ENIs
- NAT Gateways (public and private)
- VPC endpoint ENIs that on-prem systems need to reach
- Anything that advertises its own address to clients (hello, Kafka)
- Databases that on-prem applications query directly

## Non-routable subnets

**Definition:** addresses from a range that is deliberately reused across many VPCs and never advertised outside. Usually `100.64.0.0/10` (CGNAT space, RFC 6598), sometimes an internally-designated "overlap allowed" `10.x` block.

**Real-world analogy:** locker #237 at a middle school. Every school has one. That's fine, because nobody mails letters to lockers. It only means something inside the building.

**Key property:** things outside the VPC **cannot** initiate a connection here. Outbound works via NAT.

**What should live here:**

- Container and pod networks (EKS with custom networking, ECS awsvpc tasks)
- Ephemeral compute: EMR core/task nodes, Glue ENIs, Spark executors
- Application servers that are only ever reached through a load balancer
- Batch jobs, ETL workers, anything short-lived and numerous

## Why 100.64.0.0/10 specifically

RFC 6598 set aside `100.64.0.0/10` (that's `100.64.0.0` through `100.127.255.255`, about 4.2 million addresses) as **shared address space** for internet providers doing carrier-grade NAT — the same technique your mobile carrier uses so millions of phones can share a small pool of public addresses.

Why AWS practitioners like it for this job:

- **It's huge.** A `/10` is four million addresses. You will not run out.
- **Almost nobody uses it internally.** AWS's own EKS documentation recommends CGNAT space precisely because it's less likely to collide with a corporate network than another `10.x` range.
- **It's not RFC 1918**, so AWS lets you attach it as a secondary CIDR to a VPC whose primary is `10.x` — which the RFC 1918 ranges themselves don't allow (see the restriction table below).
- **It self-documents.** Anyone who sees `100.64.x.x` in a diagram immediately knows "that's the overlapping, non-routable stuff."

**The honest counter-argument:** some network purists object that this range belongs to ISPs and shouldn't be repurposed. In practice, if your company also uses `100.64` space at the WAN edge — some do, especially telcos and anyone behind CGNAT circuits — you'd have a genuine collision. **Check with your network team before adopting it.** If it's taken, the fallback is to designate an internal "overlap allowed" block out of `10.0.0.0/8` and document loudly that it's never advertised.

## Secondary CIDR restrictions — read this before you plan

AWS does **not** let you attach any range you like as a secondary CIDR. The rules are asymmetric and surprising. Approximately:

| Your primary VPC CIDR | You generally **cannot** add a secondary from |
|---|---|
| `10.0.0.0/8` range | `172.16.0.0/12`, `192.168.0.0/16`, `198.19.0.0/16` |
| `172.16.0.0/12` range | `10.0.0.0/8`, `192.168.0.0/16`, `198.19.0.0/16` |
| `192.168.0.0/16` range | `10.0.0.0/8`, `172.16.0.0/12`, `198.19.0.0/16` |
| Non-RFC1918 / `100.64.0.0/10` | `10.0.0.0/15`, `172.16.0.0/12`, `192.168.0.0/16`, `198.19.0.0/16` |

There's also a special case: if your primary CIDR falls within `10.0.0.0/15`, you can't add a secondary from `10.0.0.0/16`.

**The practical takeaway:** `10.x` primary + `100.64.x` secondary is the combination that works, which is a large part of why this pattern became standard. You'll also see `198.19.0.0/16` recommended in some EKS docs, but it appears on AWS's restricted list in most primary-CIDR cases — **test it with a throwaway VPC before you build a plan around it.**

Test any combination safely in about three seconds:

```bash
aws ec2 create-vpc --cidr-block 10.99.0.0/16 --query 'Vpc.VpcId' --output text
# then try the association; delete the VPC afterward
aws ec2 associate-vpc-cidr-block --vpc-id vpc-XXXX --cidr-block 198.19.0.0/16
```

Other hard limits worth knowing:

- **5 CIDR blocks per VPC by default**, raisable to 50 via a quota increase
- Subnets must be `/28` to `/16`
- You can never resize a CIDR block after creation — only add more
- You can disassociate a secondary CIDR only if no subnets use it

## The critical misunderstanding: this is not a security control

Putting something in a non-routable subnet makes it *unreachable by default from outside the VPC*. It does **not** make it secure.

- Anything else **inside the same VPC** can reach it freely.
- Anything in a **peered VPC or across the Transit Gateway** can reach it if routes exist and CIDRs don't overlap.
- A compromised machine in the same subnet has full access.
- The NAT Gateway gives it unrestricted outbound internet — which is exactly what malware wants for command-and-control and data exfiltration.

**Non-routable is a locked hallway, not a locked locker.** You still need security groups (mandatory), and for sensitive workloads, egress filtering via AWS Network Firewall or a proxy.

---

<a name="part-4-the-building-blocks-in-detail"></a>
# Part 4: The Building Blocks in Detail

## Route tables

The single most important object in this whole topic. Every subnet is associated with exactly one route table. If you don't associate one explicitly, it silently uses the VPC's **main route table** — a very common source of "why can't this thing reach anything?"

Routes are matched **most-specific-first**. Given these entries:

```
10.20.0.0/16    -> local          (automatic, cannot be removed)
100.64.0.0/16   -> local          (automatic)
10.0.0.0/8      -> tgw-0abc
0.0.0.0/0       -> nat-0abc
```

A packet to `10.5.1.1` matches `10.0.0.0/8` and goes to the Transit Gateway. A packet to `8.8.8.8` matches only `0.0.0.0/0` and goes to NAT. A packet to `100.64.0.9` matches `local` and never leaves the VPC. **Local routes always win and cannot be overridden.**

Inspect the rules for any subnet:

```bash
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=subnet-0abc" \
  --query 'RouteTables[].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,TransitGatewayId,VpcPeeringConnectionId,State]' \
  --output table
```

Find subnets that fell through to the main route table by mistake:

```bash
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[?Associations[?Main==`true`]].Associations' --output json
```

## Internet Gateway vs. NAT Gateway

| | Internet Gateway | Public NAT Gateway | Private NAT Gateway |
|---|---|---|---|
| **Direction** | Both ways | Outbound only | Outbound only |
| **Translates addresses?** | No (1:1 with public IP) | Yes, to an Elastic IP | Yes, to a private IP |
| **Needs public IP?** | Yes, on the resource | On the NAT itself | No |
| **Reaches the internet?** | Yes | Yes | **No** |
| **Cost** | Free | ~$0.045/hr + ~$0.045/GB | ~$0.045/hr + ~$0.045/GB |
| **Lives in** | The VPC | A public subnet | A **routable private** subnet |

The **private NAT Gateway** is the less famous one and it's the key to the whole non-routable pattern in a hybrid network. It translates non-routable `100.64.x` source addresses into routable `10.x` addresses so traffic can cross a Transit Gateway to on-premises — without ever touching the internet.

```bash
aws ec2 create-nat-gateway \
  --subnet-id $SUBNET_ROUTABLE \
  --connectivity-type private \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=private-nat}]'
```

Then in the non-routable subnet's route table:

```bash
# Traffic destined for the corporate network gets NAT'd to a routable address
aws ec2 create-route --route-table-id $RTB_NONROUTABLE \
  --destination-cidr-block 10.0.0.0/8 \
  --nat-gateway-id $PRIVATE_NAT_GW
```

Now a pod at `100.64.5.9` can call an on-prem LDAP server, and the LDAP server sees the connection arriving from a legitimate `10.20.0.x` address it knows how to reply to. **This is how you get outbound hybrid connectivity without spending routable addresses on every pod.**

AWS's own multi-VPC networking whitepaper describes exactly this pattern for connecting VPCs with overlapping CIDRs — something VPC peering and Transit Gateway alone cannot do.

## Transit Gateway

The Transit Gateway (TGW) is the central switchboard connecting your VPCs, VPNs, and Direct Connect links.

**The rule that governs everything:** TGW does **not** do address translation. If two VPCs both use `100.64.0.0/16`, TGW cannot route between them. Full stop.

This is precisely why the pattern is *routable* subnets for the TGW attachment and *non-routable* subnets for the workload:

```bash
aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id tgw-0abc \
  --vpc-id $VPC_ID \
  --subnet-ids $SUBNET_ROUTABLE_1A $SUBNET_ROUTABLE_1B $SUBNET_ROUTABLE_1C
```

Give the TGW attachment its **own dedicated `/28` subnet per AZ**. It only needs one ENI per AZ, and keeping it isolated means you can attach NACLs and route tables to it without side effects. This is a widely recommended practice and costs you almost nothing.

Check what the TGW actually knows how to reach:

```bash
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id tgw-rtb-0abc \
  --filters "Name=type,Values=static,propagated"
```

## VPC Endpoints — the address-saving superpower

There are two kinds, and the difference matters enormously for your IP budget.

### Gateway Endpoints (S3 and DynamoDB only)

- **Consume zero IP addresses**
- **Cost nothing**
- Work by injecting a prefix list route into your route tables
- Cannot be reached from on-premises

**Every data lake should have one. There is no downside.**

```bash
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID \
  --service-name com.amazonaws.us-east-1.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids rtb-a rtb-b rtb-c
```

### Interface Endpoints (PrivateLink — everything else)

- **Consume one IP address per AZ per service**
- Cost roughly $0.01/hour per AZ plus ~$0.01/GB
- Can be reached from on-premises over Direct Connect/VPN
- Used for KMS, Secrets Manager, STS, CloudWatch, Glue, Athena, SSM, Kinesis, and ~100 others

The IP cost adds up fast. Ten services × 3 AZs = 30 addresses. Put interface endpoints in their own dedicated `/26` per AZ so they don't eat into workload subnets.

```bash
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID \
  --service-name com.amazonaws.us-east-1.secretsmanager \
  --vpc-endpoint-type Interface \
  --subnet-ids $SUBNET_ENDPOINTS_1A $SUBNET_ENDPOINTS_1B \
  --security-group-ids $SG_ENDPOINTS \
  --private-dns-enabled
```

> **Cost tip:** Consider a **centralized endpoints VPC** shared across your organization via Transit Gateway, rather than duplicating 20 interface endpoints in every VPC. This trades a small amount of latency and TGW data processing charges for a large reduction in endpoint hourly fees and IP consumption.

### PrivateLink for your own services

You can publish your own service behind a Network Load Balancer as an endpoint service. Consumers connect through an ENI in *their* VPC — **which means CIDR overlap between provider and consumer doesn't matter at all.** This is the escape hatch when two teams both used `10.50.0.0/16` and now need to talk. As of late 2024, PrivateLink also supports cross-Region connectivity.

## Security Groups vs. Network ACLs

| | Security Group | Network ACL |
|---|---|---|
| **Attaches to** | ENI / instance | Subnet |
| **Stateful?** | Yes | No |
| **Rules** | Allow only | Allow and deny |
| **Evaluation** | All rules, any match allows | In numbered order, first match wins |
| **Can reference** | Other security groups | CIDR blocks only |
| **Best used for** | Everything, all the time | Coarse guardrails, e.g. block a bad CIDR |

**Practical advice:** do your real work in security groups, referencing them by ID rather than by CIDR:

```bash
# "Anything with the kafka-client SG may reach the brokers on 9098"
aws ec2 authorize-security-group-ingress \
  --group-id $SG_KAFKA_BROKERS \
  --protocol tcp --port 9098 \
  --source-group $SG_KAFKA_CLIENTS
```

This keeps working when you re-IP, add subnets, or move things between routable and non-routable space. **CIDR-based rules break during exactly the migrations this tutorial is about.**

## DNS

DNS decides which address a name resolves to, and it must line up with your routing or nothing works.

- **Route 53 Resolver inbound endpoints** let on-prem DNS servers resolve your private AWS names. These ENIs live in **routable** subnets.
- **Outbound endpoints** let AWS resources resolve on-prem names. Also routable subnets.
- **Private hosted zones** hold your internal names and must be associated with each VPC that needs them.
- **`--private-dns-enabled` on interface endpoints** silently overrides the public AWS service name so it resolves to your private endpoint IP. Very useful, occasionally very confusing during troubleshooting.

The classic failure: a Kafka broker in a routable subnet resolves fine from on-prem, but a client in a non-routable subnet gets the right name and then can't reach it because the route table has no path. **Always check DNS and routing separately.**

---

<a name="part-5-the-decision-rule"></a>
# Part 5: The Decision Rule

For any component you're about to deploy, walk this ladder. Stop at the first "yes."

```
1. Does something OUTSIDE this VPC need to START a connection to it?
      YES -> ROUTABLE
      NO  -> continue

2. Does it hand out its OWN IP address or hostname to clients?
   (Kafka advertised.listeners, NiFi site-to-site, Cassandra gossip,
    Hadoop DataNode registration, Zookeeper, Elasticsearch transport)
      YES -> ROUTABLE  (NAT breaks these — the client is told to
                        connect to an address it can never reach)
      NO  -> continue

3. Is it AWS infrastructure that requires a real address?
   (TGW attachment, NAT Gateway, ALB/NLB, Route 53 Resolver endpoint,
    interface endpoints reached from on-prem)
      YES -> ROUTABLE
      NO  -> continue

4. Will there be a LOT of them, or will they come and go?
   (pods, Spark executors, Glue ENIs, batch workers, Lambda ENIs)
      YES -> NON-ROUTABLE, definitely
      NO  -> NON-ROUTABLE anyway, as the default
```

**Default to non-routable.** Make each routable address justify itself. Routable space is the scarce resource; treat it like a budget, not a convenience.

## The two questions that catch people out

**"But it needs to reach our on-prem database!"** — That's *outbound*. It works fine from non-routable space via a private NAT Gateway. Outbound is never a reason to spend routable addresses.

**"But we need to SSH into it!"** — Use SSM Session Manager (as in Part 1). It's outbound-initiated, works from non-routable space, needs no bastion, no keys, and no inbound rules at all. This eliminates the most common excuse for routable addresses.

---

<a name="part-6-workload-by-workload-guidance"></a>
# Part 6: Workload-by-Workload Guidance

## 6.1 Apache Kafka / Amazon MSK

**Verdict: ROUTABLE. Kafka is the special case, and it's non-negotiable.**

### Why Kafka is different

Kafka's protocol has a step no other system quite duplicates. A client connects to any broker and asks "who owns the partitions I want?" The broker replies with a **metadata response** containing the addresses of the other brokers — whatever each broker has configured in `advertised.listeners`.

The client then **disconnects and reconnects directly** to the broker that owns the partition it needs.

```
Client -> broker-1 (bootstrap):  "Where is partition 7 of topic orders?"
broker-1 -> Client:              "broker-3 at b-3.mycluster...:9098"
Client -> broker-3:              [direct connection]
```

If `b-3` resolves to `100.64.2.19` and the client is outside the VPC, that third step fails. The client has been handed an address it has no route to. It will retry, time out, and produce error messages that don't mention networking at all — usually `TimeoutException: Topic not present in metadata` or leader-election churn.

**NAT does not save you here.** NAT only helps connections that the inside starts. Kafka requires clients to start connections *to* each broker individually.

### The rules for MSK

- **Broker ENIs go in routable subnets.** One ENI per broker, drawn from the subnet's CIDR.
- **Standard brokers:** 2 or 3 subnets in different AZs (US West / N. California requires exactly 2; other regions accept 2 or 3).
- **Express brokers:** require **3 subnets in 3 different AZs.**
- Broker count must be a **multiple of the number of subnets** you specify.
- Client subnets **cannot** use the AZ with ID `use1-az3`.
- **Test any non-RFC1918 subnet before committing.** MSK's supported ranges have historically been more restrictive than plain EC2's; validate with a throwaway cluster in `100.64` space before you design around it.

### CLI

```bash
cat > brokernodegroupinfo.json <<'EOF'
{
  "InstanceType": "kafka.m5.large",
  "ClientSubnets": ["subnet-routable-1a","subnet-routable-1b","subnet-routable-1c"],
  "SecurityGroups": ["sg-kafka-brokers"],
  "StorageInfo": { "EbsStorageInfo": { "VolumeSize": 1000 } }
}
EOF

aws kafka create-cluster \
  --cluster-name prod-kafka \
  --broker-node-group-info file://brokernodegroupinfo.json \
  --kafka-version "3.6.0" \
  --number-of-broker-nodes 3 \
  --enhanced-monitoring PER_TOPIC_PER_BROKER

# See exactly which IPs the brokers took
aws kafka list-nodes --cluster-arn <arn> \
  --query 'NodeInfoList[].BrokerNodeInfo.[BrokerId,ClientVpcIpAddress]' --output table
```

### CIDR guidance

| Item | Size per AZ | Notes |
|---|---|---|
| Broker subnet | **`/26`** (59 usable) | Fits 3 brokers with enormous room to grow to 12+ |
| Broker subnet, very large cluster | **`/25`** | 30+ brokers per AZ |
| Absolute minimum | `/28` | Works but leaves no growth room — don't |

Kafka clusters are small in address terms. `/26` per AZ across 3 AZs costs you 192 routable addresses total. That's cheap insurance.

### Consumers and producers

Your *clients* — Spark jobs, Flink apps, microservices — can absolutely live in **non-routable** subnets, as long as they're in the same VPC or a VPC with routes to the brokers. Client-to-broker traffic within the VPC uses local routing, no NAT involved. **Only the brokers need routable addresses.**

### If clients are in a different account or VPC with overlapping CIDRs

Two supported escapes:

1. **MSK multi-VPC connectivity / PrivateLink** — front the cluster with an NLB and publish an endpoint service. Consumers connect via an ENI in their own VPC, so overlapping CIDRs are irrelevant. Cross-Region PrivateLink has been supported since November 2024.
2. **A Kafka proxy layer** (e.g. an NLB per broker with distinct listener ports, plus per-broker `advertised.listeners` overrides). Workable, but you're maintaining a mapping table forever. Prefer option 1.

### Pros and cons of Kafka in routable space

| Pros | Cons |
|---|---|
| Protocol works as designed, no surprises | Consumes scarce routable addresses |
| On-prem producers/consumers connect directly | Must coordinate the range with the network team |
| Simple troubleshooting — addresses mean something | Re-IPing a live cluster later is painful |
| Rebalancing and broker replacement just work | AZ constraints limit placement flexibility |

---

## 6.2 Apache NiFi

**Verdict: DEPENDS ON YOUR FLOW DIRECTION. This is the most situational of the five.**

NiFi is a clustered data-movement tool. Two things about it drive the decision.

### Consideration 1: Site-to-Site

NiFi's **Site-to-Site (S2S)** protocol behaves like Kafka's metadata dance. When a remote NiFi (say, on-premises) wants to push data to your AWS cluster, it contacts one node, receives back **a list of all cluster nodes and their host/port pairs**, and then distributes data directly across them for load balancing.

Same failure mode as Kafka. If those hostnames resolve to `100.64.x`, the remote instance can't deliver.

- **On-prem NiFi pushes to AWS NiFi** → your nodes need **routable** addresses.
- **AWS NiFi pulls from on-prem sources** (or uses S2S in the outbound direction) → **non-routable is fine**, via private NAT.

### Consideration 2: Cluster coordination

NiFi nodes talk to each other constantly — cluster protocol, load-balanced connections between processors, and (in older versions) Zookeeper for coordination. All of this is *intra-VPC*, so non-routable space handles it perfectly. Just don't put nodes behind a NAT **from each other** — keep the whole cluster in one address family.

### Consideration 3: The UI

Users need the NiFi UI. Don't solve this by giving nodes routable addresses — put an **ALB in routable subnets** in front and leave the nodes wherever they belong. NiFi's UI is sticky-session sensitive, so enable session stickiness on the target group.

### Recommended layout

```
Routable /24 per AZ    -> ALB for the NiFi UI
Routable /25 per AZ    -> NiFi nodes  (ONLY if inbound S2S is required)
Non-routable /22 per AZ -> NiFi nodes (if pull-only)
Routable /28 per AZ    -> TGW attachment
```

### CIDR guidance

| Scenario | Size per AZ | Why |
|---|---|---|
| Nodes, inbound S2S needed | **`/25` routable** | NiFi clusters grow; 123 usable covers node churn during rolling replacement |
| Nodes, pull-only | **`/22` non-routable** | Be generous, it's free |
| UI load balancer | **`/27` minimum, `/24` recommended** | AWS requires /27 minimum for ALB subnets |

> **Rolling-upgrade gotcha:** during a blue/green node replacement you temporarily run double the nodes. Size for **2× your steady-state count**. A `/28` sized for exactly 11 nodes will fail an upgrade at the worst possible moment.

### Pros and cons

| Option | Pros | Cons |
|---|---|---|
| **Nodes routable** | Inbound S2S works; simple hybrid integration; easy debugging | Burns routable space; NiFi node counts fluctuate; upgrades need headroom |
| **Nodes non-routable** | Cheap addresses; scale freely; nodes unreachable from outside | Inbound S2S impossible; on-prem partners must be re-plumbed to pull-based or push via a load balancer instead |

---

## 6.3 Keycloak

**Verdict: NON-ROUTABLE, behind a ROUTABLE load balancer. The easiest decision of the five.**

### Why it's easy

Keycloak is a plain HTTPS application. It has no protocol that advertises its own address, no peer-to-peer client contract. Everything users do — login, token refresh, admin console — arrives over HTTP through a load balancer. **The load balancer needs a real address; Keycloak itself doesn't.**

Its outbound needs (LDAP/AD sync, identity-provider federation, SMTP, OIDC discovery of external providers) are all connections *it* starts, which NAT handles perfectly.

```
On-prem users ---> [ALB in ROUTABLE /24] ---> [Keycloak pods in NON-ROUTABLE /22]
                                                      |
                                       [private NAT in ROUTABLE] ---> on-prem Active Directory
                                                      |
                                       [Amazon RDS in NON-ROUTABLE /27]
```

### The one real complication: Infinispan clustering

Keycloak clusters its user sessions using **Infinispan/JGroups**, and nodes must discover each other. In AWS this uses either `JDBC_PING` (nodes write their addresses to a shared database table) or `DNS_PING` (headless-service DNS lookup on Kubernetes).

**Both work perfectly in non-routable space**, because all cluster traffic is intra-VPC. But note that nodes register their *own* addresses in that table — so all nodes must be in the same address family and mutually routable within the VPC. Don't split a Keycloak cluster across a NAT boundary.

### Load balancer requirements

- **ALB subnets require a `/27` minimum** in at least 2 AZs — AWS enforces this.
- Enable **sticky sessions** or ensure Infinispan replication is working; otherwise users get bounced mid-login.
- Set `KC_PROXY_HEADERS=xforwarded` (or `forwarded`) so Keycloak generates correct redirect URLs. Getting this wrong produces the classic "Invalid parameter: redirect_uri" that people mistakenly blame on networking.
- Health check `/health/ready` on the management port (9000 in recent versions).

### CIDR guidance

| Item | Size per AZ | Type |
|---|---|---|
| ALB | **`/24`** (`/27` absolute minimum) | Routable |
| Keycloak nodes/pods | **`/22`** | Non-routable |
| RDS/Aurora for Keycloak | **`/27`** | Non-routable |
| NAT Gateway (for LDAP outbound) | shared `/24` | Routable |

### Pros and cons

| Option | Pros | Cons |
|---|---|---|
| **Non-routable behind ALB** (recommended) | Minimal routable usage; scales freely; nodes not directly reachable; TLS terminates in one auditable place | One more component; must configure proxy headers correctly |
| **Routable directly** | Marginally simpler; direct debugging | Wastes routable space; exposes app servers; no central TLS/WAF point; genuinely no upside |

**There is no good reason to put Keycloak application nodes in routable space.** If someone proposes it, they're usually solving a debugging-access problem that SSM already solves.

---

## 6.4 Amazon OpenSearch Service

**Verdict: ROUTABLE if humans and on-prem systems query it directly. Non-routable if it's fronted by a proxy or only queried from inside the VPC.**

### How it consumes addresses

When you deploy OpenSearch into a VPC, the service places **one ENI per data node into your subnets**. Dedicated master nodes also consume ENIs. So your subnet must have enough free addresses for the whole cluster — and for the **blue/green deployment** that happens on almost every configuration change.

**This is the trap.** OpenSearch performs blue/green updates for version upgrades, instance type changes, and many setting changes. During the switchover it stands up a **complete parallel set of nodes** before retiring the old ones. If your subnet doesn't have room for 2× the node count, **the update fails** — sometimes after hours of data migration.

> **Size OpenSearch subnets for double your node count. This is the single most common OpenSearch networking failure.**

### Which way to go

- **Analysts hit OpenSearch Dashboards from the corporate network** → routable. Dashboards is served by the domain endpoint itself, and there's no clean way to proxy it without breaking some features.
- **Only applications inside the VPC query it** → non-routable, and give it a `/24` of free space.
- **Middle ground** → put the domain in non-routable space and front it with an NGINX proxy or ALB in routable space. This works but you'll fight cookie paths, Dashboards' basepath setting, and SAML/Cognito redirect URLs. Budget real time for it.

### CLI

```bash
aws opensearch create-domain \
  --domain-name analytics \
  --engine-version "OpenSearch_2.13" \
  --cluster-config InstanceType=r6g.large.search,InstanceCount=6,\
ZoneAwarenessEnabled=true,ZoneAwarenessConfig={AvailabilityZoneCount=3},\
DedicatedMasterEnabled=true,DedicatedMasterType=m6g.large.search,DedicatedMasterCount=3 \
  --vpc-options SubnetIds=subnet-1a,subnet-1b,subnet-1c,SecurityGroupIds=sg-opensearch \
  --ebs-options EBSEnabled=true,VolumeType=gp3,VolumeSize=500 \
  --encryption-at-rest-options Enabled=true \
  --node-to-node-encryption-options Enabled=true \
  --domain-endpoint-options EnforceHTTPS=true

# Watch the addresses it actually consumed
aws ec2 describe-network-interfaces \
  --filters "Name=description,Values=*OpenSearch*" \
  --query 'NetworkInterfaces[].[PrivateIpAddress,SubnetId,Description]' --output table
```

Also note: **the number of subnets must match your AZ count** (1, 2, or 3), and you can't change VPC/subnet placement later without a blue/green migration.

### CIDR guidance

| Cluster size | Size per AZ | Reasoning |
|---|---|---|
| Small (≤6 data nodes) | **`/26`** = 59 usable | Fits 2× growth comfortably |
| Medium (up to 20 nodes/AZ) | **`/25`** = 123 usable | Blue/green headroom |
| Large (50+ nodes/AZ) | **`/24`** = 251 usable | Plus masters, plus blue/green |

Add **+3 addresses per AZ** for dedicated master nodes and always compute against 2× your node count.

### Pros and cons

| Option | Pros | Cons |
|---|---|---|
| **Routable** | Dashboards works out of the box from corporate network; SAML/Cognito redirects straightforward; simple | Consumes a meaningful block of routable space; blue/green doubles the requirement |
| **Non-routable + proxy** | Saves routable space; single ingress point for auth and logging | Proxy config for Dashboards is fiddly; SAML redirect URIs, basepath, and cookies all need attention; extra component to run |
| **Non-routable, VPC-internal only** | Cheapest, simplest, most secure | Analysts can't reach Dashboards without a jump host or VDI |

---

## 6.5 Data Lakes (S3, EMR, Glue, Athena, EKS/Spark, Redshift)

**Verdict: NON-ROUTABLE, aggressively. This is where the whole strategy pays for itself.**

### Why this is the clearest case

Data lake compute has three properties that make it perfect for non-routable space:

1. **The data isn't in your VPC.** S3 is a regional service reached via a gateway endpoint. Your Spark executors never need a route to your office.
2. **The machines are ephemeral and numerous.** An EMR cluster spins up 200 task nodes for an hour and dies. EKS assigns an IP to *every pod*.
3. **Nothing outside ever initiates a connection to them.** You submit jobs *to* the cluster's control plane; nobody dials an executor.

### The address math that forces the issue

With the standard VPC CNI on EKS, **every pod gets a real VPC IP address**. A modest platform:

```
   40 nodes × 30 pods each          = 1,200 addresses
 + warm-pool / prefix-delegation buffer (~30%) = ~1,600
 + rolling deployments (2× during rollout)     = ~3,200
```

That's a `/20` of address space for *one cluster* — half of what many companies allocate to an entire business unit. Do this in routable space twice and you're finished.

**EKS custom networking** is the fix: nodes keep primary ENIs in routable space (needed for the EKS control plane cross-account ENIs), while pods get addresses from a secondary `100.64.x` CIDR.

```bash
aws ec2 associate-vpc-cidr-block --vpc-id $VPC_ID --cidr-block 100.64.0.0/16

POD_SUBNET_1A=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 100.64.0.0/19 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)

kubectl set env daemonset aws-node -n kube-system AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true
kubectl set env daemonset aws-node -n kube-system ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone
```

Then one `ENIConfig` per AZ:

```yaml
apiVersion: crd.k8s.amazonaws.com/v1alpha1
kind: ENIConfig
metadata:
  name: us-east-1a
spec:
  subnet: subnet-0pod1a
  securityGroups:
    - sg-0podsg
```

> Note that nodes must be recycled after enabling this — existing pods keep their old addresses.

### Also do these

**Turn on prefix delegation** (Nitro instances only). Instead of assigning addresses one at a time, the CNI allocates `/28` blocks, dramatically increasing pod density per node and reducing API churn:

```bash
kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=true
```

**Give EMR and Glue their own large non-routable subnets.** Glue creates ENIs per DPU; a big job can create hundreds simultaneously and then release them, which also means you need headroom for AWS's ENI cleanup lag.

**Add gateway endpoints for S3 *and* DynamoDB.** Free, and DynamoDB is used by EMRFS consistent view and many job-bookkeeping patterns.

**Add interface endpoints for Glue, Athena, KMS, Secrets Manager, STS, CloudWatch Logs, and ECR** (both `ecr.api` and `ecr.dkr`, plus S3 for layer downloads). Otherwise every container image pull and every log flush goes through your NAT Gateway at $0.045/GB.

### CIDR guidance

| Component | Size per AZ | Type |
|---|---|---|
| EKS pods (Spark) | **`/18`** (16,379) | Non-routable |
| EKS nodes (primary ENIs) | `/24` | Routable *(control plane ENIs)* |
| EMR core + task nodes | **`/20`** | Non-routable |
| Glue ENIs | **`/22`** | Non-routable |
| Redshift cluster | `/27` | Non-routable (routable if queried from on-prem via JDBC) |
| RDS/Aurora metastore | `/27` | Non-routable |
| Interface endpoints | `/26` | Routable if on-prem needs them, else non-routable |

### Pros and cons

| Option | Pros | Cons |
|---|---|---|
| **Non-routable compute** (recommended) | Effectively unlimited scale; routable space preserved for what needs it; smaller blast radius; cheaper IPAM governance | NAT data-processing charges if you skip endpoints; slightly more complex CNI config; troubleshooting requires understanding two address families |
| **Routable compute** | Direct on-prem debugging; conceptually simpler | You will run out — usually about 8 months in, usually mid-project |

---

<a name="part-7-cidr-sizing-the-master-plan"></a>
# Part 7: CIDR Sizing — The Master Plan

## A complete reference design

Assume your network team gave you **`10.20.0.0/16`** as routable space and you've adopted **`100.64.0.0/16`** as non-routable, across **3 Availability Zones**.

### Routable allocation (from 10.20.0.0/16)

| Purpose | AZ-a | AZ-b | AZ-c | Size |
|---|---|---|---|---|
| Public / ingress ALB + NAT GW | `10.20.0.0/24` | `10.20.1.0/24` | `10.20.2.0/24` | /24 |
| Internal load balancers | `10.20.3.0/24` | `10.20.4.0/24` | `10.20.5.0/24` | /24 |
| Interface VPC endpoints | `10.20.6.0/26` | `10.20.6.64/26` | `10.20.6.128/26` | /26 |
| Route 53 Resolver endpoints | `10.20.6.192/28` | `10.20.6.208/28` | `10.20.6.224/28` | /28 |
| TGW attachment | `10.20.7.0/28` | `10.20.7.16/28` | `10.20.7.32/28` | /28 |
| Kafka / MSK brokers | `10.20.8.0/26` | `10.20.8.64/26` | `10.20.8.128/26` | /26 |
| OpenSearch nodes | `10.20.9.0/25` | `10.20.9.128/25` | `10.20.10.0/25` | /25 |
| NiFi nodes (if inbound S2S) | `10.20.11.0/25` | `10.20.11.128/25` | `10.20.12.0/25` | /25 |
| EKS node primary ENIs | `10.20.13.0/24` | `10.20.14.0/24` | `10.20.15.0/24` | /24 |
| **RESERVED — DO NOT ALLOCATE** | `10.20.16.0/20` … `10.20.255.0/24` | | | ~**75%** |

### Non-routable allocation (from 100.64.0.0/16)

| Purpose | AZ-a | AZ-b | AZ-c | Size |
|---|---|---|---|---|
| EKS pods (Spark/streaming) | `100.64.0.0/18` | `100.64.64.0/18` | `100.64.128.0/18` | /18 |
| EMR core + task | `100.64.192.0/20` | `100.64.208.0/20` | `100.64.224.0/20` | /20 |
| Glue ENIs | `100.64.240.0/22` | `100.64.244.0/22` | `100.64.248.0/22` | /22 |
| Keycloak + app tier | `100.64.252.0/22` | (see note) | | /22 |
| Databases (RDS/Aurora/Redshift) | `100.64.255.0/27`… | | | /27 |

*(When you run low here, attach `100.65.0.0/16` as another secondary CIDR. That's the entire point of using CGNAT space.)*

## The single most important rule

> **Allocate no more than 25–30% of your routable range on day one.**

Every failed network design I've seen shared one cause: someone carved up the whole `/16` at the start, because the spreadsheet looked tidy. Eighteen months later a new workload needed a `/24` and there wasn't one — and by then re-IPing meant coordinated downtime across five teams.

Unallocated space costs nothing. Fragmentation costs everything.

## Sizing formulas

```
Kubernetes pod subnet per AZ:
  (max_nodes_per_AZ × max_pods_per_node × 1.3 warm-pool) × 2 rollout
  Then round UP to the next power of two, then go one size bigger.

OpenSearch subnet per AZ:
  (data_nodes_per_AZ + master_nodes_per_AZ) × 2 blue/green
  + 20% growth, minimum /26

Kafka broker subnet per AZ:
  planned_brokers_per_AZ × 3 (for expansion + replacement)
  minimum /26

Load balancer subnet per AZ:
  ALB scales its own ENIs under load; minimum /27 is enforced by AWS
  but /24 is the practical recommendation

Interface endpoint subnet per AZ:
  number_of_endpoint_services + 50% growth, minimum /26
```

## Rules that will save you

1. **Never let two VPCs that might ever connect share a routable CIDR.** Overlap cannot be fixed by TGW or peering. Only NAT or PrivateLink works around it, and both cost you.
2. **Align subnets on power-of-two boundaries.** `10.20.8.0/26`, `10.20.8.64/26`, `10.20.8.128/26` — never improvised offsets. Misaligned CIDRs are rejected or silently canonicalized (AWS turns `100.68.0.18/18` into `100.68.0.0/18` without asking).
3. **Same size in every AZ.** Asymmetric subnets guarantee that one AZ fills first and your autoscaler goes lopsided.
4. **Reserve a `/28` per AZ for the TGW attachment** even if you don't have a TGW yet.
5. **Write it down where others will find it** — AWS IPAM, or at minimum a version-controlled file. See Part 13.
6. **Tag every subnet with its tier** so automation can find the right one:

```bash
aws ec2 create-tags --resources $SUBNET_ID \
  --tags Key=network-tier,Value=non-routable \
         Key=workload,Value=spark \
         Key=kubernetes.io/role/internal-elb,Value=1
```

---

<a name="part-8-pros-and-cons-of-every-option"></a>
# Part 8: Pros and Cons of Every Option

## Routable vs. non-routable, head to head

| Dimension | Routable | Non-routable |
|---|---|---|
| **Address supply** | Scarce, budgeted, political | Effectively unlimited |
| **Inbound from outside VPC** | Yes | No |
| **Outbound to internet** | Direct via IGW/NAT | Via NAT only |
| **Outbound to on-prem** | Direct via TGW | Requires private NAT |
| **Can overlap between VPCs** | Never | Yes, by design |
| **Works with TGW/peering directly** | Yes | No (needs NAT or PrivateLink) |
| **Cost** | Free, but governance overhead | NAT hourly + per-GB charges |
| **Troubleshooting** | Address is meaningful and traceable | Address is ambiguous across VPCs; flow logs need VPC context |
| **Service compatibility** | Universal | Verify per service |
| **Blast radius if compromised** | Larger — reachable from the enterprise | Smaller — but still full internal access |

## Connectivity options compared

| Option | Handles CIDR overlap? | IPs consumed | Cost | Best for |
|---|---|---|---|---|
| **VPC Peering** | No | 0 | Free (same-AZ data free) | Two VPCs, simple, permanent |
| **Transit Gateway** | No | /28 per AZ per VPC | Hourly attachment + per-GB | Many VPCs, hybrid, central control |
| **Private NAT Gateway** | **Yes** | 1 per AZ | Hourly + per-GB | Non-routable → routable egress |
| **PrivateLink / endpoint service** | **Yes** | 1 per AZ per consumer | Hourly + per-GB | One-way service exposure, cross-account, cross-Region |
| **Cloud WAN** | No (but centralizes NAT) | Similar to TGW | Higher | Global, multi-Region, policy-driven |
| **Gateway endpoint (S3/DDB)** | N/A | **0** | **Free** | Always. No exceptions. |

## NAT strategies compared

| Strategy | Pros | Cons |
|---|---|---|
| **NAT GW per AZ** (recommended) | No cross-AZ data charges; AZ failure is contained | 3× hourly cost |
| **Single shared NAT GW** | Cheapest hourly | Cross-AZ data charges may exceed the savings; single point of failure |
| **Centralized egress VPC** | One place for inspection and egress filtering; fewer NAT GWs overall | Adds TGW data processing charges; extra hop of latency |
| **NAT instance (self-managed)** | Cheap at low volume | You own patching, failover, and bandwidth ceilings. Not worth it in 2026. |

## Kubernetes networking modes compared

| Mode | Pod IPs from | Pros | Cons |
|---|---|---|---|
| **VPC CNI, default** | Node's subnet | Simplest; pods are first-class VPC citizens; SGs per pod possible | Devours routable addresses |
| **VPC CNI + custom networking** | Secondary CIDR | Huge pod space; keeps routable space free | Node recycle required; slightly reduced ENI slots on node; more config |
| **VPC CNI + prefix delegation** | /28 prefixes | Far higher pod density; fewer API calls | Nitro instances only; can fragment addresses |
| **Overlay CNI (Calico VXLAN, Cilium)** | Fully virtual | Zero VPC addresses for pods | Loses VPC-native SGs and flow-log visibility; encapsulation overhead; harder debugging |

---

<a name="part-9-best-practices-and-anti-patterns"></a>
# Part 9: Best Practices and Anti-Patterns

## The checklist

**Planning**

- [ ] Routable range formally allocated and recorded by the network team
- [ ] Non-routable range agreed with the network team (confirm `100.64` isn't already in use at your WAN edge)
- [ ] No more than 30% of routable space allocated on day one
- [ ] Identical subnet sizes across all three AZs
- [ ] Every subnet sized for 2× the steady-state requirement
- [ ] Documented in AWS IPAM, not a wiki page someone will forget

**Building**

- [ ] Every subnet explicitly associated with a route table (never rely on main)
- [ ] Dedicated `/28` subnets for TGW attachments
- [ ] S3 **and** DynamoDB gateway endpoints on every route table
- [ ] Interface endpoints for the AWS services you actually call
- [ ] One NAT Gateway per AZ, in routable subnets
- [ ] Security groups reference other security groups, not CIDRs
- [ ] Consistent tagging: `network-tier`, `workload`, `Name`
- [ ] Any non-RFC1918 range validated against each managed service before committing

**Operating**

- [ ] VPC Flow Logs on, delivered to S3 in Parquet, partitioned
- [ ] CloudWatch alarm on subnet address exhaustion
- [ ] Runbook for adding a secondary CIDR under pressure
- [ ] Quarterly review of address utilization
- [ ] Network changes go through infrastructure-as-code, never the console

## Alarm on address exhaustion before it bites

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "subnet-ips-low-spark-1a" \
  --namespace "Custom/VPC" \
  --metric-name "AvailableIpAddresses" \
  --dimensions Name=SubnetId,Value=subnet-0abc \
  --statistic Minimum --period 300 --evaluation-periods 2 \
  --threshold 500 --comparison-operator LessThanThreshold \
  --alarm-actions arn:aws:sns:us-east-1:123456789012:network-alerts
```

Feed it with a scheduled Lambda that calls `describe-subnets` and publishes `AvailableIpAddressCount`. Ten lines of code that will save you an outage.

Or check by hand across the whole account:

```bash
aws ec2 describe-subnets \
  --query 'sort_by(Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,
           CIDR:CidrBlock,Free:AvailableIpAddressCount}, &Free)' \
  --output table
```

## Anti-patterns — the ten ways this goes wrong

**1. "We'll just use 10.0.0.0/16 for everything."**
So did four other teams. Now none of you can connect, and TGW can't help. *Fix: central IPAM allocation before any VPC is created.*

**2. Putting Kafka brokers behind NAT.**
Metadata responses hand clients unreachable addresses. Symptoms look like broker instability, not networking. *Fix: brokers in routable subnets, or PrivateLink.*

**3. Sizing OpenSearch subnets for exactly the current node count.**
The next blue/green deployment fails. *Fix: 2× node count, minimum /26.*

**4. Relying on the main route table.**
A subnet you forgot to associate quietly inherits whatever the main table says — often internet access you didn't intend, or none at all. *Fix: explicit association for every subnet, enforced in code.*

**5. Treating non-routable as a security boundary.**
It isn't. Everything inside the VPC still reaches it, and NAT gives it unrestricted egress. *Fix: security groups always; egress filtering for sensitive tiers.*

**6. Forgetting gateway endpoints.**
A petabyte of S3 reads through a NAT Gateway is roughly $45,000 in data processing charges you didn't need to pay. *Fix: one command, Part 4.*

**7. Security group rules written as CIDRs.**
They break the moment you add a subnet or migrate to a new range — during exactly the migration this document describes. *Fix: `--source-group`.*

**8. Deploying the same non-routable CIDR in two VPCs that later need to talk.**
This is *allowed* and *intended*, but only if you never need direct routing between them. *Fix: plan the PrivateLink or private-NAT path up front.*

**9. NACLs used as a primary control.**
Stateless rules break return traffic in ways that take days to diagnose. *Fix: coarse guardrails only; do real work in security groups.*

**10. No documentation.**
Two years on, nobody knows why `100.64.192.0/20` exists or whether it's safe to reuse. *Fix: IPAM with descriptions, plus a README in the network repo.*

---

<a name="part-10-cost"></a>
# Part 10: Cost

Approximate US regional pricing — verify current rates, these move.

| Item | Roughly |
|---|---|
| VPC, subnets, route tables, security groups | **Free** |
| Internet Gateway | **Free** |
| Gateway VPC endpoint (S3, DynamoDB) | **Free** |
| NAT Gateway | ~$0.045/hour (~$33/month) + ~$0.045/GB processed |
| Interface VPC endpoint | ~$0.01/hour per AZ + ~$0.01/GB |
| Transit Gateway attachment | ~$0.05/hour per attachment + ~$0.02/GB |
| Data transfer between AZs | ~$0.01/GB each direction |
| Elastic IP (attached) | Free while attached to a running resource |
| Elastic IP (idle) | ~$0.005/hour — charged even for in-use IPv4 since Feb 2024 |
| VPC Flow Logs to S3 | ~$0.25/GB ingested (plus storage) |

## Where the money actually goes

A data platform's network bill is usually **NAT Gateway data processing**, and usually for traffic that never needed to be there:

| Traffic | Through NAT | With endpoint |
|---|---|---|
| 500 TB/month S3 reads | ~$22,500/month | **$0** (gateway endpoint) |
| 10 TB/month ECR image pulls | ~$450/month | ~$100/month (interface endpoint) |
| 5 TB/month CloudWatch Logs | ~$225/month | ~$50/month |

**Run this and look at the number before you do anything else:**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value=nat-0abc \
  --start-time $(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 2592000 --statistics Sum
```

Divide by 1e9 for GB, multiply by $0.045. If that number is large, your first move is gateway endpoints, then interface endpoints for your top talkers.

## The cost of routable vs. non-routable

Non-routable space is not free — it costs you NAT charges for anything that must reach out. But routable space has a hidden cost too: **the engineering time of running out.** A re-IP project for a live data platform is typically weeks of coordination and at least one maintenance window per system. Non-routable space with well-placed endpoints is almost always the cheaper total.

---

<a name="part-11-troubleshooting-playbook"></a>
# Part 11: Troubleshooting Playbook

## The order to check things

When something can't connect, work through these in order. Resist the urge to skip ahead — the answer is in step 1 or 2 more often than anyone expects.

```
1. DNS      -> Does the name resolve, and to what?
2. Routing  -> Does the source subnet have a path to that address?
3. Security -> Do the security groups allow it, in the right direction?
4. NACLs    -> Are they default-allow, or did someone get creative?
5. The app  -> Is it listening on the right interface and port?
```

### Step 1: DNS

```bash
# From the source machine
dig +short b-1.mycluster.abc123.c2.kafka.us-east-1.amazonaws.com
nslookup my-opensearch-domain.us-east-1.es.amazonaws.com
```

**Look at what came back.** If it's `100.64.x.x` and you're connecting from on-premises, you've found your bug — stop here.

### Step 2: Routing

```bash
SUBNET=subnet-0abc
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET" \
  --query 'RouteTables[].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId,TransitGatewayId,State]' \
  --output table
```

If this returns nothing, **the subnet is using the main route table** — a top-three cause of mystery failures.

For the destination side, verify the return path exists too. Routing is not automatically symmetric, and asymmetric routing produces "it connects but hangs" behavior that looks like an application bug.

### Step 3: Let AWS analyze it for you

The **Reachability Analyzer** simulates the whole path and tells you the exact hop that blocks it. It's dramatically faster than manual inspection.

```bash
PATH_ID=$(aws ec2 create-network-insights-path \
  --source i-0source --destination i-0dest \
  --destination-port 9098 --protocol tcp \
  --query 'NetworkInsightsPath.NetworkInsightsPathId' --output text)

ANALYSIS=$(aws ec2 start-network-insights-analysis \
  --network-insights-path-id $PATH_ID \
  --query 'NetworkInsightsAnalysis.NetworkInsightsAnalysisId' --output text)

sleep 30

aws ec2 describe-network-insights-analyses \
  --network-insights-analysis-ids $ANALYSIS \
  --query 'NetworkInsightsAnalyses[0].[NetworkPathFound,Explanations]'
```

`NetworkPathFound: false` comes with an `Explanations` block naming the exact security group or missing route. Costs about $0.10 per analysis. Worth every cent.

### Step 4: Flow Logs

```bash
aws ec2 create-flow-logs \
  --resource-type Subnet --resource-ids $SUBNET \
  --traffic-type ALL \
  --log-destination-type s3 \
  --log-destination arn:aws:s3:::my-flow-logs/ \
  --log-format '${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${action} ${log-status} ${vpc-id} ${subnet-id} ${pkt-srcaddr} ${pkt-dstaddr}'
```

Two fields matter enormously here:

- **`action`** — `REJECT` means a security group or NACL blocked it. `ACCEPT` with no reply means routing or the application.
- **`pkt-srcaddr` vs. `srcaddr`** — these differ when NAT is involved, letting you see the address *before* translation. Indispensable for debugging private NAT paths.

## Symptom → cause table

| Symptom | Likely cause | Check |
|---|---|---|
| Kafka: `TimeoutException: Topic not present in metadata` | Brokers advertising non-routable addresses | `dig` the broker names from the client |
| Kafka: bootstrap works, produce fails | Bootstrap reachable, individual brokers not | Test connectivity to each broker port directly |
| OpenSearch update fails after hours | Not enough free IPs for blue/green | `AvailableIpAddressCount` on the domain subnets |
| Pods stuck in `ContainerCreating`, `failed to assign an IP` | Pod subnet exhausted | `describe-subnets`, check the CNI logs |
| Glue job fails with ENI errors | Subnet exhausted, or ENI cleanup lag | Free address count; wait and retry |
| Instance can reach S3 but not the internet | Gateway endpoint present, `0.0.0.0/0` route missing | `describe-route-tables` |
| Instance can reach internet but not on-prem | No route to TGW, or private NAT missing | Route table + TGW route table |
| Two VPCs can't talk despite peering | Overlapping CIDRs | Compare `describe-vpcs` output |
| Keycloak: `Invalid parameter: redirect_uri` | Proxy headers misconfigured | `KC_PROXY_HEADERS`, ALB `X-Forwarded-*` |
| NiFi cluster won't form | Nodes split across NAT, or SG blocks cluster port | SG rules for the cluster protocol port |
| Connection succeeds then hangs | Asymmetric routing, or stateless NACL blocking return traffic | NACL ephemeral port range 1024–65535 |
| Everything intermittently slow | Cross-AZ traffic, or NAT bandwidth saturation | `AWS/NATGateway` `ErrorPortAllocation` and `PacketsDropCount` |

## NAT port exhaustion

One NAT Gateway supports about 55,000 simultaneous connections **per unique destination**. A Spark cluster hammering one endpoint can exhaust this.

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway --metric-name ErrorPortAllocation \
  --dimensions Name=NatGatewayId,Value=nat-0abc \
  --start-time $(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 --statistics Sum
```

Anything above zero means dropped connections. Fixes: add NAT Gateways (traffic is distributed by subnet), or better, add VPC endpoints so the traffic never reaches NAT.

---

<a name="part-12-rescue-plans"></a>
# Part 12: Rescue Plans — When You've Already Run Out

You're mid-project, subnets are full, and you can't get more routable space. Here is the order of operations, cheapest and least disruptive first.

## Level 1: Add a secondary CIDR (hours, no downtime)

```bash
aws ec2 associate-vpc-cidr-block --vpc-id $VPC_ID --cidr-block 100.64.0.0/16
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 100.64.0.0/18 \
  --availability-zone us-east-1a
```

Then move new workloads into it. **Nothing existing is disturbed.** This alone solves most emergencies. Note the EKS caveat: the control plane may take up to an hour to recognize a newly associated CIDR before `kubectl exec`, `logs`, and `port-forward` work against nodes in it.

## Level 2: Move ephemeral workloads (days)

Migrate the biggest, most disposable consumers first — they're the ones that will move without anyone noticing:

1. EKS pods, via custom networking (recycle node groups one at a time)
2. Glue and EMR — just point the job configuration at new subnets
3. Batch and ECS tasks — update the task definition network configuration

This typically frees 60–80% of the routable space, because those workloads were always the bulk of it.

## Level 3: Add a private NAT Gateway (days)

If the new non-routable workloads need on-prem access:

```bash
PNAT=$(aws ec2 create-nat-gateway --subnet-id $SUBNET_ROUTABLE \
  --connectivity-type private --query 'NatGateway.NatGatewayId' --output text)

aws ec2 create-route --route-table-id $RTB_NONROUTABLE \
  --destination-cidr-block 10.0.0.0/8 --nat-gateway-id $PNAT
```

Costs one routable address per AZ and buys unlimited non-routable outbound.

## Level 4: PrivateLink for the stubborn cases (weeks)

When two VPCs overlap and must communicate, or a partner needs one specific service:

```bash
# Provider side
aws ec2 create-vpc-endpoint-service-configuration \
  --network-load-balancer-arns arn:aws:elasticloadbalancing:... \
  --acceptance-required

# Consumer side
aws ec2 create-vpc-endpoint --vpc-id $CONSUMER_VPC \
  --vpc-endpoint-type Interface \
  --service-name com.amazonaws.vpce.us-east-1.vpce-svc-0abc \
  --subnet-ids subnet-consumer-a subnet-consumer-b
```

Overlapping CIDRs become irrelevant, because the consumer reaches the service through an ENI in their own address space.

## Level 5: Re-IP (months — avoid)

New VPC, migrate everything, cut over with DNS. Expect one maintenance window per stateful system. **This is what Levels 1–4 exist to prevent.**

If you're here, take the opportunity to do it properly: IPAM allocation, 30% initial usage, dedicated TGW subnets, and this document's layout.

---

<a name="part-13-ipv6-ipam-and-the-future"></a>
# Part 13: IPv6, IPAM, and Where This Is All Heading

## AWS IPAM

Amazon VPC IP Address Manager is the supported way to stop managing addresses in a spreadsheet. It gives you a hierarchy of pools, automatic allocation, and — most valuable — **utilization monitoring and overlap detection across your whole organization**.

```bash
IPAM_ID=$(aws ec2 create-ipam \
  --operating-regions RegionName=us-east-1 RegionName=eu-west-1 \
  --query 'Ipam.IpamId' --output text)

SCOPE=$(aws ec2 describe-ipams --ipam-ids $IPAM_ID \
  --query 'Ipams[0].PrivateDefaultScopeId' --output text)

# Top-level routable pool
ROUTABLE_POOL=$(aws ec2 create-ipam-pool \
  --ipam-scope-id $SCOPE --address-family ipv4 \
  --description "Corporate routable space" \
  --query 'IpamPool.IpamPoolId' --output text)

aws ec2 provision-ipam-pool-cidr --ipam-pool-id $ROUTABLE_POOL --cidr 10.0.0.0/8

# Separate pool for non-routable — keeps the two governance models apart
NONROUTABLE_POOL=$(aws ec2 create-ipam-pool \
  --ipam-scope-id $SCOPE --address-family ipv4 \
  --description "Non-routable CGNAT space - never advertised" \
  --query 'IpamPool.IpamPoolId' --output text)

aws ec2 provision-ipam-pool-cidr --ipam-pool-id $NONROUTABLE_POOL --cidr 100.64.0.0/10
```

Then create VPCs by *asking for* space rather than picking it:

```bash
aws ec2 create-vpc --ipv4-ipam-pool-id $ROUTABLE_POOL --ipv4-netmask-length 16
```

**Two pools, two policies.** The routable pool is scarce and requires justification. The non-routable pool is generous and self-service. Encoding that difference in tooling is what makes the discipline stick after the architects move on.

## IPv6 — the actual long-term answer

Every VPC can have an IPv6 range alongside IPv4. AWS gives you a `/56` for free, and there is no shortage — the address space is effectively infinite.

```bash
aws ec2 associate-vpc-cidr-block --vpc-id $VPC_ID --amazon-provided-ipv6-cidr-block

aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.20.20.0/24 \
  --ipv6-cidr-block 2600:1f18:abcd:1200::/64 \
  --availability-zone us-east-1a
```

**With IPv6, the entire routable/non-routable distinction disappears.** There's no reason to conserve, no need for NAT, no overlapping CIDRs.

### Why you probably still can't

- On-prem networks and Direct Connect circuits often aren't dual-stacked
- Some third-party appliances and older applications don't support it
- Client libraries occasionally misbehave with IPv6 literals
- Managed service support is good but not universal — check per service

### The realistic path

1. **Today:** dual-stack new VPCs. IPv4 for compatibility, IPv6 available.
2. **Next:** IPv6-only subnets for new, purely internal workloads. Use **DNS64 + NAT64** so they can still reach IPv4-only destinations.
3. **Eventually:** IPv6 primary, IPv4 for legacy only.

Egress-only internet gateway is the IPv6 equivalent of a NAT Gateway — outbound only, and **free**:

```bash
aws ec2 create-egress-only-internet-gateway --vpc-id $VPC_ID
```

## Other things worth watching

- **Cloud WAN with service insertion** — centralizes private NAT Gateways and PrivateLink at a global level, letting you assign CGNAT space per Region and translate at the edge into company-routable space. Worth evaluating if you're multi-Region.
- **VPC Lattice** — application-layer service-to-service connectivity that sidesteps IP routing entirely, including across overlapping CIDRs.
- **Prefix delegation and higher pod density** — reduces address pressure on EKS without changing your CIDR plan.

---

<a name="part-14-cheat-sheet-and-glossary"></a>
# Part 14: Cheat Sheet and Glossary

## Command cheat sheet

```bash
# ---------- Inspect ----------
# All CIDRs on a VPC
aws ec2 describe-vpcs --vpc-ids $VPC_ID \
  --query 'Vpcs[0].CidrBlockAssociationSet[].CidrBlock'

# Every subnet with free address count, sorted by most-full first
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'sort_by(Subnets[].{Name:Tags[?Key==`Name`]|[0].Value,
           AZ:AvailabilityZone,CIDR:CidrBlock,Free:AvailableIpAddressCount}, &Free)' \
  --output table

# What route table does this subnet use?
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
  --query 'RouteTables[].[RouteTableId,Routes[].DestinationCidrBlock]'

# Which subnets fell through to the main route table?
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[?Associations[?Main==`true`]].RouteTableId'

# Who is using addresses in this subnet?
aws ec2 describe-network-interfaces \
  --filters "Name=subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkInterfaces[].[PrivateIpAddress,InterfaceType,Description]' \
  --output table

# All VPC endpoints
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'VpcEndpoints[].[ServiceName,VpcEndpointType,State]' --output table

# ---------- Build ----------
aws ec2 associate-vpc-cidr-block --vpc-id $VPC_ID --cidr-block 100.64.0.0/16
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 100.64.0.0/18 --availability-zone us-east-1a
aws ec2 create-route --route-table-id $RTB --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT
aws ec2 create-route --route-table-id $RTB --destination-cidr-block 10.0.0.0/8 --transit-gateway-id $TGW
aws ec2 create-nat-gateway --subnet-id $SUBNET --connectivity-type private
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.us-east-1.s3 \
  --vpc-endpoint-type Gateway --route-table-ids $RTB

# ---------- Diagnose ----------
aws ec2 create-network-insights-path --source i-0a --destination i-0b --destination-port 443 --protocol tcp
aws ec2 create-flow-logs --resource-type Subnet --resource-ids $SUBNET --traffic-type ALL \
  --log-destination-type s3 --log-destination arn:aws:s3:::my-logs/

# ---------- Test safely ----------
# Every mutating EC2 command supports --dry-run
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 100.64.0.0/18 \
  --availability-zone us-east-1a --dry-run
```

## The one-page decision summary

| Component | Placement | Size per AZ |
|---|---|---|
| **Kafka / MSK brokers** | **Routable** | /26 |
| Kafka clients | Non-routable | with the app |
| **NiFi nodes** (inbound S2S) | **Routable** | /25 |
| NiFi nodes (pull-only) | Non-routable | /22 |
| NiFi UI load balancer | **Routable** | /24 |
| **Keycloak nodes** | Non-routable | /22 |
| Keycloak ALB | **Routable** | /24 |
| **OpenSearch** (direct queries) | **Routable** | /25, ×2 for blue/green |
| OpenSearch (VPC-internal only) | Non-routable | /24 |
| **EKS pods / Spark** | Non-routable | /18 |
| EKS node primary ENIs | **Routable** | /24 |
| **EMR core + task** | Non-routable | /20 |
| **Glue ENIs** | Non-routable | /22 |
| RDS / Aurora / Redshift | Non-routable | /27 |
| Interface VPC endpoints | Routable if on-prem needs them | /26 |
| NAT Gateways | **Routable** | shared /24 |
| TGW attachment | **Routable** | /28 |

## Glossary

**ALB** — Application Load Balancer. Layer 7. Requires /27 minimum subnets in 2+ AZs.

**AZ** — Availability Zone. A physically separate datacenter within a Region.

**Blue/green** — Deployment style where a full parallel environment is built before switching over. Doubles address requirements temporarily.

**CGNAT space** — `100.64.0.0/10`, defined by RFC 6598 for carrier-grade NAT. The conventional choice for non-routable AWS subnets.

**CIDR** — Classless Inter-Domain Routing. The `/16` notation. Bigger number = smaller network.

**CNI** — Container Network Interface. On EKS, the AWS VPC CNI gives every pod a real VPC address by default.

**ENI** — Elastic Network Interface. A virtual network card. Every address consumed belongs to one.

**Gateway endpoint** — Free, IP-free private access to S3 and DynamoDB via route table injection.

**IGW** — Internet Gateway. Bidirectional internet access for a VPC. Free.

**IPAM** — IP Address Manager. AWS's service for allocating and tracking address space.

**NACL** — Network ACL. Stateless, subnet-level packet filter. Use sparingly.

**NAT** — Network Address Translation. Rewrites source addresses so many machines share one. Outbound only.

**Non-routable** — Address space deliberately not advertised outside the VPC, safe to reuse across VPCs.

**PrivateLink** — Private, one-directional service access via an ENI in the consumer's VPC. Immune to CIDR overlap.

**Private NAT Gateway** — NAT that translates to a private address instead of a public one. Enables non-routable → on-prem egress.

**RFC 1918** — Defines the private ranges `10/8`, `172.16/12`, `192.168/16`.

**RFC 6598** — Defines the shared CGNAT range `100.64.0.0/10`.

**Route table** — The list of directions for a subnet. The actual mechanism behind "routable."

**Routable** — Address space that's unique within your organization and advertised to it.

**Secondary CIDR** — An additional address range attached to an existing VPC. Up to 5 by default, 50 with a quota increase.

**Security group** — Stateful, ENI-level firewall. Your primary control. Reference other SGs, not CIDRs.

**Site-to-Site (S2S)** — NiFi's cluster-aware transfer protocol. Advertises node addresses, so it behaves like Kafka.

**TGW** — Transit Gateway. Central routing hub. Cannot resolve overlapping CIDRs.

**VPC** — Virtual Private Cloud. Your isolated network in AWS.

---

## A final word

Nearly everything in this document reduces to one habit:

> **Spend routable addresses only on things that must be *reached*. Everything that only *reaches out* goes in the cheap pile.**

Get that right, reserve most of your range on day one, and put a gateway endpoint on every route table. Those three decisions will carry a data platform for years.

*Verify current AWS pricing, service limits, and CIDR restrictions against the official documentation before finalizing any production design — these change.*
