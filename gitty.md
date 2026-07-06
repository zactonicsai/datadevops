# Plan: Tracking All Our AWS Infrastructure and Data Platform Changes in GitLab

**Written in plain language so everyone on the team can understand it.**

---

## 1. The Big Picture (Why Are We Doing This?)

Right now, our AWS cloud setup is like a big house that lots of people have keys to. People add rooms, move furniture, and change the locks — but nobody writes it down. When something breaks, we can't answer basic questions like:

- **What changed?**
- **Who changed it?**
- **When did it change?**
- **Why did it change?**
- **How do we put it back the way it was?**

Our "house" includes AWS infrastructure (servers, networks, storage, security rules) **and** the data platforms running on top of it:

| Platform | What it does (simple version) |
|---|---|
| **Kafka (Amazon MSK or self-managed)** | A conveyor belt that moves data between systems in real time |
| **NiFi** | A visual pipeline builder that moves and transforms data |
| **OpenSearch** | A super-fast search engine and log explorer |
| **Keycloak** | The security guard — handles logins and who can access what |
| **Databricks** | A big workspace for data analysis and machine learning |

**The goal:** Every change to any of these gets recorded in **GitLab** — the code goes in **Git repositories**, and the *reason and approval* for each change goes in **GitLab Issues**. Eventually, no one changes anything by clicking around in the AWS console. Everything goes through code, review, and automation.

Think of it like this: **Git is the diary, GitLab Issues are the permission slips, and pipelines are the robots that do the work.**

---

## 2. Key Ideas You Need to Know (Background)

### 2.1 Infrastructure as Code (IaC)
Instead of clicking buttons in the AWS website to create a server, you write a **text file** that describes the server. A tool reads the file and builds it for you. Because it's text, you can save it in Git, compare versions, and review changes like homework before it's turned in.

### 2.2 The Tools We'll Use

- **AWS CLI** — a command-line remote control for AWS. Great for *reading* what exists today.
- **Terraform** — the main IaC tool. It *describes and builds* infrastructure (VPCs, MSK clusters, OpenSearch domains, IAM roles, Databricks workspaces). It keeps a "state file" that remembers what it built.
- **Ansible** — a tool that *configures things inside* servers and applications (installing NiFi, tuning Kafka settings, configuring Keycloak realms). Terraform builds the house; Ansible arranges the furniture.
- **GitLab** — stores all the code, tracks all the issues (tickets), runs all the pipelines (automation robots), and holds the approval history.
- **GitLab Issues** — every change starts as an issue: "We need to add a new Kafka topic for billing events." The issue links to the code change (Merge Request) that does it.

### 2.3 Terraform vs. Ansible — Who Does What?

| Question | Terraform | Ansible |
|---|---|---|
| Creates AWS resources (VPC, EC2, MSK, S3, IAM)? | ✅ Best at this | Can, but clunky |
| Configures software inside servers? | ❌ Not its job | ✅ Best at this |
| Manages Keycloak realms/clients? | ✅ (Keycloak provider) or | ✅ (Ansible modules) — pick one |
| Manages Kafka topics? | ✅ (Kafka/MSK providers) | ✅ (community modules) — pick one |
| Remembers state? | Yes (state file) | No (checks live each run) |

**Rule of thumb:** Terraform for anything AWS creates or bills you for. Ansible for anything you'd configure *after* the thing exists.

---

## 3. The Phases (Our Roadmap)

We'll do this in **four phases**. Each phase is useful on its own, so even if we stop halfway, we're better off than today.

```
Phase 0: Get Organized (GitLab setup)          ~2 weeks
Phase 1: Take a Snapshot (AWS CLI exports)     ~4-6 weeks
Phase 2: Convert to Code (Terraform+Ansible)   ~3-6 months
Phase 3: Automate Everything (Pipelines+Agents) ongoing
```

---

## Phase 0: Get Organized in GitLab (Weeks 1–2)

Before touching AWS, set up the "filing cabinet."

### Steps

1. **Create a GitLab group** called something like `platform-infrastructure`.
2. **Create repositories (projects)** inside it. Suggested layout:
   - `aws-inventory` — raw snapshots of what exists (Phase 1 output)
   - `terraform-core` — networking, IAM, shared AWS stuff
   - `terraform-data-platform` — MSK/Kafka, OpenSearch, Databricks
   - `ansible-config` — NiFi, Keycloak, Kafka tuning, OS configs
   - `platform-docs` — runbooks, diagrams, this plan
