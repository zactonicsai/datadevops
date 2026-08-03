# The AWS CLI "Describe Everything" Cheat Sheet

**A complete tutorial + reference for cloud teams.**
Written in plain language. Every command is a full, working example.

---

## Table of Contents

1. [Background: what is the AWS CLI?](#1-background)
2. [Step-by-step: your very first example](#2-step-by-step-your-first-example)
3. [The 6 knobs on every command](#3-the-6-knobs)
4. [`--query` deep dive (JMESPath)](#4-query-deep-dive)
5. [`--filters` deep dive (server-side)](#5-filters-deep-dive)
6. [`--query` vs `--filters` vs `jq` — pros and cons](#6-query-vs-filters-vs-jq)
7. [Networking: VPC, subnets, routes, NACLs, security groups, endpoints](#7-networking)
8. [Load balancing: ALB/NLB, target groups, listeners, rules](#8-load-balancing)
9. [Compute: EC2, AMIs, disks, launch templates, Auto Scaling](#9-compute)
10. [Containers: EKS, ECS, ECR](#10-containers)
11. [DNS: Route 53, hosted zones, records, Resolver rules](#11-dns)
12. [Everything else a cloud team manages](#12-everything-else)
13. [Cross-service inventory (find things everywhere)](#13-cross-service-inventory)
14. [Ready-to-run audit recipes](#14-audit-recipes)
15. [Best practices, gotchas, and a quick-reference table](#15-best-practices)

---

## 1. Background

### What is the AWS CLI?

AWS (Amazon Web Services) is a giant computer rental company. You rent servers, networks, databases, and DNS from them.

There are three ways to talk to AWS:

| Way | What it looks like | Good for |
|---|---|---|
| **Console** | A website you click | Learning, one-off looks |
| **CLI** | Typing commands in a terminal | Investigating, scripting, audits |
| **IaC** (Terraform, CloudFormation) | Writing config files | Building and *keeping* things |

The **CLI** (Command Line Interface) is a program called `aws` that you install on your laptop. When you type a command, it sends a message over the internet to AWS, and AWS sends back an answer.

### The shape of every command

Every AWS CLI command looks like this:

```
aws  <service>  <operation>  [options]
```

- **service** — which part of AWS (`ec2`, `s3`, `eks`, `route53`)
- **operation** — what to do (`describe-vpcs`, `list-clusters`)
- **options** — extra details (`--vpc-id vpc-123`, `--region us-east-1`)

Example:

```bash
aws ec2 describe-vpcs --region us-east-1
```

Read it as: *"AWS, in the EC2 service, describe the VPCs in the us-east-1 region."*

### Naming rule of thumb

AWS uses three verbs and they are not random:

| Verb | Meaning | Example |
|---|---|---|
| `list-` | Give me the **names/IDs** only | `aws eks list-clusters` |
| `describe-` | Give me the **full details** | `aws ec2 describe-vpcs` |
| `get-` | Give me **one specific thing** | `aws route53 get-hosted-zone` |

Older services (EC2, RDS) love `describe-`. Newer services (EKS, Lambda) love `list-` + `describe-` as a two-step. When a `list-` returns only IDs, you almost always follow up with a `describe-`.

### Read-only is safe

Every command in this guide that starts with `describe`, `list`, or `get` **only reads**. It cannot break anything. You can run all of them safely. (The few dangerous ones are clearly marked.)

---

## 2. Step-by-step: your first example

We are going to go from zero to "I listed my VPCs and made a clean table." Follow along exactly.

### Step 1 — Install the CLI (v2 — always use v2, v1 is retired)

**macOS:**
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

**Linux (x86_64):**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**Windows:** download and run `https://awscli.amazonaws.com/AWSCLIV2.msi`

**Check it worked:**
```bash
aws --version
```

You should see something like `aws-cli/2.x.x Python/3.x.x`. If it says `aws-cli/1.x`, upgrade — v1 is end-of-life and missing newer commands.

### Step 2 — Log in

You have two choices. **Use the first one if your company gives you an AWS access portal.**

**Option A — IAM Identity Center / SSO (best practice, modern, no long-lived keys):**

```bash
aws configure sso
```

It asks you:
```
SSO session name (Recommended): my-company
SSO start URL [None]: https://my-company.awsapps.com/start
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]: <press enter>
```
A browser opens, you approve, then it asks which account and role, and finally:
```
Default client Region [None]: us-east-1
CLI default output format [None]: json
CLI profile name [...]: prod
```

Now log in any time with:
```bash
aws sso login --profile prod
```

**Option B — Access keys (simple, but riskier):**

```bash
aws configure --profile prod
```
```
AWS Access Key ID [None]: AKIA................
AWS Secret Access Key [None]: ....................................
Default region name [None]: us-east-1
Default output format [None]: json
```

> ⚠️ Access keys are like a password written on paper. They never expire on their own. If one leaks to GitHub, attackers find it in minutes. SSO tokens expire in hours, which is why SSO is preferred.

### Step 3 — Prove who you are

```bash
aws sts get-caller-identity --profile prod
```

Output:
```json
{
    "UserId": "AROA5EXAMPLEID:alice",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/DevOps/alice"
}
```

**Read this every time before you run anything.** It tells you *which AWS account* you are pointed at. Nearly every "oh no I did that in prod" story starts with skipping this step.

### Step 4 — Stop typing `--profile` every time

```bash
export AWS_PROFILE=prod
export AWS_REGION=us-east-1
```

Now every command uses that account and region. (On Windows PowerShell: `$env:AWS_PROFILE="prod"`.)

### Step 5 — Your first describe

```bash
aws ec2 describe-vpcs
```

Output (trimmed):
```json
{
    "Vpcs": [
        {
            "CidrBlock": "10.0.0.0/16",
            "DhcpOptionsId": "dopt-0abc123",
            "State": "available",
            "VpcId": "vpc-0a1b2c3d4e5f67890",
            "OwnerId": "123456789012",
            "InstanceTenancy": "default",
            "CidrBlockAssociationSet": [
                {
                    "AssociationId": "vpc-cidr-assoc-0abc",
                    "CidrBlock": "10.0.0.0/16",
                    "CidrBlockState": { "State": "associated" }
                }
            ],
            "IsDefault": false,
            "Tags": [
                { "Key": "Name", "Value": "prod-vpc" },
                { "Key": "Environment", "Value": "production" }
            ]
        }
    ]
}
```

**How to read it:** the outer key is `Vpcs`. Inside is a **list** `[ ... ]`. Each item `{ ... }` is one VPC. `VpcId` is the unique name AWS gave it. `Tags` are sticky notes *you* added.

That nesting — `TopKey` → list → fields — is the pattern for almost every describe command in AWS.

### Step 6 — Make it readable

That JSON is a lot. Let's ask for only three fields, as a table:

```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`]|[0].Value]' \
  --output table
```

```
--------------------------------------------------------
|                      DescribeVpcs                    |
+------------------------+---------------+-------------+
|  vpc-0a1b2c3d4e5f67890 |  10.0.0.0/16  |  prod-vpc   |
|  vpc-0f9e8d7c6b5a43210 |  172.31.0.0/16|  None       |
+------------------------+---------------+-------------+
```

That's the whole game: **run a describe, then use `--query` to keep only what you care about.** Section 4 teaches `--query` properly.

### Step 7 — Narrow it down at the source

```bash
aws ec2 describe-vpcs --filters "Name=tag:Environment,Values=production"
```

This asks AWS to send back *only* production VPCs. Less data over the wire, faster answer. Section 5 covers this.

🎉 **You now know the core loop:** authenticate → describe → filter → query → format.

---

## 3. The 6 knobs

These options work on **almost every** AWS CLI command. Learn these six and you can drive the whole thing.

| Knob | What it does | Example |
|---|---|---|
| `--profile` | Which account/login to use | `--profile prod` |
| `--region` | Which AWS data center | `--region eu-west-1` |
| `--output` | How to print the answer | `--output table` |
| `--query` | Which fields to keep (**your computer** does this) | `--query 'Vpcs[*].VpcId'` |
| `--filters` | Which items AWS should send (**AWS** does this) | `--filters Name=state,Values=available` |
| `--max-items` | Stop after N results | `--max-items 10` |

Plus two quality-of-life flags:

```bash
--no-cli-pager     # don't open a "less" scroll view, just print
--debug            # show the raw API calls (for troubleshooting)
```

Set the pager off permanently, it's the #1 annoyance for new users:
```bash
aws configure set cli_pager ""
```

### Output formats — which to pick

| Format | Looks like | Use it when | Downside |
|---|---|---|---|
| `json` (default) | `{"VpcId": "vpc-123"}` | Feeding to `jq` or scripts | Verbose to read |
| `table` | ASCII grid | Showing a human | Ugly if many columns |
| `text` | Tab-separated | Bash loops, `awk`, `cut` | Empty fields silently vanish |
| `yaml` | Indented text | Reading long nested configs | Not great for scripts |

```bash
aws ec2 describe-vpcs --output table   # for your eyes
aws ec2 describe-vpcs --output json    # for jq
aws ec2 describe-vpcs --output text    # for bash loops
aws ec2 describe-vpcs --output yaml    # for reading deep configs
```

**`--output text` gotcha:** if a field is `null`, it prints `None`, and if you select a list of lists the columns can shift. Always pair `text` with a `--query` that returns a fixed, flat set of fields.

### Pagination — the hidden trap

AWS returns big result sets in pages (often 100 or 1000 at a time). **The CLI v2 automatically follows all pages for you** — good, but it means one command can quietly make 40 API calls in a huge account.

```bash
# Only the first 5 results (stops early — fast)
aws ec2 describe-instances --max-items 5

# Ask for smaller pages (gentler on API rate limits)
aws ec2 describe-images --owners self --page-size 20

# Turn OFF auto-paging: return one page + a NextToken you handle yourself
aws ec2 describe-instances --no-paginate
```

When you use `--max-items`, the CLI may add a `NextToken` to the end of the output so you can resume:
```bash
aws ec2 describe-instances --max-items 5 --starting-token <token-from-last-run>
```

---

## 4. `--query` deep dive

### What it is

`--query` uses a mini-language called **JMESPath** (say "James path"). Think of it as a path through the JSON, like a folder path through files.

**Important:** `--query` runs **on your computer, after** AWS already sent you everything. It makes output *readable*, not *faster*.

### The building blocks

Start with this sample answer:

```json
{
  "Vpcs": [
    { "VpcId": "vpc-aaa", "CidrBlock": "10.0.0.0/16", "IsDefault": false,
      "Tags": [{"Key":"Name","Value":"prod"},{"Key":"Team","Value":"web"}] },
    { "VpcId": "vpc-bbb", "CidrBlock": "172.31.0.0/16", "IsDefault": true,
      "Tags": [] }
  ]
}
```

**1. Go into a key — use a dot**
```bash
--query 'Vpcs'
```
Returns the whole list.

**2. Every item in a list — use `[*]` or `[]`**
```bash
--query 'Vpcs[*].VpcId'
```
```json
["vpc-aaa", "vpc-bbb"]
```

**3. One item by position — use a number**
```bash
--query 'Vpcs[0].VpcId'     # first one
--query 'Vpcs[-1].VpcId'    # last one
```

**4. A slice — `[start:stop]`**
```bash
--query 'Vpcs[0:2]'    # first two
--query 'Vpcs[:5]'     # first five
--query 'Vpcs[::-1]'   # reversed
```

**5. Several fields, no labels — square brackets (multiselect list)**
```bash
--query 'Vpcs[*].[VpcId,CidrBlock,IsDefault]'
```
```json
[["vpc-aaa","10.0.0.0/16",false],["vpc-bbb","172.31.0.0/16",true]]
```
👉 This is the one to use with `--output table` and `--output text`.

**6. Several fields, WITH labels — curly braces (multiselect hash)**
```bash
--query 'Vpcs[*].{Id:VpcId,Cidr:CidrBlock,Default:IsDefault}'
```
```json
[{"Id":"vpc-aaa","Cidr":"10.0.0.0/16","Default":false}, ...]
```
👉 This is the one to use with `--output json` and for `--output table` **with column headers**.

```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[*].{Id:VpcId,Cidr:CidrBlock,Default:IsDefault}' \
  --output table
```
```
-----------------------------------------------
|                 DescribeVpcs                |
+---------+----------------+------------------+
|  Cidr   |    Default     |       Id         |
+---------+----------------+------------------+
| 10.0.0.0/16 |  False     |  vpc-aaa         |
| 172.31.0.0/16 |  True    |  vpc-bbb         |
+---------+----------------+------------------+
```
(Note: table columns are alphabetical by label. Name your labels `1Id`, `2Cidr` if you need a specific order.)

**7. Filter the list — `[?condition]`**

```bash
--query 'Vpcs[?IsDefault==`false`].VpcId'
```

Rules for the condition:
- **Backticks** around JSON literals: `` `true` ``, `` `false` ``, `` `100` ``, `` `null` ``
- **Single quotes** around strings: `'production'`
- Operators: `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&` (and), `||` (or), `!` (not)

```bash
# String comparison
--query "Reservations[].Instances[?State.Name=='running']"

# Number comparison
--query 'Volumes[?Size>`100`]'

# Two conditions
--query "Reservations[].Instances[?State.Name=='running' && InstanceType=='t3.micro']"
```

**8. The Tag trick — the single most useful pattern in AWS**

AWS stores tags as a list of `{Key, Value}` pairs, which is annoying. To pull out the `Name` tag:

```
Tags[?Key=='Name']|[0].Value
```

Read it as: *filter tags down to the one whose Key is Name → pipe → take item 0 → give me its Value.*

Full example:
```bash
aws ec2 describe-vpcs \
  --query "Vpcs[*].{Name:Tags[?Key=='Name']|[0].Value, Id:VpcId, Cidr:CidrBlock}" \
  --output table
```

The `|[0]` is required. Without it you get a list back instead of a single string.

**9. The pipe `|` — start a fresh query on the result**

```bash
--query 'Vpcs[*].VpcId | [0]'          # first VpcId
--query 'Vpcs | length(@)'             # how many VPCs? -> 3
--query 'Vpcs[?IsDefault==`false`] | length(@)'
```

`@` means "the thing I have right now."

**10. Built-in functions**

| Function | Does | Example |
|---|---|---|
| `length(@)` | Count items | `Vpcs \| length(@)` |
| `sort_by(list, &Field)` | Sort | `sort_by(Volumes, &Size)` |
| `contains(str, 'x')` | Does it contain? | `?contains(InstanceType, 'micro')` |
| `starts_with(str,'x')` | Prefix match | `?starts_with(Name, 'prod-')` |
| `ends_with(str,'x')` | Suffix match | `?ends_with(ImageName,'-arm64')` |
| `join(',', list)` | Glue into string | `join(',', Vpcs[*].VpcId)` |
| `keys(obj)` / `values(obj)` | Object keys/values | `keys(Tags[0])` |
| `max_by` / `min_by` | Biggest/smallest | `max_by(Images, &CreationDate)` |
| `to_number(str)` | Text → number | `to_number(Size)` |
| `not_null(a, b)` | First non-null | `not_null(Name, 'unnamed')` |

Real examples:

```bash
# 5 biggest EBS volumes, newest sort
aws ec2 describe-volumes \
  --query 'sort_by(Volumes, &Size)[::-1][:5].[VolumeId,Size,State]' \
  --output table

# The single newest AMI I own
aws ec2 describe-images --owners self \
  --query 'sort_by(Images, &CreationDate)[-1].[ImageId,Name,CreationDate]' \
  --output text

# Instance types containing "large"
aws ec2 describe-instances \
  --query "Reservations[].Instances[?contains(InstanceType,'large')].[InstanceId,InstanceType]" \
  --output text

# Count of running instances
aws ec2 describe-instances \
  --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[] | length(@)'
```

**11. Flattening nested lists — `[]` vs `[*]`**

This trips everyone up. `describe-instances` nests instances inside reservations:

```json
{"Reservations":[{"Instances":[{...},{...}]},{"Instances":[{...}]}]}
```

```bash
# WRONG-ish: gives a list of lists
--query 'Reservations[*].Instances[*].InstanceId'
# [["i-1","i-2"],["i-3"]]

# RIGHT: [] flattens it into one clean list
--query 'Reservations[].Instances[].InstanceId'
# ["i-1","i-2","i-3"]
```

**Rule: use `[]` (empty brackets) when you need to flatten nested lists. Use `[*]` on a top-level list.** When in doubt, use `[]`.

### The all-purpose EC2 query (memorize this one)

```bash
aws ec2 describe-instances \
  --query "Reservations[].Instances[].{
      Name:Tags[?Key=='Name']|[0].Value,
      ID:InstanceId,
      Type:InstanceType,
      State:State.Name,
      AZ:Placement.AvailabilityZone,
      PrivateIP:PrivateIpAddress,
      PublicIP:PublicIpAddress,
      Subnet:SubnetId,
      Launched:LaunchTime
  }" \
  --output table
```

### Quoting rules (the #1 source of errors)

| Shell | Wrap the query in | Inside, for strings use | Inside, for literals use |
|---|---|---|---|
| bash / zsh (Mac, Linux) | `'single quotes'` | `"double"` or escape | `` `backticks` `` |
| PowerShell | `'single quotes'` | `''doubled singles''` | `` `backticks` `` |
| Windows cmd.exe | `"double quotes"` | `\"escaped\"` | `` `backticks` `` |

Safest cross-platform habit on bash: wrap in **double quotes** when the query contains backticks, and **single quotes** when it contains `'strings'`. Don't mix the same quote inside and outside.

```bash
# ✅ outer double, inner single
--query "Vpcs[?Tags[?Key=='Name']]"

# ✅ outer single, inner backtick
--query 'Vpcs[?IsDefault==`true`]'
```

---

## 5. `--filters` deep dive

### What it is

`--filters` is a **server-side** filter. AWS applies it *before* sending you anything. Less data crosses the network, and the answer comes back faster.

### The syntax

```
--filters "Name=<filter-name>,Values=<value1>,<value2>"
```

Multiple filters = **AND** (all must match).
Multiple values inside one filter = **OR** (any may match).

```bash
# Running AND t3.micro
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
            "Name=instance-type,Values=t3.micro"

# Running OR stopped
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,stopped"
```

Equivalent JSON form (useful in scripts, and required when values contain commas):
```bash
aws ec2 describe-instances --filters '[
  {"Name":"instance-state-name","Values":["running"]},
  {"Name":"tag:Environment","Values":["prod"]}
]'
```

### Filtering by tag — three flavors

```bash
# 1. Specific tag key = specific value
--filters "Name=tag:Environment,Values=production"

# 2. Resource HAS this tag key, any value
--filters "Name=tag-key,Values=Owner"

# 3. ANY tag has this value
--filters "Name=tag-value,Values=team-payments"
```

### Wildcards

Server-side filters support `*` (any characters) and `?` (one character):

```bash
# Anything whose Name tag starts with prod-
aws ec2 describe-instances --filters "Name=tag:Name,Values=prod-*"

# All large-ish instance types
aws ec2 describe-instances --filters "Name=instance-type,Values=*.large,*.xlarge"

# AMIs matching a naming pattern
aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64"
```

⚠️ **Filters are case-sensitive.** `Values=Production` will not match a tag value of `production`. If case might vary, filter client-side with `--query` instead.

### Finding out which filter names exist

There is no universal list — each command has its own. Ask the CLI:

```bash
aws ec2 describe-instances help
# then search for "--filters" in the help text (press / to search, q to quit)
```

Or check the docs page for that command. The most-used EC2 filter names:

| Resource | Handy filter names |
|---|---|
| Instances | `instance-state-name`, `instance-type`, `vpc-id`, `subnet-id`, `availability-zone`, `image-id`, `private-ip-address`, `instance.group-id` |
| Subnets | `vpc-id`, `availability-zone`, `cidr-block`, `default-for-az`, `state` |
| Security groups | `group-name`, `group-id`, `vpc-id`, `ip-permission.from-port`, `ip-permission.cidr`, `ip-permission.protocol` |
| Route tables | `vpc-id`, `association.subnet-id`, `route.destination-cidr-block`, `route.nat-gateway-id` |
| NACLs | `vpc-id`, `association.subnet-id`, `default`, `entry.cidr` |
| Volumes | `status`, `size`, `attachment.instance-id`, `volume-type`, `encrypted` |
| Snapshots | `status`, `volume-id`, `owner-id`, `start-time` |
| Images | `name`, `architecture`, `root-device-type`, `state`, `is-public` |
| ENIs | `vpc-id`, `subnet-id`, `status`, `attachment.instance-id`, `group-id` |
| VPC endpoints | `vpc-id`, `service-name`, `vpc-endpoint-type`, `vpc-endpoint-state` |

### The `--filter` (singular) exception

A handful of commands use singular `--filter` and will error on `--filters`:

```bash
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=vpc-123"
aws ec2 describe-transit-gateway-attachments --filters "Name=transit-gateway-id,Values=tgw-123"
```

If one form errors, try the other — that's the whole trick.

### Other services use `--filters` differently

Not every service uses the `Name=,Values=` shape:

```bash
# RDS: same shape
aws rds describe-db-instances --filters "Name=engine,Values=postgres"

# ELBv2: NO filters at all — use --query
aws elbv2 describe-load-balancers --query "LoadBalancers[?Type=='application']"

# EKS: NO filters — list then loop
aws eks list-clusters

# S3 / Lambda / Route53: no filters — use --query
aws lambda list-functions --query "Functions[?Runtime=='python3.12'].FunctionName"

# Resource Groups Tagging API: uses --tag-filters
aws resourcegroupstaggingapi get-resources --tag-filters Key=Environment,Values=prod
```

**Rule of thumb: EC2 and RDS have rich server-side filters. Most newer services do not — for those, `--query` is your only option.**

---

## 6. `--query` vs `--filters` vs `jq`

| | `--filters` | `--query` | `jq` |
|---|---|---|---|
| **Runs where** | AWS's servers | Your machine | Your machine |
| **Reduces network traffic** | ✅ Yes | ❌ No | ❌ No |
| **Reduces API calls / pages** | ✅ Yes | ❌ No | ❌ No |
| **Available everywhere** | ❌ EC2/RDS mostly | ✅ Every command | ✅ Any JSON |
| **Case-insensitive matching** | ❌ No | ⚠️ Limited | ✅ Yes |
| **Regex** | ❌ No (globs only) | ❌ No | ✅ Yes |
| **Math / grouping** | ❌ No | ⚠️ Basic | ✅ Yes |
| **Extra install needed** | No | No | Yes |

**The professional pattern — use both together:**

```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType]" \
  --output text
```

*Filter narrows what comes back. Query shapes what you see.*

**When to reach for `jq` instead:**

```bash
# Case-insensitive search — jq can, JMESPath can't
aws ec2 describe-instances | jq '.Reservations[].Instances[]
  | select((.Tags[]?|select(.Key=="Name").Value|ascii_downcase) | test("prod"))'

# Sum up numbers — jq can, JMESPath can't
aws ec2 describe-volumes | jq '[.Volumes[].Size] | add'

# Turn output into CSV
aws ec2 describe-instances \
  | jq -r '.Reservations[].Instances[] | [.InstanceId, .InstanceType, .State.Name] | @csv'
```

**Pros/cons summary:**
- **`--filters` pro:** the only thing that actually makes commands *fast* in big accounts. **Con:** limited support, case-sensitive, filter names are hard to discover.
- **`--query` pro:** works on 100% of commands, no dependencies, great with `--output table`. **Con:** weird quoting, no math, no regex, doesn't save any time or money.
- **`jq` pro:** full programming power. **Con:** must be installed, another syntax to learn, and it still downloads everything first.

---

## 7. Networking

### Mental model first

A **VPC** is your own private neighborhood inside AWS.
- **Subnets** are streets in that neighborhood. Each lives in one Availability Zone (a building).
- **Route tables** are the road signs telling traffic where to go.
- An **Internet Gateway** is the front door to the internet. A **NAT Gateway** is a one-way door (inside can call out; outside can't call in).
- **NACLs** are guards at the street entrance — they check every car in *and* out, and they forget who they let in (stateless).
- **Security Groups** are guards at each house door — they remember who they let in, so replies get out automatically (stateful).
- **VPC Endpoints** are private tunnels to AWS services so traffic never touches the internet.

| | Security Group | NACL |
|---|---|---|
| Attaches to | Instance / ENI | Subnet |
| Stateful? | ✅ Yes (replies auto-allowed) | ❌ No (need both in + out rules) |
| Rules | Allow only | Allow **and** Deny |
| Evaluation | All rules together | In number order, first match wins |
| Default | Deny all in, allow all out | Default NACL allows everything |

### 7.1 VPCs

```bash
# All VPCs
aws ec2 describe-vpcs

# Clean table with names
aws ec2 describe-vpcs \
  --query "Vpcs[].{Name:Tags[?Key=='Name']|[0].Value,ID:VpcId,CIDR:CidrBlock,Default:IsDefault,State:State}" \
  --output table

# One specific VPC
aws ec2 describe-vpcs --vpc-ids vpc-0a1b2c3d4e5f67890

# Only non-default VPCs
aws ec2 describe-vpcs --filters "Name=isDefault,Values=false"

# By tag
aws ec2 describe-vpcs --filters "Name=tag:Environment,Values=production"

# All CIDR blocks attached to each VPC (VPCs can have several)
aws ec2 describe-vpcs \
  --query 'Vpcs[].{ID:VpcId,CIDRs:CidrBlockAssociationSet[].CidrBlock}' \
  --output json

# DHCP options (what DNS servers your instances get)
aws ec2 describe-dhcp-options

# DNS settings for a VPC (needed for private hosted zones / endpoints)
aws ec2 describe-vpc-attribute --vpc-id vpc-123 --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --vpc-id vpc-123 --attribute enableDnsHostnames
```

### 7.2 Subnets

```bash
# All subnets in one VPC, sorted, with free IP count
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-0a1b2c3d4e5f67890" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value,ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,FreeIPs:AvailableIpAddressCount,AutoPublicIP:MapPublicIpOnLaunch}" \
  --output table

# Public subnets (auto-assign public IP is on) — a decent first guess
aws ec2 describe-subnets \
  --filters "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone]' --output text

# Subnets running low on IPs (under 20 free) — a very common outage cause
aws ec2 describe-subnets \
  --query 'Subnets[?AvailableIpAddressCount<`20`].[SubnetId,CidrBlock,AvailableIpAddressCount]' \
  --output table

# Subnets in one AZ
aws ec2 describe-subnets --filters "Name=availability-zone,Values=us-east-1a"

# Which AZs exist in this region at all
aws ec2 describe-availability-zones \
  --query 'AvailabilityZones[].[ZoneName,ZoneId,State]' --output table
```

### 7.3 Route tables and routes

```bash
# All route tables in a VPC
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=vpc-123"

# Just the routes, flattened and readable
aws ec2 describe-route-tables \
  --query 'RouteTables[].{RT:RouteTableId,Routes:Routes[].{Dest:DestinationCidrBlock,GW:GatewayId,NAT:NatGatewayId,ENI:NetworkInterfaceId,Peer:VpcPeeringConnectionId,TGW:TransitGatewayId,State:State}}' \
  --output json

# Which route tables send 0.0.0.0/0 to an Internet Gateway = TRULY public subnets
aws ec2 describe-route-tables \
  --query "RouteTables[?Routes[?DestinationCidrBlock=='0.0.0.0/0' && starts_with(GatewayId,'igw-')]].{RT:RouteTableId,Subnets:Associations[].SubnetId}" \
  --output json

# Which subnets use which route table
aws ec2 describe-route-tables \
  --query 'RouteTables[].{RT:RouteTableId,Main:Associations[0].Main,Subnets:Associations[].SubnetId}' \
  --output json

# Find the route table for one specific subnet
aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=subnet-abc123"

# Any blackhole routes? (broken routes pointing at deleted things)
aws ec2 describe-route-tables \
  --query "RouteTables[].Routes[?State=='blackhole']" --output json
```

### 7.4 Internet gateways, NAT gateways, Elastic IPs

```bash
# Internet gateways and what they're attached to
aws ec2 describe-internet-gateways \
  --query 'InternetGateways[].{IGW:InternetGatewayId,VPC:Attachments[0].VpcId,State:Attachments[0].State}' \
  --output table

# IPv6-only outbound gateway
aws ec2 describe-egress-only-internet-gateways

# NAT gateways — NOTE: singular --filter here!
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=vpc-123" \
  --query 'NatGateways[].{ID:NatGatewayId,Subnet:SubnetId,State:State,Type:ConnectivityType,PublicIP:NatGatewayAddresses[0].PublicIp}' \
  --output table

# Elastic IPs — and which are wasted (unattached = you're paying for nothing)
aws ec2 describe-addresses \
  --query 'Addresses[].{IP:PublicIp,AllocID:AllocationId,Instance:InstanceId,ENI:NetworkInterfaceId}' \
  --output table

aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].PublicIp' --output text
```

### 7.5 Security groups

```bash
# All SGs in a VPC, summarized
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=vpc-123" \
  --query 'SecurityGroups[].{Name:GroupName,ID:GroupId,Desc:Description,InRules:length(IpPermissions),OutRules:length(IpPermissionsEgress)}' \
  --output table

# One SG in full detail
aws ec2 describe-security-groups --group-ids sg-0123456789abcdef0

# By name
aws ec2 describe-security-groups --filters "Name=group-name,Values=web-sg"

# 🚨 THE BIG AUDIT: which SGs allow the whole internet in?
aws ec2 describe-security-groups \
  --filters "Name=ip-permission.cidr,Values=0.0.0.0/0" \
  --query 'SecurityGroups[].{Name:GroupName,ID:GroupId,VPC:VpcId}' \
  --output table

# 🚨 SSH (22) open to the world
aws ec2 describe-security-groups \
  --filters "Name=ip-permission.from-port,Values=22" "Name=ip-permission.cidr,Values=0.0.0.0/0" \
  --query 'SecurityGroups[].[GroupId,GroupName,VpcId]' --output text

# 🚨 RDP (3389) open to the world
aws ec2 describe-security-groups \
  --filters "Name=ip-permission.from-port,Values=3389" "Name=ip-permission.cidr,Values=0.0.0.0/0" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text

# Flatten inbound rules into a readable list
aws ec2 describe-security-groups --group-ids sg-123 \
  --query 'SecurityGroups[].IpPermissions[].{Proto:IpProtocol,From:FromPort,To:ToPort,CIDRs:IpRanges[].CidrIp,SrcSGs:UserIdGroupPairs[].GroupId}' \
  --output json

# Which SGs are unused (attached to nothing)? Compare these two lists:
aws ec2 describe-security-groups --query 'SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort > /tmp/all-sgs
aws ec2 describe-network-interfaces --query 'NetworkInterfaces[].Groups[].GroupId' --output text | tr '\t' '\n' | sort -u > /tmp/used-sgs
comm -23 /tmp/all-sgs /tmp/used-sgs
```

### 7.6 Security group rules (individual rule objects)

Newer API — every rule has its own ID, which is much nicer for auditing:

```bash
# Every rule in one SG, with rule IDs
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=sg-0123456789abcdef0" \
  --query 'SecurityGroupRules[].{RuleID:SecurityGroupRuleId,Egress:IsEgress,Proto:IpProtocol,From:FromPort,To:ToPort,CIDR:CidrIpv4,SrcSG:ReferencedGroupInfo.GroupId,Desc:Description}' \
  --output table

# Only inbound rules
aws ec2 describe-security-group-rules \
  --filters "Name=group-id,Values=sg-123" \
  --query 'SecurityGroupRules[?IsEgress==`false`]' --output json

# Every rule across the account that references 0.0.0.0/0
aws ec2 describe-security-group-rules \
  --query "SecurityGroupRules[?CidrIpv4=='0.0.0.0/0'].[GroupId,SecurityGroupRuleId,IpProtocol,FromPort,ToPort,IsEgress]" \
  --output table
```

### 7.7 NACLs (Network ACLs)

```bash
# All NACLs in a VPC
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=vpc-123"

# Inbound rules, sorted by rule number (order matters — first match wins!)
aws ec2 describe-network-acls --network-acl-ids acl-0123456789abcdef0 \
  --query 'NetworkAcls[].Entries[?Egress==`false`] | [] | sort_by(@, &RuleNumber)[].{Rule:RuleNumber,Action:RuleAction,Proto:Protocol,CIDR:CidrBlock,Ports:PortRange}' \
  --output table

# Outbound rules
aws ec2 describe-network-acls --network-acl-ids acl-123 \
  --query 'NetworkAcls[].Entries[?Egress==`true`] | [] | sort_by(@, &RuleNumber)[].{Rule:RuleNumber,Action:RuleAction,Proto:Protocol,CIDR:CidrBlock,Ports:PortRange}' \
  --output table

# Which subnets each NACL protects
aws ec2 describe-network-acls \
  --query 'NetworkAcls[].{ACL:NetworkAclId,Default:IsDefault,Subnets:Associations[].SubnetId}' \
  --output json

# Find the NACL guarding one subnet
aws ec2 describe-network-acls --filters "Name=association.subnet-id,Values=subnet-abc"

# Any DENY rules? (these are the usual cause of "why is it blocked?")
aws ec2 describe-network-acls \
  --query "NetworkAcls[].{ACL:NetworkAclId,Denies:Entries[?RuleAction=='deny']}" --output json
```

> 💡 **Protocol numbers:** `-1` = all, `6` = TCP, `17` = UDP, `1` = ICMP.

### 7.8 VPC endpoints (private tunnels to AWS services)

```bash
# All endpoints
aws ec2 describe-vpc-endpoints \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType,VPC:VpcId,State:State,DNS:PrivateDnsEnabled}' \
  --output table

# Endpoints in one VPC
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=vpc-123"

# Gateway endpoints only (S3 & DynamoDB — these attach to route tables, and are free)
aws ec2 describe-vpc-endpoints --filters "Name=vpc-endpoint-type,Values=Gateway" \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,Service:ServiceName,RouteTables:RouteTableIds}' --output json

# Interface endpoints (an ENI in your subnet — these cost money per hour)
aws ec2 describe-vpc-endpoints --filters "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].{ID:VpcEndpointId,Service:ServiceName,Subnets:SubnetIds,SGs:Groups[].GroupId}' --output json

# The endpoint POLICY (the rules on the endpoint — "endpoint rules")
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids vpce-0123456789abcdef0 \
  --query 'VpcEndpoints[0].PolicyDocument' --output text | python3 -m json.tool

# What services CAN I make an endpoint for in this region?
aws ec2 describe-vpc-endpoint-services --query 'ServiceNames' --output text | tr '\t' '\n' | sort

# Details of one service (which AZs support it)
aws ec2 describe-vpc-endpoint-services \
  --filters "Name=service-name,Values=com.amazonaws.us-east-1.s3" \
  --query 'ServiceDetails[].{Service:ServiceName,Type:ServiceType[].ServiceType,AZs:AvailabilityZones,PrivateDNS:PrivateDnsName}'

# If YOU publish a PrivateLink service to others
aws ec2 describe-vpc-endpoint-service-configurations
aws ec2 describe-vpc-endpoint-service-permissions --service-id vpce-svc-0123456789abcdef0
aws ec2 describe-vpc-endpoint-connections   # who is connecting to my service
```

### 7.9 Peering, Transit Gateway, VPN, Direct Connect

```bash
# VPC peering
aws ec2 describe-vpc-peering-connections \
  --query 'VpcPeeringConnections[].{ID:VpcPeeringConnectionId,Status:Status.Code,Requester:RequesterVpcInfo.VpcId,RequesterCIDR:RequesterVpcInfo.CidrBlock,Accepter:AccepterVpcInfo.VpcId,AccepterCIDR:AccepterVpcInfo.CidrBlock}' \
  --output table

# Transit Gateways
aws ec2 describe-transit-gateways \
  --query 'TransitGateways[].{ID:TransitGatewayId,State:State,ASN:Options.AmazonSideAsn,Owner:OwnerId}' --output table

aws ec2 describe-transit-gateway-attachments \
  --query 'TransitGatewayAttachments[].{Attach:TransitGatewayAttachmentId,TGW:TransitGatewayId,Type:ResourceType,Resource:ResourceId,State:State}' \
  --output table

aws ec2 describe-transit-gateway-route-tables
aws ec2 get-transit-gateway-route-table-associations --transit-gateway-route-table-id tgw-rtb-123
aws ec2 get-transit-gateway-route-table-propagations --transit-gateway-route-table-id tgw-rtb-123

# TGW routes (a filter is REQUIRED here)
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id tgw-rtb-0123456789abcdef0 \
  --filters "Name=state,Values=active" \
  --query 'Routes[].{CIDR:DestinationCidrBlock,Type:Type,State:State,Attach:TransitGatewayAttachments[0].ResourceId}' \
  --output table

# Site-to-site VPN
aws ec2 describe-vpn-connections \
  --query 'VpnConnections[].{ID:VpnConnectionId,State:State,TGW:TransitGatewayId,VGW:VpnGatewayId,Tunnels:VgwTelemetry[].{IP:OutsideIpAddress,Status:Status}}' --output json
aws ec2 describe-vpn-gateways
aws ec2 describe-customer-gateways

# Direct Connect
aws directconnect describe-connections
aws directconnect describe-virtual-interfaces
aws directconnect describe-direct-connect-gateways
```

### 7.10 ENIs, prefix lists, flow logs

```bash
# Network interfaces (every IP in your VPC belongs to one of these)
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=vpc-123" \
  --query 'NetworkInterfaces[].{ENI:NetworkInterfaceId,Type:InterfaceType,IP:PrivateIpAddress,Subnet:SubnetId,Status:Status,AttachedTo:Attachment.InstanceId,Desc:Description}' \
  --output table

# Orphaned ENIs (available = attached to nothing; often left by deleted Lambdas)
aws ec2 describe-network-interfaces --filters "Name=status,Values=available" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,SubnetId,Description]' --output table

# Managed prefix lists (named groups of CIDRs you can use in SG rules)
aws ec2 describe-managed-prefix-lists \
  --query 'PrefixLists[].{ID:PrefixListId,Name:PrefixListName,Owner:OwnerId,MaxEntries:MaxEntries}' --output table
aws ec2 get-managed-prefix-list-entries --prefix-list-id pl-0123456789abcdef0
# AWS-managed ones (e.g. the S3 and CloudFront IP ranges):
aws ec2 describe-managed-prefix-lists --filters "Name=owner-id,Values=AWS"

# VPC Flow Logs (network traffic recording)
aws ec2 describe-flow-logs \
  --query 'FlowLogs[].{ID:FlowLogId,Resource:ResourceId,Dest:LogDestination,Group:LogGroupName,Traffic:TrafficType,Status:FlowLogStatus}' \
  --output table

# Which VPCs have NO flow logs? (compliance finding)
aws ec2 describe-vpcs --query 'Vpcs[].VpcId' --output text | tr '\t' '\n' | sort > /tmp/vpcs
aws ec2 describe-flow-logs --query 'FlowLogs[].ResourceId' --output text | tr '\t' '\n' | sort -u > /tmp/fl
comm -23 /tmp/vpcs /tmp/fl

# Reachability Analyzer — "why can't A talk to B?" answered by AWS
aws ec2 describe-network-insights-paths
aws ec2 describe-network-insights-analyses
```

---

## 8. Load balancing

### Mental model

A **load balancer** is a receptionist. Traffic arrives at the receptionist, who forwards it to whichever worker is free.

- **Load Balancer** — the front door with a DNS name.
- **Listener** — "I'm listening on port 443 for HTTPS."
- **Rule** — "if the path is `/api/*`, send it to the api group."
- **Target Group** — the list of workers (instances, IPs, or Lambdas).
- **Target Health** — is each worker answering the health check?

`elbv2` = ALB, NLB, GWLB (modern). `elb` = Classic (old, avoid).

### 8.1 Load balancers

```bash
# All ALBs/NLBs
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[].{Name:LoadBalancerName,Type:Type,Scheme:Scheme,DNS:DNSName,State:State.Code,VPC:VpcId,AZs:AvailabilityZones[].ZoneName}' \
  --output table

# One by name
aws elbv2 describe-load-balancers --names my-prod-alb

# Only internet-facing ones (a security review starting point)
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?Scheme=='internet-facing'].[LoadBalancerName,DNSName,Type]" --output table

# Only ALBs
aws elbv2 describe-load-balancers --query "LoadBalancers[?Type=='application']"

# Settings (idle timeout, deletion protection, access logs, HTTP/2)
aws elbv2 describe-load-balancer-attributes --load-balancer-arn <lb-arn> \
  --query 'Attributes[].[Key,Value]' --output table

# Classic ELBs (legacy — check if any still exist)
aws elb describe-load-balancers \
  --query 'LoadBalancerDescriptions[].{Name:LoadBalancerName,DNS:DNSName,Instances:Instances[].InstanceId}' --output json
```

### 8.2 Target groups and health

```bash
# All target groups
aws elbv2 describe-target-groups \
  --query 'TargetGroups[].{Name:TargetGroupName,Proto:Protocol,Port:Port,Type:TargetType,VPC:VpcId,HealthPath:HealthCheckPath,LB:LoadBalancerArns[0]}' \
  --output table

# Target groups belonging to one load balancer
aws elbv2 describe-target-groups --load-balancer-arn <lb-arn>

# 🚨 THE MOST USED COMMAND IN AN OUTAGE: are the targets healthy?
aws elbv2 describe-target-health --target-group-arn <tg-arn> \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,AZ:Target.AvailabilityZone,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
  --output table

# Only the UNhealthy ones
aws elbv2 describe-target-health --target-group-arn <tg-arn> \
  --query "TargetHealthDescriptions[?TargetHealth.State!='healthy'].[Target.Id,TargetHealth.State,TargetHealth.Description]" \
  --output table

# Loop: health of EVERY target group in the account
for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
  name=$(aws elbv2 describe-target-groups --target-group-arns "$tg" --query 'TargetGroups[0].TargetGroupName' --output text)
  echo "== $name"
  aws elbv2 describe-target-health --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text
done

# Target group settings (deregistration delay, stickiness, slow start)
aws elbv2 describe-target-group-attributes --target-group-arn <tg-arn> \
  --query 'Attributes[].[Key,Value]' --output table

# Target groups attached to NOTHING (safe to delete = save money)
aws elbv2 describe-target-groups \
  --query 'TargetGroups[?length(LoadBalancerArns)==`0`].TargetGroupName' --output text
```

### 8.3 Listeners, rules, and certificates

```bash
# Listeners on a load balancer
aws elbv2 describe-listeners --load-balancer-arn <lb-arn> \
  --query 'Listeners[].{ARN:ListenerArn,Port:Port,Proto:Protocol,SSLPolicy:SslPolicy,DefaultAction:DefaultActions[0].Type,DefaultTG:DefaultActions[0].TargetGroupArn}' \
  --output table

# Routing RULES on a listener — path/host based routing
aws elbv2 describe-rules --listener-arn <listener-arn> \
  --query 'Rules[].{Priority:Priority,Default:IsDefault,Conditions:Conditions[].{Field:Field,Values:Values},Action:Actions[0].Type,Target:Actions[0].TargetGroupArn}' \
  --output json

# Human-readable rule dump
aws elbv2 describe-rules --listener-arn <listener-arn> \
  --query 'Rules[].[Priority,Conditions[0].Field,join(`,`,Conditions[0].Values || [`-`]),Actions[0].Type]' \
  --output table

# HTTPS certificates on a listener
aws elbv2 describe-listener-certificates --listener-arn <listener-arn>

# Available SSL security policies
aws elbv2 describe-ssl-policies --query 'SslPolicies[].Name' --output text

# 🚨 Any listener still on plain HTTP?
for lb in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text); do
  aws elbv2 describe-listeners --load-balancer-arn "$lb" \
    --query "Listeners[?Protocol=='HTTP'].[LoadBalancerArn,Port]" --output text
done
```

---

## 9. Compute

### 9.1 EC2 instances

```bash
# THE workhorse command
aws ec2 describe-instances \
  --query "Reservations[].Instances[].{Name:Tags[?Key=='Name']|[0].Value,ID:InstanceId,Type:InstanceType,State:State.Name,AZ:Placement.AvailabilityZone,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,Subnet:SubnetId,AMI:ImageId,Key:KeyName,Launched:LaunchTime}" \
  --output table

# Running only (server-side filter = fast)
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running"

# Stopped instances (still paying for their disks!)
aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' --output table

# In one VPC / one subnet
aws ec2 describe-instances --filters "Name=vpc-id,Values=vpc-123"
aws ec2 describe-instances --filters "Name=subnet-id,Values=subnet-abc"

# By tag, with wildcard
aws ec2 describe-instances --filters "Name=tag:Name,Values=prod-web-*"

# By security group
aws ec2 describe-instances --filters "Name=instance.group-id,Values=sg-123" \
  --query 'Reservations[].Instances[].InstanceId' --output text

# Specific instances
aws ec2 describe-instances --instance-ids i-0abc123 i-0def456

# Find an instance by its IP
aws ec2 describe-instances --filters "Name=private-ip-address,Values=10.0.1.55"
aws ec2 describe-instances --filters "Name=ip-address,Values=54.1.2.3"

# Count instances by type
aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceType' --output text \
  | tr '\t' '\n' | sort | uniq -c | sort -rn

# Health / status checks (is the box actually OK?)
aws ec2 describe-instance-status --include-all-instances \
  --query 'InstanceStatuses[].{ID:InstanceId,State:InstanceState.Name,System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table

# Only failing status checks
aws ec2 describe-instance-status \
  --filters "Name=instance-status.status,Values=impaired" --output json

# What instance types exist, and their specs
aws ec2 describe-instance-types --instance-types t3.micro m5.large \
  --query 'InstanceTypes[].{Type:InstanceType,vCPU:VCpuInfo.DefaultVCpus,MemGiB:MemoryInfo.SizeInMiB,Net:NetworkInfo.NetworkPerformance,ENIs:NetworkInfo.MaximumNetworkInterfaces}' \
  --output table

# Which types are available in a given AZ (before you plan a deployment)
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=location,Values=us-east-1a" \
  --query 'InstanceTypeOfferings[].InstanceType' --output text | tr '\t' '\n' | sort

# Graviton (ARM) types only
aws ec2 describe-instance-types \
  --filters "Name=processor-info.supported-architecture,Values=arm64" \
  --query 'InstanceTypes[].InstanceType' --output text

# User data (the startup script) of an instance — often holds the answer
aws ec2 describe-instance-attribute --instance-id i-0abc --attribute userData \
  --query 'UserData.Value' --output text | base64 -d

# Console output / screenshot (for boot failures)
aws ec2 get-console-output --instance-id i-0abc --output text
aws ec2 get-console-screenshot --instance-id i-0abc --query ImageData --output text | base64 -d > screen.jpg

# Key pairs and placement groups
aws ec2 describe-key-pairs --query 'KeyPairs[].[KeyName,KeyPairId,CreateTime]' --output table
aws ec2 describe-placement-groups

# Spot & Reserved & Savings Plans
aws ec2 describe-spot-instance-requests --query 'SpotInstanceRequests[].[SpotInstanceRequestId,State,InstanceId,SpotPrice]' --output table
aws ec2 describe-spot-price-history --instance-types t3.medium --product-descriptions "Linux/UNIX" --max-items 5
aws ec2 describe-reserved-instances --filters "Name=state,Values=active" \
  --query 'ReservedInstances[].[ReservedInstancesId,InstanceType,InstanceCount,End]' --output table
aws savingsplans describe-savings-plans
```

### 9.2 Disks — EBS volumes and snapshots

```bash
# All volumes
aws ec2 describe-volumes \
  --query "Volumes[].{ID:VolumeId,SizeGiB:Size,Type:VolumeType,IOPS:Iops,State:State,AZ:AvailabilityZone,Enc:Encrypted,Attached:Attachments[0].InstanceId,Device:Attachments[0].Device,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table

# 💸 Unattached volumes = pure wasted money
aws ec2 describe-volumes --filters "Name=status,Values=available" \
  --query 'Volumes[].{ID:VolumeId,Size:Size,Type:VolumeType,Created:CreateTime}' --output table

# Total unattached GB
aws ec2 describe-volumes --filters "Name=status,Values=available" \
  --query 'sum(Volumes[].Size)'

# 🚨 Unencrypted volumes
aws ec2 describe-volumes --filters "Name=encrypted,Values=false" \
  --query 'Volumes[].[VolumeId,Size,Attachments[0].InstanceId]' --output table

# Old gp2 volumes you could upgrade to cheaper/faster gp3
aws ec2 describe-volumes --filters "Name=volume-type,Values=gp2" \
  --query 'Volumes[].[VolumeId,Size,Attachments[0].InstanceId]' --output table

# Volumes attached to one instance
aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=i-0abc123"

# Snapshots I own, newest first
aws ec2 describe-snapshots --owner-ids self \
  --query 'sort_by(Snapshots,&StartTime)[::-1][:20].{ID:SnapshotId,Vol:VolumeId,Size:VolumeSize,Started:StartTime,Desc:Description,State:State}' \
  --output table

# 🚨 Snapshots shared with the world
aws ec2 describe-snapshots --owner-ids self --restorable-by-user-ids all \
  --query 'Snapshots[].SnapshotId' --output text

# Snapshots older than a date (cleanup candidates)
aws ec2 describe-snapshots --owner-ids self \
  --query "Snapshots[?StartTime<'2024-01-01'].[SnapshotId,VolumeId,StartTime]" --output table

# Account-wide EBS defaults
aws ec2 get-ebs-encryption-by-default
aws ec2 get-ebs-default-kms-key-id
```

### 9.3 AMIs (machine images)

```bash
# My own AMIs, newest first
aws ec2 describe-images --owners self \
  --query 'sort_by(Images,&CreationDate)[::-1].{ID:ImageId,Name:Name,Created:CreationDate,State:State,Arch:Architecture,Public:Public}' \
  --output table

# Latest Amazon Linux 2023 (x86)
aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].[ImageId,Name,CreationDate]' --output text

# Latest Ubuntu 22.04 (owner 099720109477 = Canonical)
aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query 'sort_by(Images,&CreationDate)[-1].[ImageId,Name]' --output text

# 🏆 EASIEST WAY: AWS publishes latest AMI IDs in SSM Parameter Store
aws ssm get-parameters-by-path --path /aws/service/ami-amazon-linux-latest \
  --query 'Parameters[].[Name,Value]' --output table

aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text

# Which AMIs are actually in use right now?
aws ec2 describe-instances --query 'Reservations[].Instances[].ImageId' --output text \
  | tr '\t' '\n' | sort -u

# 🚨 Are any of my AMIs public?
aws ec2 describe-images --owners self --filters "Name=is-public,Values=true" \
  --query 'Images[].[ImageId,Name]' --output text

# Who did I share an AMI with?
aws ec2 describe-image-attribute --image-id ami-0abc --attribute launchPermission

# What snapshots back an AMI?
aws ec2 describe-images --image-ids ami-0abc \
  --query 'Images[].BlockDeviceMappings[].{Device:DeviceName,Snapshot:Ebs.SnapshotId,Size:Ebs.VolumeSize,Type:Ebs.VolumeType,Encrypted:Ebs.Encrypted}' \
  --output table
```

### 9.4 Launch templates

```bash
# All launch templates
aws ec2 describe-launch-templates \
  --query 'LaunchTemplates[].{Name:LaunchTemplateName,ID:LaunchTemplateId,Default:DefaultVersionNumber,Latest:LatestVersionNumber,Created:CreateTime}' \
  --output table

# All versions of one template
aws ec2 describe-launch-template-versions --launch-template-name my-web-template \
  --query 'LaunchTemplateVersions[].{Ver:VersionNumber,Default:DefaultVersion,AMI:LaunchTemplateData.ImageId,Type:LaunchTemplateData.InstanceType,Desc:VersionDescription}' \
  --output table

# The full contents of the latest version
aws ec2 describe-launch-template-versions --launch-template-name my-web-template \
  --versions '$Latest' --query 'LaunchTemplateVersions[0].LaunchTemplateData' --output json

# The default version (use $Default)
aws ec2 describe-launch-template-versions --launch-template-name my-web-template --versions '$Default'

# A specific version
aws ec2 describe-launch-template-versions --launch-template-name my-web-template --versions 3

# Decode the user-data inside a launch template
aws ec2 describe-launch-template-versions --launch-template-name my-web-template --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text | base64 -d

# Which AMI + type does every template's latest version use?
for lt in $(aws ec2 describe-launch-templates --query 'LaunchTemplates[].LaunchTemplateName' --output text); do
  echo -n "$lt : "
  aws ec2 describe-launch-template-versions --launch-template-name "$lt" --versions '$Latest' \
    --query 'LaunchTemplateVersions[0].LaunchTemplateData.[ImageId,InstanceType]' --output text
done

# 🪄 Reverse-engineer a launch template from a running instance
aws ec2 get-launch-template-data --instance-id i-0abc123 --query 'LaunchTemplateData' --output json
```

### 9.5 Auto Scaling groups

```bash
# All ASGs
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Running:length(Instances),LT:LaunchTemplate.LaunchTemplateName,Subnets:VPCZoneIdentifier,TGs:TargetGroupARNs}' \
  --output table

# One ASG
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names my-asg

# Instances and their lifecycle/health state
aws autoscaling describe-auto-scaling-instances \
  --query 'AutoScalingInstances[].{ID:InstanceId,ASG:AutoScalingGroupName,Health:HealthStatus,State:LifecycleState,AZ:AvailabilityZone}' \
  --output table

# 🚨 ASGs not at desired capacity (something is failing to launch)
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[?length(Instances)!=DesiredCapacity].[AutoScalingGroupName,DesiredCapacity,length(Instances)]' \
  --output table

# WHY did it scale / why did a launch fail? (read this during incidents)
aws autoscaling describe-scaling-activities --auto-scaling-group-name my-asg --max-items 10 \
  --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:Description,Detail:StatusMessage}' --output table

aws autoscaling describe-policies --auto-scaling-group-name my-asg
aws autoscaling describe-scheduled-actions
aws autoscaling describe-lifecycle-hooks --auto-scaling-group-name my-asg
```

---

## 10. Containers

### 10.1 EKS (Kubernetes)

**Mental model:** the **cluster** is the brain (control plane, managed by AWS). **Node groups** are the muscle (EC2 servers running your pods). **Add-ons** are the built-in helpers (networking, DNS, storage drivers).

```bash
# 1. What clusters exist?
aws eks list-clusters --query 'clusters' --output table

# 2. Full details of one
aws eks describe-cluster --name my-cluster \
  --query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint,VPC:resourcesVpcConfig.vpcId,Subnets:resourcesVpcConfig.subnetIds,SGs:resourcesVpcConfig.securityGroupIds,PublicAccess:resourcesVpcConfig.endpointPublicAccess,PrivateAccess:resourcesVpcConfig.endpointPrivateAccess,PublicCIDRs:resourcesVpcConfig.publicAccessCidrs,RoleArn:roleArn,Logging:logging.clusterLogging}' \
  --output json

# Just the version (upgrade planning)
aws eks describe-cluster --name my-cluster --query 'cluster.version' --output text

# Every cluster's version at a glance
for c in $(aws eks list-clusters --query 'clusters[]' --output text); do
  echo -n "$c : "
  aws eks describe-cluster --name "$c" --query 'cluster.[version,status]' --output text
done

# 🚨 Clusters with a public API endpoint open to 0.0.0.0/0
aws eks describe-cluster --name my-cluster \
  --query 'cluster.resourcesVpcConfig.[endpointPublicAccess,publicAccessCidrs]' --output json

# 3. Node groups
aws eks list-nodegroups --cluster-name my-cluster
aws eks describe-nodegroup --cluster-name my-cluster --nodegroup-name ng-1 \
  --query 'nodegroup.{Name:nodegroupName,Status:status,Type:capacityType,Instance:instanceTypes,AMIType:amiType,Disk:diskSize,Version:version,Release:releaseVersion,Scaling:scalingConfig,Subnets:subnets,LT:launchTemplate,ASGs:resources.autoScalingGroups[].name}' \
  --output json

# All node groups in all clusters
for c in $(aws eks list-clusters --query 'clusters[]' --output text); do
  for ng in $(aws eks list-nodegroups --cluster-name "$c" --query 'nodegroups[]' --output text); do
    echo -n "$c/$ng : "
    aws eks describe-nodegroup --cluster-name "$c" --nodegroup-name "$ng" \
      --query 'nodegroup.[status,version,instanceTypes[0],scalingConfig.desiredSize]' --output text
  done
done

# 4. Fargate profiles (serverless pods)
aws eks list-fargate-profiles --cluster-name my-cluster
aws eks describe-fargate-profile --cluster-name my-cluster --fargate-profile-name fp-1

# 5. Add-ons (vpc-cni, coredns, kube-proxy, ebs-csi-driver...)
aws eks list-addons --cluster-name my-cluster
aws eks describe-addon --cluster-name my-cluster --addon-name vpc-cni \
  --query 'addon.{Name:addonName,Version:addonVersion,Status:status,Role:serviceAccountRoleArn}' --output json

# Is a newer add-on version available?
aws eks describe-addon-versions --addon-name vpc-cni --kubernetes-version 1.30 \
  --query 'addons[].addonVersions[].addonVersion' --output text

# 6. Access (who can talk to the cluster)
aws eks list-access-entries --cluster-name my-cluster
aws eks describe-access-entry --cluster-name my-cluster --principal-arn arn:aws:iam::123456789012:role/DevOps
aws eks list-associated-access-policies --cluster-name my-cluster --principal-arn <role-arn>

# 7. Identity provider for IRSA (pod → IAM role)
aws eks describe-cluster --name my-cluster --query 'cluster.identity.oidc.issuer' --output text
aws eks list-pod-identity-associations --cluster-name my-cluster

# 8. In-progress upgrades
aws eks list-updates --name my-cluster
aws eks describe-update --name my-cluster --update-id <id>

# 9. 🔑 Wire up kubectl
aws eks update-kubeconfig --name my-cluster --region us-east-1
kubectl get nodes
```

### 10.2 ECS

```bash
aws ecs list-clusters --query 'clusterArns' --output table
aws ecs describe-clusters --clusters my-cluster --include ATTACHMENTS \
  --query 'clusters[].{Name:clusterName,Status:status,Running:runningTasksCount,Pending:pendingTasksCount,Services:activeServicesCount,Instances:registeredContainerInstancesCount}' \
  --output table

aws ecs list-services --cluster my-cluster
aws ecs describe-services --cluster my-cluster --services my-svc \
  --query 'services[].{Name:serviceName,Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount,TaskDef:taskDefinition,LaunchType:launchType}' \
  --output table

aws ecs list-tasks --cluster my-cluster --service-name my-svc
aws ecs describe-tasks --cluster my-cluster --tasks <task-arn> \
  --query 'tasks[].{Task:taskArn,Status:lastStatus,Health:healthStatus,CPU:cpu,Mem:memory,StoppedReason:stoppedReason}' --output json

aws ecs list-task-definitions --family-prefix my-app --sort DESC --max-items 5
aws ecs describe-task-definition --task-definition my-app:12 \
  --query 'taskDefinition.containerDefinitions[].{Name:name,Image:image,CPU:cpu,Mem:memory,Ports:portMappings}' --output json
```

### 10.3 ECR (container image registry)

```bash
aws ecr describe-repositories \
  --query 'repositories[].{Name:repositoryName,URI:repositoryUri,ScanOnPush:imageScanningConfiguration.scanOnPush,Tag:imageTagMutability}' \
  --output table

# Images in a repo, newest first
aws ecr describe-images --repository-name my-app \
  --query 'sort_by(imageDetails,&imagePushedAt)[::-1][:10].{Tags:imageTags,Pushed:imagePushedAt,SizeMB:imageSizeInBytes,Digest:imageDigest}' \
  --output table

# Untagged images (safe cleanup)
aws ecr list-images --repository-name my-app --filter tagStatus=UNTAGGED

# Vulnerability scan results
aws ecr describe-image-scan-findings --repository-name my-app --image-id imageTag=latest \
  --query 'imageScanFindings.findingSeverityCounts'

aws ecr get-lifecycle-policy --repository-name my-app
aws ecr get-repository-policy --repository-name my-app
```

---

## 11. DNS

### Mental model

**Route 53** is the internet's phone book. A **hosted zone** is one page in that book, for one domain like `example.com`. **Records** are the individual entries: "www → 1.2.3.4".

- **Public hosted zone** — the whole internet can look it up.
- **Private hosted zone** — only machines inside your VPCs can look it up.

### 11.1 Hosted zones

```bash
# All hosted zones
aws route53 list-hosted-zones \
  --query 'HostedZones[].{Name:Name,ID:Id,Private:Config.PrivateZone,Records:ResourceRecordSetCount,Comment:Config.Comment}' \
  --output table

# Find one by name (note the trailing dot!)
aws route53 list-hosted-zones-by-name --dns-name example.com. --max-items 1

# Get the ZONE ID into a variable — you need it constantly
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name example.com. \
  --query 'HostedZones[0].Id' --output text | cut -d/ -f3)
echo $ZONE_ID

# Full details, including the 4 nameservers to give your registrar
aws route53 get-hosted-zone --id $ZONE_ID \
  --query '{Zone:HostedZone.Name,Private:HostedZone.Config.PrivateZone,NS:DelegationSet.NameServers,VPCs:VPCs}' \
  --output json

# Only private zones
aws route53 list-hosted-zones --query 'HostedZones[?Config.PrivateZone==`true`].[Name,Id]' --output table

# Which VPCs a private zone is attached to
aws route53 get-hosted-zone --id $ZONE_ID --query 'VPCs' --output table
```

### 11.2 Records

```bash
# All records in a zone
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
  --query 'ResourceRecordSets[].{Name:Name,Type:Type,TTL:TTL,Values:ResourceRecords[].Value,Alias:AliasTarget.DNSName}' \
  --output table

# Only A records
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
  --query "ResourceRecordSets[?Type=='A']" --output json

# Only CNAMEs
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
  --query "ResourceRecordSets[?Type=='CNAME'].[Name,ResourceRecords[0].Value]" --output table

# Alias records (pointing at ALBs, CloudFront, S3)
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
  --query 'ResourceRecordSets[?AliasTarget].{Name:Name,Type:Type,Target:AliasTarget.DNSName,HealthCheck:AliasTarget.EvaluateTargetHealth}' \
  --output table

# Search for one hostname (server-side start point + client-side filter)
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
  --start-record-name "www.example.com." --start-record-type A --max-items 5

aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
  --query "ResourceRecordSets[?contains(Name,'api')]" --output json

# Records with routing policies (weighted / latency / failover / geo)
aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID \
  --query 'ResourceRecordSets[?SetIdentifier].{Name:Name,Type:Type,Set:SetIdentifier,Weight:Weight,Region:Region,Failover:Failover,Geo:GeoLocation}' \
  --output table

# Export every record from every zone (a great backup / diff artifact)
for z in $(aws route53 list-hosted-zones --query 'HostedZones[].Id' --output text); do
  zid=${z##*/}
  name=$(aws route53 get-hosted-zone --id "$zid" --query 'HostedZone.Name' --output text)
  echo "=== $name ($zid)"
  aws route53 list-resource-record-sets --hosted-zone-id "$zid" \
    --query 'ResourceRecordSets[].[Name,Type,TTL,join(`,`,ResourceRecords[].Value || [AliasTarget.DNSName])]' \
    --output text
done
```

### 11.3 Health checks, domains, and Resolver rules

```bash
# Health checks
aws route53 list-health-checks \
  --query 'HealthChecks[].{ID:Id,Type:HealthCheckConfig.Type,Target:HealthCheckConfig.FullyQualifiedDomainName,IP:HealthCheckConfig.IPAddress,Port:HealthCheckConfig.Port,Path:HealthCheckConfig.ResourcePath}' \
  --output table

aws route53 get-health-check-status --health-check-id <id>

# Did my DNS change finish propagating?
aws route53 get-change --id /change/C1234567890ABC

# Registered domains (this API lives ONLY in us-east-1)
aws route53domains list-domains --region us-east-1 \
  --query 'Domains[].[DomainName,Expiry,AutoRenew,TransferLock]' --output table

# ── Route 53 Resolver: hybrid DNS between AWS and on-prem ──
aws route53resolver list-resolver-endpoints \
  --query 'ResolverEndpoints[].{ID:Id,Name:Name,Direction:Direction,Status:Status,VPC:HostVPCId,IPs:IpAddressCount}' \
  --output table

aws route53resolver list-resolver-endpoint-ip-addresses --resolver-endpoint-id rslvr-out-123

# RESOLVER RULES — "send queries for corp.local to these on-prem DNS servers"
aws route53resolver list-resolver-rules \
  --query 'ResolverRules[].{ID:Id,Name:Name,Domain:DomainName,Type:RuleType,Status:Status,Targets:TargetIps[].Ip,Endpoint:ResolverEndpointId}' \
  --output table

aws route53resolver get-resolver-rule --resolver-rule-id rslvr-rr-0123456789abcdef0

# Which VPCs each rule applies to
aws route53resolver list-resolver-rule-associations \
  --query 'ResolverRuleAssociations[].{Rule:ResolverRuleId,VPC:VPCId,Status:Status}' --output table

# DNS firewall (block bad domains)
aws route53resolver list-firewall-rule-groups
aws route53resolver list-firewall-rules --firewall-rule-group-id rslvr-frg-123
aws route53resolver list-firewall-domain-lists
aws route53resolver list-resolver-query-log-configs
```

---

## 12. Everything else

### 12.1 IAM — who can do what

```bash
aws sts get-caller-identity                    # who am I?
aws iam list-users --query 'Users[].[UserName,CreateDate,PasswordLastUsed]' --output table
aws iam list-roles --query 'Roles[].[RoleName,CreateDate]' --output table
aws iam list-groups
aws iam list-policies --scope Local --query 'Policies[].[PolicyName,Arn,AttachmentCount]' --output table

# What can this role do?
aws iam list-attached-role-policies --role-name MyRole
aws iam list-role-policies --role-name MyRole                  # inline policies
aws iam get-role --role-name MyRole --query 'Role.AssumeRolePolicyDocument'   # who can assume it
aws iam get-policy-version --policy-arn <arn> --version-id v3 --query 'PolicyVersion.Document'

# Access keys and how stale they are
aws iam list-access-keys --user-name alice
aws iam get-access-key-last-used --access-key-id AKIA...

# 🚨 The security report card (CSV of every credential in the account)
aws iam generate-credential-report
aws iam get-credential-report --query 'Content' --output text | base64 -d

# 🚨 Users without MFA
for u in $(aws iam list-users --query 'Users[].UserName' --output text); do
  n=$(aws iam list-mfa-devices --user-name "$u" --query 'length(MFADevices)')
  [ "$n" = "0" ] && echo "NO MFA: $u"
done

# Full IAM dump (best single artifact for an audit)
aws iam get-account-authorization-details > iam-dump.json
aws iam get-account-summary
aws iam get-account-password-policy
```

### 12.2 S3

```bash
aws s3 ls                                              # all buckets
aws s3 ls s3://my-bucket/path/ --recursive --human-readable --summarize
aws s3api list-buckets --query 'Buckets[].[Name,CreationDate]' --output table

aws s3api get-bucket-location --bucket my-bucket
aws s3api get-bucket-encryption --bucket my-bucket
aws s3api get-bucket-versioning --bucket my-bucket
aws s3api get-bucket-policy --bucket my-bucket --query Policy --output text | python3 -m json.tool
aws s3api get-bucket-lifecycle-configuration --bucket my-bucket
aws s3api get-bucket-logging --bucket my-bucket
aws s3api get-bucket-tagging --bucket my-bucket

# 🚨 Buckets missing Block Public Access
for b in $(aws s3api list-buckets --query 'Buckets[].Name' --output text); do
  cfg=$(aws s3api get-public-access-block --bucket "$b" \
        --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null) \
        || cfg="NOT-SET"
  echo "$b : $cfg"
done
```

### 12.3 RDS and databases

```bash
aws rds describe-db-instances \
  --query 'DBInstances[].{ID:DBInstanceIdentifier,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,Status:DBInstanceStatus,MultiAZ:MultiAZ,Public:PubliclyAccessible,Storage:AllocatedStorage,Enc:StorageEncrypted,Endpoint:Endpoint.Address}' \
  --output table

aws rds describe-db-clusters \
  --query 'DBClusters[].{ID:DBClusterIdentifier,Engine:Engine,Version:EngineVersion,Status:Status,Writer:Endpoint,Reader:ReaderEndpoint,Members:DBClusterMembers[].DBInstanceIdentifier}' \
  --output json

# 🚨 Publicly reachable databases
aws rds describe-db-instances \
  --query 'DBInstances[?PubliclyAccessible==`true`].[DBInstanceIdentifier,Endpoint.Address]' --output table

# 🚨 Unencrypted databases
aws rds describe-db-instances \
  --query 'DBInstances[?StorageEncrypted==`false`].DBInstanceIdentifier' --output text

aws rds describe-db-subnet-groups
aws rds describe-db-parameter-groups
aws rds describe-db-snapshots --snapshot-type manual --query 'DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime]' --output table
aws rds describe-events --duration 1440
aws rds describe-pending-maintenance-actions

# Other datastores
aws dynamodb list-tables
aws dynamodb describe-table --table-name my-table --query 'Table.{Name:TableName,Status:TableStatus,Items:ItemCount,SizeBytes:TableSizeBytes,Mode:BillingModeSummary.BillingMode}'
aws elasticache describe-cache-clusters --show-cache-node-info
aws redshift describe-clusters
```

### 12.4 Serverless and messaging

```bash
aws lambda list-functions \
  --query 'Functions[].{Name:FunctionName,Runtime:Runtime,Mem:MemorySize,Timeout:Timeout,Modified:LastModified,VPC:VpcConfig.VpcId}' \
  --output table

# 🚨 Functions on old/deprecated runtimes
aws lambda list-functions --query "Functions[?starts_with(Runtime,'python3.8') || starts_with(Runtime,'nodejs16')].[FunctionName,Runtime]" --output table

aws lambda get-function --function-name my-fn
aws lambda get-function-configuration --function-name my-fn --query 'Environment.Variables'
aws lambda list-event-source-mappings --function-name my-fn

aws sns list-topics
aws sns list-subscriptions-by-topic --topic-arn <arn>
aws sqs list-queues
aws sqs get-queue-attributes --queue-url <url> --attribute-names All

aws apigateway get-rest-apis --query 'items[].[name,id,createdDate]' --output table
aws apigatewayv2 get-apis --query 'Items[].[Name,ApiId,ProtocolType,ApiEndpoint]' --output table
aws stepfunctions list-state-machines
```

### 12.5 Monitoring and logs

```bash
# Alarms — start with the ones firing right now
aws cloudwatch describe-alarms --state-value ALARM \
  --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,State:StateValue,Reason:StateReason}' --output table

aws cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
aws cloudwatch describe-alarm-history --alarm-name my-alarm --max-items 10

# Log groups, biggest first, plus retention
aws logs describe-log-groups \
  --query 'sort_by(logGroups,&storedBytes)[::-1][:20].{Name:logGroupName,SizeMB:storedBytes,RetentionDays:retentionInDays}' \
  --output table

# 💸 Log groups with NO retention = stored forever = growing bill
aws logs describe-log-groups --query 'logGroups[?retentionInDays==`null`].logGroupName' --output text

aws logs describe-log-streams --log-group-name /aws/lambda/my-fn --order-by LastEventTime --descending --max-items 5

# Search logs for errors in the last hour
aws logs filter-log-events --log-group-name /aws/lambda/my-fn \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) \
  --filter-pattern "ERROR" \
  --query 'events[].[timestamp,message]' --output text

# Live tail (CLI v2)
aws logs tail /aws/lambda/my-fn --follow --since 10m

# A metric graph in numbers
aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0abc123 \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[].[Timestamp,Average]' --output table
```

### 12.6 Ops tooling: SSM, Secrets, KMS, ACM, CloudFront, EFS, Backup

```bash
# SSM — which instances are managed (can I run commands / Session Manager?)
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{ID:InstanceId,Ping:PingStatus,Platform:PlatformName,Version:PlatformVersion,Agent:AgentVersion,IP:IPAddress}' \
  --output table

aws ssm describe-parameters --query 'Parameters[].[Name,Type,LastModifiedDate]' --output table
aws ssm get-parameter --name /app/db/password --with-decryption --query 'Parameter.Value' --output text
aws ssm get-parameters-by-path --path /app/prod --recursive
aws ssm describe-patch-baselines
aws ssm describe-instance-patch-states --instance-ids i-0abc
aws ssm start-session --target i-0abc123          # SSH without SSH

# Secrets Manager
aws secretsmanager list-secrets --query 'SecretList[].[Name,LastChangedDate,RotationEnabled]' --output table
aws secretsmanager describe-secret --secret-id prod/db
aws secretsmanager get-secret-value --secret-id prod/db --query SecretString --output text

# KMS
aws kms list-aliases --query 'Aliases[].[AliasName,TargetKeyId]' --output table
aws kms describe-key --key-id alias/my-key
aws kms get-key-rotation-status --key-id <key-id>

# ACM certificates — and which are expiring
aws acm list-certificates \
  --query 'CertificateSummaryList[].[DomainName,CertificateArn,Status]' --output table
aws acm describe-certificate --certificate-arn <arn> \
  --query 'Certificate.{Domain:DomainName,SANs:SubjectAlternativeNames,Status:Status,Expires:NotAfter,InUseBy:InUseBy}' --output json
aws acm list-certificates --certificate-statuses EXPIRED PENDING_VALIDATION

# CloudFront (global service — always us-east-1)
aws cloudfront list-distributions \
  --query 'DistributionList.Items[].{ID:Id,Domain:DomainName,Aliases:Aliases.Items,Origin:Origins.Items[0].DomainName,Status:Status,Enabled:Enabled}' \
  --output json
aws cloudfront get-distribution-config --id E123ABC

# EFS
aws efs describe-file-systems --query 'FileSystems[].{ID:FileSystemId,Name:Name,SizeBytes:SizeInBytes.Value,Enc:Encrypted,Mode:PerformanceMode}' --output table
aws efs describe-mount-targets --file-system-id fs-123
aws efs describe-access-points

# AWS Backup
aws backup list-backup-plans
aws backup list-backup-vaults
aws backup list-protected-resources
aws backup list-backup-jobs --by-state FAILED --max-results 10

# WAF (v2). Use --scope CLOUDFRONT (in us-east-1) for CloudFront ACLs
aws wafv2 list-web-acls --scope REGIONAL
aws wafv2 get-web-acl --scope REGIONAL --name my-acl --id <id>
```

### 12.7 Account, org, cost, quotas

```bash
aws organizations describe-organization
aws organizations list-accounts --query 'Accounts[].[Id,Name,Email,Status]' --output table
aws organizations list-roots
aws organizations list-organizational-units-for-parent --parent-id r-abcd
aws organizations list-policies --filter SERVICE_CONTROL_POLICY

# Which regions are turned on for me?
aws ec2 describe-regions --query 'Regions[].RegionName' --output text | tr '\t' '\n' | sort

# Service quotas (limits) — e.g. how many VPCs can I have?
aws service-quotas list-service-quotas --service-code vpc \
  --query 'Quotas[].[QuotaName,Value]' --output table
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A

# Cost — last month by service
aws ce get-cost-and-usage \
  --time-period Start=2026-07-01,End=2026-08-01 \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' --output table

# Ongoing AWS incidents affecting me
aws health describe-events --filter eventStatusCodes=open --region us-east-1

# CloudFormation
aws cloudformation describe-stacks --query 'Stacks[].[StackName,StackStatus,LastUpdatedTime]' --output table
aws cloudformation list-stack-resources --stack-name my-stack
aws cloudformation describe-stack-events --stack-name my-stack --max-items 10
aws cloudformation detect-stack-drift --stack-name my-stack
```

---

## 13. Cross-service inventory

### The tag API — find *anything* by tag, across all services

```bash
# Everything tagged Environment=production
aws resourcegroupstaggingapi get-resources \
  --tag-filters Key=Environment,Values=production \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n'

# Everything of a given type
aws resourcegroupstaggingapi get-resources --resource-type-filters ec2:instance rds:db

# 🚨 What tag keys are even in use? (spot inconsistent tagging: Env vs env vs Environment)
aws resourcegroupstaggingapi get-tag-keys --query 'TagKeys' --output text | tr '\t' '\n' | sort

aws resourcegroupstaggingapi get-tag-values --key Environment
```

### AWS Config — the query language for your whole account

If Config is enabled, this is the single most powerful inventory tool:

```bash
aws configservice describe-configuration-recorders
aws configservice describe-config-rules --query 'ConfigRules[].[ConfigRuleName,ConfigRuleState]' --output table

# Non-compliant resources for a rule
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name s3-bucket-public-read-prohibited \
  --compliance-types NON_COMPLIANT

# SQL over your infrastructure 🤯
aws configservice select-resource-config \
  --expression "SELECT resourceId, resourceType, tags WHERE resourceType = 'AWS::EC2::Instance'"

aws configservice select-resource-config \
  --expression "SELECT resourceId WHERE resourceType='AWS::EC2::SecurityGroup' AND configuration.ipPermissions.ipRanges = '0.0.0.0/0'"

# Full config history of one resource — "what changed?"
aws configservice get-resource-config-history --resource-type AWS::EC2::Instance --resource-id i-0abc
```

### CloudTrail — who did it, and when

```bash
# Recent changes by a person
aws cloudtrail lookup-events --lookup-attributes AttributeKey=Username,AttributeValue=alice --max-items 10

# Who deleted that security group?
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=DeleteSecurityGroup \
  --query 'Events[].[EventTime,Username,EventName]' --output table

# Everything that touched one resource
aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue=i-0abc123

aws cloudtrail describe-trails
aws cloudtrail get-trail-status --name my-trail
```

### Security findings

```bash
aws securityhub get-findings --filters '{"SeverityLabel":[{"Value":"CRITICAL","Comparison":"EQUALS"}]}' \
  --query 'Findings[].[Title,Resources[0].Id]' --output table
aws guardduty list-detectors
aws guardduty list-findings --detector-id <id>
aws inspector2 list-findings --filter-criteria '{"severity":[{"comparison":"EQUALS","value":"CRITICAL"}]}'
aws access-analyzer list-analyzers
aws access-analyzer list-findings --analyzer-arn <arn>
```

---

## 14. Audit recipes

Copy-paste these. They are the ones cloud teams actually run.

### Full network map of one VPC

```bash
#!/usr/bin/env bash
VPC=vpc-0a1b2c3d4e5f67890

echo "===== VPC ====="
aws ec2 describe-vpcs --vpc-ids $VPC --query 'Vpcs[].[VpcId,CidrBlock]' --output text

echo "===== SUBNETS ====="
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query 'Subnets[].[SubnetId,CidrBlock,AvailabilityZone,AvailableIpAddressCount,MapPublicIpOnLaunch]' --output table

echo "===== ROUTE TABLES ====="
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
  --query 'RouteTables[].[RouteTableId,join(`,`,Associations[].SubnetId || [`main`])]' --output table

echo "===== IGW / NAT ====="
aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
  --query 'InternetGateways[].InternetGatewayId' --output text
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" \
  --query 'NatGateways[].[NatGatewayId,SubnetId,State]' --output text

echo "===== SECURITY GROUPS ====="
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output table

echo "===== NACLS ====="
aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$VPC" \
  --query 'NetworkAcls[].[NetworkAclId,IsDefault]' --output table

echo "===== ENDPOINTS ====="
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" \
  --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,VpcEndpointType]' --output table

echo "===== INSTANCES ====="
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType,State.Name,PrivateIpAddress,Tags[?Key=='Name']|[0].Value]" --output table
```

### Cost-waste hunt

```bash
echo "-- Unattached EBS volumes --"
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

echo "-- Unassociated Elastic IPs --"
aws ec2 describe-addresses --query 'Addresses[?AssociationId==`null`].PublicIp' --output text

echo "-- Stopped instances (still paying for disk) --"
aws ec2 describe-instances --filters Name=instance-state-name,Values=stopped \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType]' --output text

echo "-- Empty target groups --"
aws elbv2 describe-target-groups --query 'TargetGroups[?length(LoadBalancerArns)==`0`].TargetGroupName' --output text

echo "-- Orphaned ENIs --"
aws ec2 describe-network-interfaces --filters Name=status,Values=available \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text

echo "-- Log groups with no retention --"
aws logs describe-log-groups --query 'logGroups[?retentionInDays==`null`].logGroupName' --output text

echo "-- Old gp2 volumes (upgrade to gp3) --"
aws ec2 describe-volumes --filters Name=volume-type,Values=gp2 --query 'Volumes[].VolumeId' --output text
```

### Security sweep

```bash
echo "== SGs open to 0.0.0.0/0 =="
aws ec2 describe-security-groups --filters Name=ip-permission.cidr,Values=0.0.0.0/0 \
  --query 'SecurityGroups[].[GroupId,GroupName,VpcId]' --output table

echo "== Unencrypted EBS =="
aws ec2 describe-volumes --filters Name=encrypted,Values=false --query 'Volumes[].VolumeId' --output text

echo "== Public RDS =="
aws rds describe-db-instances --query 'DBInstances[?PubliclyAccessible==`true`].DBInstanceIdentifier' --output text

echo "== Public AMIs I own =="
aws ec2 describe-images --owners self --filters Name=is-public,Values=true --query 'Images[].ImageId' --output text

echo "== Internet-facing load balancers =="
aws elbv2 describe-load-balancers --query "LoadBalancers[?Scheme=='internet-facing'].[LoadBalancerName,DNSName]" --output table

echo "== IAM users with console access =="
aws iam list-users --query 'Users[?PasswordLastUsed].[UserName,PasswordLastUsed]' --output table
```

### Run one command in every region

```bash
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  n=$(aws ec2 describe-instances --region "$r" \
      --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)
  [ "$n" != "0" ] && [ -n "$n" ] && echo "$r: $n instances"
done
```

### Run across every account in the org

```bash
for acct in $(aws organizations list-accounts --query 'Accounts[?Status==`ACTIVE`].Id' --output text); do
  creds=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${acct}:role/OrganizationAccountAccessRole" \
    --role-session-name audit --query 'Credentials' --output json 2>/dev/null) || continue
  export AWS_ACCESS_KEY_ID=$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')
  export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')
  export AWS_SESSION_TOKEN=$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')
  echo "== $acct =="
  aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,CidrBlock]' --output text
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done
```

---

## 15. Best practices

### Do these

1. **Run `aws sts get-caller-identity` before anything risky.** Know which account you're in.
2. **Use SSO, not access keys.** Tokens that expire can't be leaked forever.
3. **Use a read-only role for investigating.** `ReadOnlyAccess` or `ViewOnlyAccess` — you literally cannot break prod.
4. **Filter server-side (`--filters`) first, shape client-side (`--query`) second.**
5. **Turn the pager off:** `aws configure set cli_pager ""`.
6. **Save raw JSON before you slice it.** `aws ec2 describe-instances > snapshot.json` — then experiment with `--query` offline using `jp` or `jq`.
7. **Name your profiles after environments** (`dev`, `stage`, `prod`) and colour your terminal per profile.
8. **Set retention on everything.** Look at logs and snapshots at least quarterly.
9. **Make changes in Terraform/CloudFormation, not the CLI.** The CLI is for *reading* and *emergencies*. Changes made by hand get wiped out on the next `terraform apply` — this is called drift.
10. **Add `--dry-run`** to EC2 mutating commands to test permissions without doing anything.

### Avoid these

| Mistake | Why it hurts | Do instead |
|---|---|---|
| `\| grep vpc-123` on JSON | Breaks whenever formatting changes | `--query` or `jq` |
| Forgetting `--region` | Silently looks at the wrong data center | `export AWS_REGION=` |
| Long-lived access keys in `~/.aws/credentials` | The #1 cause of AWS breaches | SSO |
| Running describes in a loop with no `sleep` | API throttling (`RequestLimitExceeded`) | `--page-size`, batch IDs, add `sleep 0.2` |
| Using `--output text` with variable fields | Nulls vanish, columns shift | Fixed `--query` field list, or use `json` |
| Assuming `--filters` works everywhere | Errors on EKS, ELBv2, Route 53 | Check `<command> help` |
| Case-mismatched tag filters | Silently returns nothing | Standardize tag casing; use `--query` if unsure |

### Handy config

```bash
aws configure set cli_pager ""
aws configure set output json
aws configure set region us-east-1
aws configure set cli_auto_prompt on-partial     # helps you discover commands
aws configure set max_attempts 10                 # retry on throttling
aws configure list-profiles
aws configure list
```

### Discovery — how to find any command yourself

```bash
aws help                       # all services
aws ec2 help                   # all EC2 operations
aws ec2 describe-vpcs help     # all options + filter names for this one
aws ec2 wait help              # the "wait until ready" helpers

# Search for a command
aws ec2 help | grep -i "describe-.*endpoint"
```

### Quick-reference: resource → command

| I want to see... | Command |
|---|---|
| VPCs | `aws ec2 describe-vpcs` |
| Subnets | `aws ec2 describe-subnets` |
| Route tables & routes | `aws ec2 describe-route-tables` |
| Internet gateway | `aws ec2 describe-internet-gateways` |
| NAT gateway | `aws ec2 describe-nat-gateways --filter ...` |
| Security groups | `aws ec2 describe-security-groups` |
| Individual SG rules | `aws ec2 describe-security-group-rules` |
| NACLs | `aws ec2 describe-network-acls` |
| VPC endpoints + policies | `aws ec2 describe-vpc-endpoints` |
| Endpoint services | `aws ec2 describe-vpc-endpoint-services` |
| Peering | `aws ec2 describe-vpc-peering-connections` |
| Transit gateway | `aws ec2 describe-transit-gateways` |
| TGW routes | `aws ec2 search-transit-gateway-routes` |
| Elastic IPs | `aws ec2 describe-addresses` |
| ENIs | `aws ec2 describe-network-interfaces` |
| Prefix lists | `aws ec2 describe-managed-prefix-lists` |
| Flow logs | `aws ec2 describe-flow-logs` |
| VPN / DX | `aws ec2 describe-vpn-connections` / `aws directconnect describe-connections` |
| Load balancers | `aws elbv2 describe-load-balancers` |
| Target groups | `aws elbv2 describe-target-groups` |
| Target health | `aws elbv2 describe-target-health --target-group-arn ...` |
| Listeners | `aws elbv2 describe-listeners --load-balancer-arn ...` |
| Listener rules | `aws elbv2 describe-rules --listener-arn ...` |
| EC2 instances | `aws ec2 describe-instances` |
| Instance health | `aws ec2 describe-instance-status` |
| EBS volumes | `aws ec2 describe-volumes` |
| Snapshots | `aws ec2 describe-snapshots --owner-ids self` |
| AMIs | `aws ec2 describe-images --owners self` |
| Latest AWS AMI ID | `aws ssm get-parameters-by-path --path /aws/service/ami-amazon-linux-latest` |
| Launch templates | `aws ec2 describe-launch-templates` |
| Launch template contents | `aws ec2 describe-launch-template-versions --versions '$Latest'` |
| Auto Scaling groups | `aws autoscaling describe-auto-scaling-groups` |
| Scaling failures | `aws autoscaling describe-scaling-activities` |
| EKS clusters | `aws eks list-clusters` → `aws eks describe-cluster --name` |
| EKS node groups | `aws eks list-nodegroups` → `describe-nodegroup` |
| EKS add-ons | `aws eks list-addons` → `describe-addon` |
| EKS access | `aws eks list-access-entries` |
| kubectl setup | `aws eks update-kubeconfig --name ...` |
| Hosted zones | `aws route53 list-hosted-zones` |
| DNS records | `aws route53 list-resource-record-sets --hosted-zone-id ...` |
| Health checks | `aws route53 list-health-checks` |
| Resolver endpoints | `aws route53resolver list-resolver-endpoints` |
| Resolver rules | `aws route53resolver list-resolver-rules` |
| Certificates | `aws acm list-certificates` |
| IAM roles | `aws iam list-roles` |
| S3 buckets | `aws s3 ls` |
| RDS | `aws rds describe-db-instances` |
| Lambda | `aws lambda list-functions` |
| ECS | `aws ecs list-clusters` → `describe-clusters` |
| ECR | `aws ecr describe-repositories` |
| Alarms | `aws cloudwatch describe-alarms` |
| Log groups | `aws logs describe-log-groups` |
| Parameters | `aws ssm describe-parameters` |
| Secrets | `aws secretsmanager list-secrets` |
| Managed instances | `aws ssm describe-instance-information` |
| CloudFront | `aws cloudfront list-distributions` |
| Anything by tag | `aws resourcegroupstaggingapi get-resources --tag-filters ...` |
| Who did what | `aws cloudtrail lookup-events` |
| Accounts in org | `aws organizations list-accounts` |
| Service limits | `aws service-quotas list-service-quotas --service-code ec2` |

---

## Final word

The whole skill is three habits:

1. **`describe` to see it, `--filters` to narrow it, `--query` to shape it.**
2. **When you don't know the command, run `aws <service> help`.**
3. **Read the account name before you type anything that changes something.**

Everything else is just remembering which service owns which noun — and that's what this document is for.