3. **Set up issue labels** so issues are easy to sort:
   - Service: `kafka`, `nifi`, `opensearch`, `keycloak`, `databricks`, `network`, `iam`
   - Type: `change-request`, `incident`, `drift-detected`, `import-task`
   - Environment: `dev`, `staging`, `prod`
4. **Create issue templates.** Every change request must answer: *What? Why? Which environment? Rollback plan? Risk level?*
5. **Set branch protection rules:** nobody pushes straight to `main`. All changes go through a **Merge Request (MR)** with at least one reviewer.
6. **Create a milestone or epic per phase** so leadership can see progress.

### 0.1 Setting Up the GitLab Group and Repos (Step by Step)

You can do this by clicking in the GitLab website, or with the **`glab` CLI** (GitLab's command-line tool). Here are both.

**Option A — In the website:**
1. Top-left menu → **Groups → New group** → name it `platform-infrastructure`.
2. Inside the group: **New project → Create blank project** for each repo listed above.
3. In each project: **Settings → Repository → Protected branches** → protect `main`, set "Allowed to push" = *No one*, "Allowed to merge" = *Maintainers*.
4. **Settings → Merge requests** → check "Pipelines must succeed" and require at least **1 approval**.

**Option B — With the `glab` CLI (faster, repeatable):**

```bash
# Install glab (Linux example; also available via brew on Mac)
curl -sSL https://gitlab.com/gitlab-org/cli/-/releases/permalink/latest/downloads/glab_amd64.deb -o glab.deb
sudo dpkg -i glab.deb

# Log in to your GitLab (works for gitlab.com or self-hosted)
glab auth login

# Create the projects inside your group
for repo in aws-inventory terraform-core terraform-data-platform ansible-config platform-docs; do
  glab repo create platform-infrastructure/$repo --private \
    --description "Part of the infrastructure-as-code program"
done

# Create the labels in the group (repeat per project or use group labels in the UI)
for label in kafka nifi opensearch keycloak databricks network iam \
             change-request incident drift-detected import-task \
             env::dev env::staging env::prod; do
  glab label create "$label" --repo platform-infrastructure/aws-inventory
done
```

### 0.2 Directory Layout for Each Repo

**`aws-inventory`** (Phase 1 output lives here):

```
aws-inventory/
├── README.md                  # What this repo is, how to run the snapshot
├── .gitlab-ci.yml             # The scheduled snapshot pipeline
├── scripts/
│   ├── snapshot.sh            # Main AWS CLI export script
│   ├── snapshot-apps.sh       # Kafka/NiFi/Keycloak/Databricks exports
│   └── scrub.py               # Removes secrets + noisy fields, sorts JSON
└── inventory/
    ├── 111111111111/          # AWS account ID
    │   ├── us-east-1/
    │   │   ├── ec2/
    │   │   │   ├── instances.json
    │   │   │   ├── security-groups.json
    │   │   │   └── vpcs.json
    │   │   ├── msk/
    │   │   ├── opensearch/
    │   │   ├── iam/           # IAM is global; store under one region folder
    │   │   └── s3/
    │   └── eu-west-1/...
    └── apps/                  # Non-AWS exports
        ├── kafka/topics.txt
        ├── nifi/root-flow.json
        ├── keycloak/realm-export.json
        └── databricks/jobs.json
```

**`terraform-data-platform`** (Phase 2):

```
terraform-data-platform/
├── README.md
├── .gitlab-ci.yml
├── modules/                   # Reusable building blocks
│   ├── kafka-cluster/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── opensearch-domain/
│   └── databricks-workspace/
└── environments/
    ├── dev/
    │   ├── main.tf            # Calls the modules with dev-sized settings
    │   ├── backend.tf         # Points at GitLab-managed state
    │   └── terraform.tfvars
    ├── staging/
    └── prod/
```

**`ansible-config`** (Phase 2):

```
ansible-config/
├── ansible.cfg
├── .gitlab-ci.yml
├── inventories/
│   ├── dev/aws_ec2.yml        # Dynamic inventory: finds hosts by AWS tags
│   └── prod/aws_ec2.yml
├── group_vars/
│   ├── nifi.yml
│   ├── kafka.yml
│   └── keycloak.yml           # Secrets referenced from vault, never plain text
├── roles/
│   ├── nifi/ (tasks/, templates/, handlers/)
│   ├── kafka-tuning/
│   └── keycloak-config/
└── playbooks/
    ├── site.yml
    ├── nifi-deploy.yml
    └── keycloak-realms.yml
```

### 0.3 Issue Template Example

Save this file in every repo at `.gitlab/issue_templates/Change_Request.md` — GitLab then offers it as a dropdown when someone opens an issue:

```markdown
## What do you want to change?
<!-- Example: Add Kafka topic `billing-events` with 12 partitions -->

## Why?
<!-- The business or technical reason -->

## Which environment(s)?
- [ ] dev
- [ ] staging
- [ ] prod

## Risk level
- [ ] Low (no user impact)
- [ ] Medium (brief impact possible)
- [ ] High (downtime or data risk — needs extra review)

## Rollback plan
<!-- How do we undo this if it goes wrong? -->

/label ~change-request
```

### The Golden Rule (start enforcing now)
> **No change without an issue. No code change without a merge request. Every merge request links to its issue.**

Even before automation exists, people making manual console changes must open an issue describing what they did. This builds the habit.

### Pros and Cons of Doing Phase 0 First
- ✅ Cheap, fast, zero risk to production.
- ✅ Builds the culture before the tools.
- ❌ Feels like paperwork; some people will grumble. Leadership support helps.

---

## Phase 1: Take a Snapshot with the AWS CLI (Weeks 3–8)

**Goal:** Pull *everything* that currently exists in AWS into text files (JSON), and commit them to the `aws-inventory` repo. This is our "before" photo. We can't manage what we can't see.

### 1.1 Setting Up the AWS CLI First

Before any snapshot commands work, each person (and later, the pipeline) needs the CLI installed and logged in:

```bash
# Install AWS CLI v2 (Linux)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
aws --version        # should say aws-cli/2.x

# Set up a read-only profile for each account (best practice: use SSO, not long-lived keys)
aws configure sso    # walks you through connecting to AWS IAM Identity Center
# ...or the classic way (avoid for humans if you can):
aws configure --profile prod-readonly

# Test that it works and see who you are
aws sts get-caller-identity --profile prod-readonly

# Handy defaults so files come out as JSON
export AWS_PROFILE=prod-readonly
export AWS_DEFAULT_OUTPUT=json
```

**Important:** the snapshot user/role should have the AWS-managed **`ReadOnlyAccess`** or **`ViewOnlyAccess`** policy — it can *look* at everything but *touch* nothing. That makes Phase 1 completely safe.

Also install **`jq`** (a JSON Swiss-army knife) — we use it to sort and clean files:

```bash
sudo apt-get install -y jq
```

### 1.2 The Full AWS CLI Command Reference (Copy-Paste Ready)

Every `describe-*` / `list-*` / `get-*` command is **read-only** and returns JSON. Here is the full set, grouped by service. (Run each in every region you use; IAM, S3-list, Route53, and CloudFront are global — run once.)

**Networking (VPC and friends):**

```bash
aws ec2 describe-vpcs                        > vpcs.json
aws ec2 describe-subnets                     > subnets.json
aws ec2 describe-route-tables                > route-tables.json
aws ec2 describe-internet-gateways           > internet-gateways.json
aws ec2 describe-nat-gateways                > nat-gateways.json
aws ec2 describe-security-groups             > security-groups.json
aws ec2 describe-network-acls                > network-acls.json
aws ec2 describe-vpc-endpoints               > vpc-endpoints.json
aws ec2 describe-vpc-peering-connections     > vpc-peering.json
aws ec2 describe-transit-gateways            > transit-gateways.json
aws ec2 describe-addresses                   > elastic-ips.json
```

**Compute (servers and containers):**

```bash
aws ec2 describe-instances                   > ec2-instances.json
aws ec2 describe-volumes                     > ebs-volumes.json
aws ec2 describe-key-pairs                   > key-pairs.json
aws ec2 describe-launch-templates            > launch-templates.json
aws ec2 describe-images --owners self        > our-amis.json
aws autoscaling describe-auto-scaling-groups > asgs.json
aws eks list-clusters                        > eks-clusters.json
aws eks describe-cluster --name MY_CLUSTER   > eks-MY_CLUSTER.json
aws ecs list-clusters                        > ecs-clusters.json
aws lambda list-functions                    > lambda-functions.json
```

**Load balancers and DNS:**

```bash
aws elbv2 describe-load-balancers            > load-balancers.json
aws elbv2 describe-target-groups             > target-groups.json
aws elbv2 describe-listeners --load-balancer-arn ARN > listeners-ARN.json
aws route53 list-hosted-zones                > route53-zones.json
aws route53 list-resource-record-sets --hosted-zone-id ZONEID > dns-ZONEID.json
aws acm list-certificates                    > certificates.json
```

**Kafka (Amazon MSK):**

```bash
aws kafka list-clusters-v2                   > msk-clusters.json
aws kafka describe-cluster-v2 --cluster-arn ARN          > msk-detail-ARN.json
aws kafka list-configurations                > msk-configs.json
aws kafka describe-configuration-revision --arn CFGARN --revision 1 > msk-config-rev1.json
aws kafka get-bootstrap-brokers --cluster-arn ARN        > msk-brokers-ARN.json
aws kafka list-scram-secrets --cluster-arn ARN           > msk-scram-list.json   # names only
```

**OpenSearch:**

```bash
aws opensearch list-domain-names             > opensearch-domains.json
aws opensearch describe-domain --domain-name MY_DOMAIN   > opensearch-MY_DOMAIN.json
aws opensearch describe-domain-config --domain-name MY_DOMAIN > opensearch-MY_DOMAIN-config.json
aws opensearch list-vpc-endpoints            > opensearch-vpc-endpoints.json
```

**Identity, security, and secrets (names only — never values!):**

```bash
aws iam list-users                           > iam-users.json
aws iam list-roles                           > iam-roles.json
aws iam list-groups                          > iam-groups.json
aws iam list-policies --scope Local          > iam-custom-policies.json
aws iam get-policy-version --policy-arn ARN --version-id v1 > policy-ARN.json
aws iam get-account-authorization-details    > iam-everything.json  # the big one!
aws kms list-keys                            > kms-keys.json
aws kms list-aliases                         > kms-aliases.json
aws secretsmanager list-secrets              > secrets-names-only.json
aws ssm describe-parameters                  > ssm-parameter-names.json
```

**Storage and databases:**

```bash
aws s3api list-buckets                       > s3-buckets.json
aws s3api get-bucket-policy --bucket MY_BUCKET       > s3-MY_BUCKET-policy.json
aws s3api get-bucket-versioning --bucket MY_BUCKET   > s3-MY_BUCKET-versioning.json
aws s3api get-public-access-block --bucket MY_BUCKET > s3-MY_BUCKET-public.json
aws rds describe-db-instances                > rds-instances.json
aws rds describe-db-clusters                 > rds-clusters.json
aws dynamodb list-tables                     > dynamo-tables.json
aws elasticache describe-cache-clusters      > elasticache.json
```

**Analytics and data services:**

```bash
aws glue get-databases                       > glue-databases.json
aws glue get-jobs                            > glue-jobs.json
aws glue get-crawlers                        > glue-crawlers.json
aws athena list-work-groups                  > athena-workgroups.json
aws kinesis list-streams                     > kinesis-streams.json
aws emr list-clusters --active               > emr-clusters.json
aws states list-state-machines               > step-functions.json
```

**Monitoring and audit:**

```bash
aws cloudwatch describe-alarms               > cw-alarms.json
aws logs describe-log-groups                 > log-groups.json
aws events list-rules                        > eventbridge-rules.json
aws cloudtrail describe-trails               > cloudtrail-trails.json
aws configservice describe-configuration-recorders > config-recorders.json
aws sns list-topics                          > sns-topics.json
aws sqs list-queues                          > sqs-queues.json
```

**Handy `jq` trick — loop over things automatically instead of typing ARNs:**

```bash
# Describe EVERY MSK cluster without copy-pasting ARNs
for arn in $(aws kafka list-clusters-v2 --query 'ClusterInfoList[].ClusterArn' --output text); do
  safe=$(echo "$arn" | tr '/:' '__')
  aws kafka describe-cluster-v2 --cluster-arn "$arn" > "msk/detail-${safe}.json"
done

# Same idea for every OpenSearch domain
for d in $(aws opensearch list-domain-names --query 'DomainNames[].DomainName' --output text); do
  aws opensearch describe-domain --domain-name "$d" > "opensearch/${d}.json"
done
```

### 1.3 Exporting the Apps Themselves (Things AWS CLI Can't See)

**Kafka topics and configs** (from a machine that can reach the brokers):

```bash
BROKERS=$(aws kafka get-bootstrap-brokers --cluster-arn ARN \
          --query 'BootstrapBrokerStringSaslIam' --output text)

kafka-topics.sh --bootstrap-server "$BROKERS" --command-config client.properties \
  --list                                   > kafka/topics.txt
kafka-topics.sh --bootstrap-server "$BROKERS" --command-config client.properties \
  --describe                               > kafka/topics-detail.txt
kafka-configs.sh --bootstrap-server "$BROKERS" --command-config client.properties \
  --entity-type topics --describe --all    > kafka/topic-configs.txt
kafka-acls.sh --bootstrap-server "$BROKERS" --command-config client.properties \
  --list                                   > kafka/acls.txt
```

**NiFi** (REST API — get a token, then export the flow):

```bash
TOKEN=$(curl -sk -X POST "https://nifi.example.com/nifi-api/access/token" \
  -d "username=$NIFI_USER&password=$NIFI_PASS")

curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://nifi.example.com/nifi-api/flow/process-groups/root" \
  | jq -S . > nifi/root-flow.json

# Better long-term: use NiFi Registry — it versions flows natively and can back onto Git
```

**Keycloak** (admin CLI `kcadm.sh`, or full export):

```bash
# Full realm export (run on the Keycloak server; strip secrets after!)
/opt/keycloak/bin/kc.sh export --dir /tmp/kc-export --users skip

# Or targeted reads via the admin CLI:
kcadm.sh config credentials --server https://kc.example.com \
  --realm master --user admin --password "$KC_PASS"
kcadm.sh get realms                  > keycloak/realms.json
kcadm.sh get clients -r myrealm      > keycloak/myrealm-clients.json
kcadm.sh get roles   -r myrealm      > keycloak/myrealm-roles.json
kcadm.sh get groups  -r myrealm      > keycloak/myrealm-groups.json
```

**Databricks** (Databricks CLI):

```bash
pip install databricks-cli
databricks configure --token         # points at your workspace URL + a token

databricks clusters list --output JSON        > databricks/clusters.json
databricks jobs list --output JSON            > databricks/jobs.json
databricks cluster-policies list --output JSON > databricks/policies.json
databricks workspace ls / --output JSON       > databricks/workspace-root.json
databricks instance-pools list --output JSON  > databricks/pools.json
```

### 1.4 The Snapshot Script (Putting It All Together)

A trimmed real example of `scripts/snapshot.sh` — the pipeline runs this daily:

```bash
#!/usr/bin/env bash
set -euo pipefail

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGIONS="us-east-1 eu-west-1"

for REGION in $REGIONS; do
  export AWS_DEFAULT_REGION=$REGION
  OUT="inventory/$ACCOUNT/$REGION"
  mkdir -p "$OUT"/{ec2,msk,opensearch,iam,s3,network}

  # jq -S sorts keys; the 'del(...)' removes fields that change every run,
  # so Git diffs only show REAL changes
  aws ec2 describe-security-groups \
    | jq -S . > "$OUT/network/security-groups.json"

  aws ec2 describe-instances \
    | jq -S 'del(.Reservations[].Instances[].LaunchTime,
                 .Reservations[].Instances[].NetworkInterfaces[].Attachment.AttachTime)' \
    > "$OUT/ec2/instances.json"

  aws kafka list-clusters-v2 | jq -S . > "$OUT/msk/clusters.json"
  # ...add every command from section 1.2 here...
done

# Commit only if something actually changed
git add inventory/
if ! git diff --cached --quiet; then
  git commit -m "Daily snapshot $(date -u +%F)"
  git push origin main
fi
```

And the matching `.gitlab-ci.yml` in the `aws-inventory` repo:

```yaml
snapshot:
  image: amazon/aws-cli:latest
  rules:
    - if: '$CI_PIPELINE_SOURCE == "schedule"'   # only runs on the daily schedule
  id_tokens:
    AWS_ID_TOKEN:
      aud: https://gitlab.example.com           # OIDC: no stored AWS keys!
  before_script:
    - yum install -y jq git
    - >
      export $(aws sts assume-role-with-web-identity
      --role-arn $SNAPSHOT_ROLE_ARN
      --role-session-name gitlab-snapshot
      --web-identity-token $AWS_ID_TOKEN
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]'
      --output text | awk '{print "AWS_ACCESS_KEY_ID="$1, "AWS_SECRET_ACCESS_KEY="$2, "AWS_SESSION_TOKEN="$3}')
  script:
    - ./scripts/snapshot.sh
    - ./scripts/open-drift-issue.sh   # if git diff found changes, call the GitLab API to open an issue
```

Create the schedule in GitLab: **Build → Pipeline schedules → New schedule** → cron `0 6 * * *` (every day at 6 AM).

Opening the drift issue automatically is one API call:

```bash
# scripts/open-drift-issue.sh (simplified)
if [ -n "$(git log -1 --since=yesterday --oneline)" ]; then
  curl -s -X POST "https://gitlab.example.com/api/v4/projects/$CI_PROJECT_ID/issues" \
    -H "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
    --data-urlencode "title=Drift detected on $(date -u +%F)" \
    --data-urlencode "description=Unplanned changes found. See commit $CI_COMMIT_SHA. If you made this change, link your change-request issue." \
    --data "labels=drift-detected"
fi
```

### 1.5 Helper Tools Worth Knowing (Options + Pros/Cons)

| Option | What it is | Pros | Cons |
|---|---|---|---|
| **Plain AWS CLI scripts** | Hand-written describe commands | Simple, no new tools, full control | You must remember every service; easy to miss things |
| **AWS Config** | AWS's built-in change recorder | Records every change automatically with history; great audit trail | Costs money per item recorded; data lives in AWS, not Git (but you can export snapshots to S3 → Git) |
| **CloudTrail** | Logs every API call (who did what) | Answers "who changed it?" perfectly | It's a firehose of logs, not a neat inventory |
| **Steampipe** | Query AWS like a database (SQL) | Fast, thorough, exportable | New tool to learn |
| **former2 / terraformer** | Generate Terraform code from existing resources | Jump-starts Phase 2 | Generated code is messy; needs cleanup |

**Recommendation:** Use plain CLI scripts + turn on **AWS Config and CloudTrail** (they cover your blind spots). Keep Steampipe in your back pocket.

### 1.6 Phase 1 Deliverables
- ✅ `aws-inventory` repo with full JSON snapshots, updated daily.
- ✅ Auto-created `drift-detected` issues when something changes.
- ✅ A written list of **everything we own**, grouped by service — this becomes the Phase 2 to-do list.

### Pros and Cons of the Snapshot Approach
- ✅ Read-only — zero risk of breaking anything.
- ✅ Immediately gives visibility and change detection.
- ❌ It only *detects* changes; it can't *prevent* or *undo* them. That's Phase 2.
- ❌ Snapshots can miss things between runs (daily gap). CloudTrail fills that gap.

---

## Phase 2: Convert to Terraform and Ansible (Months 2–8)

**Goal:** Move from "photos of the house" to "blueprints of the house." The blueprints (code) become the source of truth. Changing the blueprint changes the house.

### 2.1 The Order of Attack (Easiest → Scariest)

Don't try to convert everything at once. Go in waves:

1. **Wave 1 — New stuff only:** From today, anything *new* must be built with Terraform/Ansible. No exceptions. This stops the hole from getting deeper.
2. **Wave 2 — Safe, boring things:** S3 buckets, Route53 DNS, IAM roles/policies, security groups. Low-risk imports, high value.
3. **Wave 3 — Data platform infrastructure:** MSK clusters, OpenSearch domains, Databricks workspaces, the EC2 fleet running NiFi/Keycloak.
4. **Wave 4 — App-level configuration:** Kafka topics and ACLs, NiFi flows, Keycloak realms/clients, OpenSearch index templates, Databricks jobs/cluster policies — via Terraform providers or Ansible playbooks.

### 2.2 How to "Import" Existing Resources into Terraform

Terraform can adopt things it didn't create. For each resource:

1. Write the Terraform code describing it (use your Phase 1 JSON as the cheat sheet).
2. Run `terraform import` (or use `import` blocks in modern Terraform) to link the code to the real resource. Example:

   ```hcl
   # In your .tf file (modern way — Terraform can even generate the config for you):
   import {
     to = aws_security_group.kafka_brokers
     id = "sg-0abc123def456"          # the real ID from your Phase 1 JSON
   }
   ```

   ```bash
   terraform plan -generate-config-out=generated.tf   # drafts the resource block
   # ...or the classic way:
   terraform import aws_security_group.kafka_brokers sg-0abc123def456
   ```

3. Run `terraform plan` — the goal is **"No changes."** That proves your code matches reality.
4. Open an issue per import batch (label: `import-task`), do the work in an MR, get it reviewed, merge.

**Tip:** Tools like `terraformer` can auto-generate a first draft, but always clean it up by hand — auto-generated code is like auto-translated text: understandable but ugly.

### 2.3 Terraform State — Handle With Care

Terraform's **state file** is its memory. If two people run Terraform at once, or the state is lost, bad things happen.

| State storage option | Pros | Cons |
|---|---|---|
| **S3 + DynamoDB lock** (classic) | Reliable, cheap, standard | You manage the bucket/table |
| **GitLab-managed Terraform state** | Built into GitLab, versioned, access-controlled, zero extra AWS setup | Ties state to GitLab availability |
| **Terraform Cloud** | Nice UI, policy features | Another vendor, another bill |

**Recommendation:** **GitLab-managed state** — keeps everything (code, issues, state, pipelines) in one place.

### 2.4 Repo and Environment Structure

- Separate **directories or workspaces** for `dev`, `staging`, `prod` — same code, different variables.
- Build reusable **modules** (e.g., a `kafka-cluster` module) so every environment is built the same way.
- **Prod applies require approval:** in GitLab, use protected environments so a human must click "approve" before `terraform apply` touches prod.

### 2.5 Ansible's Job in Phase 2

Put playbooks in `ansible-config` for things like:
- Installing and upgrading **NiFi**, managing its properties files.
- **Keycloak** realm/client/role configuration (or use the Terraform Keycloak provider — pick ONE tool per platform to avoid two tools fighting).
- Kafka broker tuning and **topic management**.
- OS patching baselines for any EC2 instances.

Use **dynamic inventory** (Ansible reads AWS tags to find servers) so the inventory never goes stale. Run playbooks from GitLab pipelines, not laptops.

### 2.6 The Change Workflow (Phase 2 Daily Life)

```
1. Someone opens a GitLab ISSUE: "Add Kafka topic 'billing-events', 12 partitions"
2. Engineer creates a BRANCH + MERGE REQUEST linked to the issue
3. Pipeline runs automatically: format check → validate → terraform plan
4. The PLAN output is posted on the MR ("this will create 1 topic")
5. A teammate REVIEWS and approves
6. MERGE → pipeline runs terraform apply (prod waits for manual approval)
7. Issue closes automatically ("Closes #123" in the MR)
```

Now the answer to "who changed it, when, and why?" is always: **look at the issue and the MR.** Forever. For free.

### Pros and Cons of Phase 2
- ✅ Changes become reviewable, repeatable, and reversible (`git revert`!).
- ✅ Disaster recovery improves massively — you can rebuild from code.
- ✅ New environments (a new dev sandbox) take hours, not weeks.
- ❌ Importing existing resources is slow, careful work. Budget real time for it.
- ❌ Team must learn Terraform/Ansible — plan training and pairing.
- ❌ During the transition, some things are code-managed and some aren't — keep the Phase 1 drift detection running to catch console changes.

---

## Phase 3: Automation, Pipelines, and Agents (Ongoing)

**Goal:** The robots do the routine work; humans do the thinking and approving.

### 3.1 GitLab CI/CD Pipeline Design

A standard pipeline for the Terraform repos:

```
Stages:  validate → security-scan → plan → approve → apply → verify
```

- **validate:** `terraform fmt -check`, `terraform validate`, `ansible-lint`.
- **security-scan:** tools like **tfsec/Trivy**, **Checkov** (catch "this S3 bucket is public!" before it happens), plus secret scanners (Gitleaks) so no passwords sneak into Git.
- **plan:** post the plan as an MR comment.
- **approve:** manual gate for staging/prod (GitLab protected environments).
- **apply:** run Terraform/Ansible.
- **verify:** smoke tests — can we reach Kafka? Does Keycloak answer? Is OpenSearch green?

**GitLab Runners:** run pipelines on runners inside our AWS account (on EC2 or EKS) so they can use **IAM roles instead of stored AWS keys**. Use GitLab's **OIDC federation with AWS** — short-lived credentials, nothing to leak.

### 3.2 Scheduled Automation (Set-and-Forget Robots)

| Robot | Schedule | What it does |
|---|---|---|
| **Drift detector** | Nightly | Runs `terraform plan` on everything; if plan isn't empty, opens a `drift-detected` issue with the diff |
| **Inventory snapshot** | Daily | The Phase 1 script keeps running as a safety net for anything not yet in Terraform |
| **Dependency updater** | Weekly | **Renovate bot** opens MRs to update Terraform provider/module versions |
| **Cost reporter** | Weekly | Posts cost changes (e.g., Infracost on MRs: "this change adds ~$240/month") |
| **Backup checker** | Daily | Verifies snapshots/exports exist for OpenSearch, Keycloak DB, NiFi flows |
| **Cert/secret expiry watcher** | Daily | Opens issues 30 days before certificates or credentials expire |

### 3.3 AI Agents (The Newer Frontier)

AI agents can take on chunks of this workflow. Introduce them in trust levels:

**Level 1 — Read-only helpers (start here, low risk):**
- An agent that reads a `drift-detected` issue, looks at CloudTrail, and comments: "This change was made by user X at 2:14 PM via the console; it modified security group Y."
- An agent that summarizes big Terraform plans in plain English on MRs.
- A chat assistant (e.g., GitLab Duo, or Claude wired to your repos) that answers "how is prod Kafka configured?" by reading the code.

**Level 2 — Draft writers (human always reviews):**
- Agent reads a well-written issue ("add OpenSearch index template for app logs") and **opens a draft MR** with the Terraform/Ansible change. A human reviews, edits, and approves. The human approval gate never goes away.
- Agent triages incoming issues: adds labels, flags missing info ("you didn't specify an environment"), suggests risk level.

**Level 3 — Trusted fixers (only after Levels 1–2 prove reliable):**
- Auto-remediation for a *pre-approved allowlist* of drift (e.g., "if someone opens port 22 to the world, revert it immediately and open an incident issue").
- Auto-merge of low-risk bot MRs (provider patch versions) when all checks pass.

**Agent safety rules (non-negotiable):**
- Agents get their own service accounts with **least-privilege** access — never admin.
- Agents **never apply to prod without a human approval** in the pipeline.
- Every agent action is logged in an issue or MR comment — agents follow the Golden Rule too.

### 3.4 Pros and Cons of Heavy Automation
- ✅ Faster changes, fewer 3 AM mistakes, perfect paper trail.
- ✅ Engineers spend time on design instead of typing.
- ❌ Pipelines and runners are themselves infrastructure — someone must own and maintain them.
- ❌ Over-trusting agents too early can automate mistakes at high speed. That's why the trust levels exist.

---

## 4. Roles, Habits, and Success Measures

**Roles:**
- **Platform lead:** owns the roadmap and the repo structure.
- **Every engineer:** follows the Golden Rule; reviews teammates' MRs.
- **Security:** reviews IAM/Keycloak changes; owns the scan rules.

**Success measures (check quarterly):**
- % of infrastructure managed by Terraform (target: 90%+ by end of Phase 2).
- Number of unexplained drift issues per month (target: trending to ~0).
- Time from issue opened → change live (should *drop* as automation grows).
- Every prod change traceable to an issue (target: 100%).

**Risks to watch:**
- **Console cowboys** — people bypassing the process. Fix with drift detection + read-only console access for most people in prod (eventually).
- **State file accidents** — fix with GitLab-managed state, locking, and backups.
- **Secrets in Git** — fix with secret scanning in every pipeline and using AWS Secrets Manager / Vault, never files.

---

## 5. One-Page Summary

| Phase | Nickname | Main tool | Outcome |
|---|---|---|---|
| 0 | Get organized | GitLab issues/repos | Filing cabinet + Golden Rule |
| 1 | Take the photo | AWS CLI → JSON | Full inventory in Git, daily drift alerts |
| 2 | Draw the blueprints | Terraform + Ansible | Code is the source of truth; changes via MRs |
| 3 | Hire the robots | GitLab CI/CD + agents | Automated plans, applies, drift fixes, AI-drafted changes with human approval |

> **The whole plan in one sentence:** First we *see* everything (CLI snapshots), then we *control* everything (Terraform/Ansible through GitLab), then we *automate* everything (pipelines and agents) — and at every step, the GitLab issue is the permission slip and the merge request is the receipt.
