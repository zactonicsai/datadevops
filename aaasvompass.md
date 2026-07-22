# How to Compare Your Terraform Code to What's Really on AWS
### A Step-by-Step Guide for Data Analytics & Cloud Teams

---

## Table of Contents
1. [Background: What Are We Even Doing?](#background)
2. [Key Words You Need to Know](#key-words)
3. [Quick Start: One Full Example (Do This First)](#quick-start)
4. [The Full Step-by-Step Process](#full-process)
5. [Common Resources a Data Team Uses (Checklist)](#common-resources)
6. [OpenSearch + ETL Configuration Deep Dive](#opensearch)
7. [Best Practices](#best-practices)
8. [Pros and Cons of Each Method](#pros-cons)
9. [Troubleshooting](#troubleshooting)

---

<a name="background"></a>
## 1. Background: What Are We Even Doing?

Imagine you have a **blueprint** for a house (that's your Terraform code). It says "3 bedrooms, 2 bathrooms, a blue door."

Now imagine someone actually built the house (that's your **real AWS infrastructure**). But over time, people made changes without updating the blueprint. Maybe someone painted the door red. Maybe someone added a room by hand.

Our job is to walk through the real house with the blueprint and make a list:
- ✅ Things that match
- ⚠️ Things that are different
- ❓ Things that exist in real life but aren't on the blueprint (called **drift**)

The end result is a **"current status" report** of your whole system.

### Why does this matter?
- **Terraform** is a tool that lets you write down your cloud setup as text files (this is called "Infrastructure as Code").
- When real AWS doesn't match your code, bad things happen: surprise costs, security holes, and broken deployments.
- Finding these differences is called **drift detection**.

---

<a name="key-words"></a>
## 2. Key Words You Need to Know

| Word | Simple Meaning |
|------|----------------|
| **Terraform** | A tool that writes your cloud setup as text files you can save and share. |
| **State file** | Terraform's "memory." A file (`terraform.tfstate`) that records what Terraform *thinks* it built. |
| **Drift** | When the real AWS setup is different from what the code/state says. |
| **Resource** | One single thing in the cloud (like one database, one bucket, one server). |
| **Provider** | The plugin that lets Terraform talk to AWS. |
| **Plan** | A "preview" of changes Terraform wants to make. Great for spotting drift. |
| **Apply** | Actually making the changes real. |
| **ETL** | **E**xtract, **T**ransform, **L**oad — the process of grabbing data, cleaning it, and storing it. |
| **OpenSearch** | An AWS search-and-analytics engine (a fork of Elasticsearch) used to search logs and data fast. |

---

<a name="quick-start"></a>
## 3. Quick Start: One Full Example (Do This First)

Let's do **one complete example** from start to finish so you see the whole flow. We'll check a single S3 bucket (a storage container).

### Step 1: Install the tools
```bash
# Check if Terraform is installed
terraform -version

# Check if the AWS CLI is installed
aws --version
```
If either is missing, install Terraform from the HashiCorp website and the AWS CLI from Amazon's website.

### Step 2: Log in to AWS
```bash
aws configure
# It will ask for:
#   AWS Access Key ID
#   AWS Secret Access Key
#   Default region (like us-east-1)
#   Output format (just type: json)
```

### Step 3: Go to your Terraform folder
```bash
cd /path/to/your/terraform-project
terraform init      # Downloads the AWS plugin. Run this once.
```

### Step 4: Refresh and see the differences (the magic step)
```bash
terraform plan -refresh-only
```
`-refresh-only` tells Terraform: *"Don't change anything. Just look at real AWS and tell me what's different from your memory."*

**What you'll see:** Terraform prints out any resource where reality doesn't match. For example:
```
~ aws_s3_bucket.analytics_data
    ~ versioning = "Enabled" -> "Suspended"
```
This means: someone turned OFF versioning on your bucket in real life, but your code still says it should be ON. **That's drift!**

### Step 5: Double-check with the AWS CLI (trust but verify)
```bash
aws s3api get-bucket-versioning --bucket analytics-data-bucket
```
This asks AWS directly. Now you've confirmed the drift with your own eyes.

### Step 6: Write it down
Add a line to your status report:

> **S3 bucket `analytics-data-bucket`**: ⚠️ Drift found. Versioning is OFF in AWS but code expects ON. Needs review.

**That's the whole loop.** Now you just repeat it for every resource. The rest of this guide shows you how to do it at scale and what resources to look for.

---

<a name="full-process"></a>
## 4. The Full Step-by-Step Process

Here is the complete, repeatable process for your whole system.

### Phase A — Get Organized
1. **Find all your Terraform code.** Look for folders with `.tf` files. There may be several (one per environment: dev, staging, prod).
2. **Find your state files.** These are usually stored remotely in an S3 bucket (with a DynamoDB table for locking). Check your `backend` block in the `.tf` files to see where.
3. **Make sure you have read access to AWS** for the accounts and regions you're reviewing.

### Phase B — Take a Snapshot of the Code Side
4. **List everything Terraform manages:**
   ```bash
   terraform state list
   ```
   This prints every resource Terraform knows about. Save it:
   ```bash
   terraform state list > terraform-managed.txt
   ```
5. **See the details of any single resource:**
   ```bash
   terraform state show aws_s3_bucket.analytics_data
   ```

### Phase C — Detect Drift (Code vs. Reality)
6. **Run the refresh-only plan** (the safe, read-only check):
   ```bash
   terraform plan -refresh-only -out=drift.tfplan
   ```
7. **Save the output as readable text:**
   ```bash
   terraform show -no-color drift.tfplan > drift-report.txt
   ```
8. Read `drift-report.txt`. Anything with a `~` (changed) or `-` (would be destroyed) is drift.

### Phase D — Find "Unmanaged" Resources (Reality vs. Code)
This is the tricky part: things that exist on AWS but are **not in Terraform at all**.

9. **List real AWS resources** using the CLI and compare against `terraform-managed.txt`. Example for S3:
   ```bash
   aws s3api list-buckets --query "Buckets[].Name" --output text
   ```
10. **Compare the two lists.** Anything on AWS but NOT in your Terraform list is **unmanaged** — a big red flag. (Tools like `driftctl` or AWS Config can automate this — see Best Practices.)

### Phase E — Build the Status Report
11. For each resource, mark it:
    - ✅ **In sync** — code and reality match.
    - ⚠️ **Drifted** — managed by Terraform but changed in AWS.
    - ❓ **Unmanaged** — exists in AWS, not in Terraform.
    - 🗑️ **Ghost** — in Terraform/state but deleted from AWS.
12. Save it in a simple table (see the checklist below).

### Phase F — Decide What To Do
13. For each issue, pick one:
    - **Fix reality:** run `terraform apply` to make AWS match the code.
    - **Fix the code:** update your `.tf` files to match reality (then `apply`).
    - **Import it:** if it's unmanaged, bring it into Terraform with `terraform import`.
    - **Leave a note:** document it as a known exception.

---

<a name="common-resources"></a>
## 5. Common Resources a Data Analytics & Cloud Team Uses (Checklist)

Below are the AWS resources a data team almost always has. Use this as your review checklist. For each one, the CLI command shows you how to check the real AWS side.

### Storage
| Resource | What It Does | Check Command |
|----------|--------------|---------------|
| **S3 Bucket** | Stores raw and processed data (your "data lake"). | `aws s3api list-buckets` |
| **EBS Volume** | Hard drives attached to servers. | `aws ec2 describe-volumes` |

### Databases & Warehouses
| Resource | What It Does | Check Command |
|----------|--------------|---------------|
| **RDS** | Managed SQL databases (Postgres, MySQL). | `aws rds describe-db-instances` |
| **Redshift** | Big data warehouse for analytics. | `aws redshift describe-clusters` |
| **DynamoDB** | Fast NoSQL key-value tables. | `aws dynamodb list-tables` |

### Data Processing / ETL
| Resource | What It Does | Check Command |
|----------|--------------|---------------|
| **Glue Job** | Serverless ETL (clean & move data). | `aws glue get-jobs` |
| **Glue Crawler** | Scans data and builds a catalog. | `aws glue get-crawlers` |
| **Lambda** | Small functions that run code on demand. | `aws lambda list-functions` |
| **Step Functions** | Chains multiple steps into a workflow. | `aws stepfunctions list-state-machines` |
| **EMR** | Big Spark/Hadoop clusters. | `aws emr list-clusters` |
| **Kinesis / MSK** | Streaming data pipelines. | `aws kinesis list-streams` |

### Search & Analytics
| Resource | What It Does | Check Command |
|----------|--------------|---------------|
| **OpenSearch** | Search & analyze logs/data fast. | `aws opensearch list-domain-names` |
| **Athena** | Run SQL directly on S3 files. | `aws athena list-work-groups` |
| **QuickSight** | Dashboards and charts. | (console-based, limited CLI) |

### Networking & Security
| Resource | What It Does | Check Command |
|----------|--------------|---------------|
| **VPC** | Your private network. | `aws ec2 describe-vpcs` |
| **Subnets** | Sections of your network. | `aws ec2 describe-subnets` |
| **Security Groups** | Firewalls for resources. | `aws ec2 describe-security-groups` |
| **IAM Roles** | Permissions ("who can do what"). | `aws iam list-roles` |
| **KMS Keys** | Encryption keys. | `aws kms list-keys` |

### Compute & Orchestration
| Resource | What It Does | Check Command |
|----------|--------------|---------------|
| **EC2** | Virtual servers. | `aws ec2 describe-instances` |
| **ECS/EKS** | Run containers. | `aws ecs list-clusters` |
| **MWAA (Airflow)** | Schedule and manage data pipelines. | `aws mwaa list-environments` |

---

<a name="opensearch"></a>
## 6. OpenSearch + ETL Configuration Deep Dive

This is a very common setup for a data team: **logs and data flow through an ETL pipeline and land in OpenSearch so people can search and build dashboards.**

### The Big Picture (how data flows)
```
Data Sources  →  Kinesis/Firehose  →  Lambda or Glue (Transform)  →  OpenSearch  →  Dashboards
   (Extract)         (Stream)              (Transform)                 (Load)         (Analyze)
```

### Example Terraform for an OpenSearch Domain
Here's simple Terraform code that creates an OpenSearch domain. Review your real code against something like this.

```hcl
resource "aws_opensearch_domain" "analytics" {
  domain_name    = "team-analytics"
  engine_version = "OpenSearch_2.11"   # Always check for the latest supported version

  cluster_config {
    instance_type          = "r6g.large.search"
    instance_count         = 3
    zone_awareness_enabled = true       # Spreads across zones for safety
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 100                   # GB of storage
    volume_type = "gp3"
  }

  encrypt_at_rest {
    enabled = true                      # Best practice: always encrypt
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https = true                # Best practice: force HTTPS
  }
}
```

### How to Check the Real OpenSearch Domain
```bash
# 1. List all domains
aws opensearch list-domain-names

# 2. Get full details of one domain
aws opensearch describe-domain --domain-name team-analytics
```
Now compare the JSON output to your Terraform:
- Does `EngineVersion` match `engine_version`?
- Does `InstanceCount` match `instance_count`?
- Is encryption actually ON?

### The ETL Piece: Firehose → OpenSearch
A common ETL pattern uses **Kinesis Firehose** to load data into OpenSearch. Simple Terraform:

```hcl
resource "aws_kinesis_firehose_delivery_stream" "to_opensearch" {
  name        = "logs-to-opensearch"
  destination = "opensearch"

  opensearch_configuration {
    domain_arn = aws_opensearch_domain.analytics.arn
    role_arn   = aws_iam_role.firehose_role.arn
    index_name = "app-logs"

    # This Lambda does the "Transform" step (cleans the data)
    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = aws_lambda_function.transform.arn
        }
      }
    }
  }
}
```

### Check the Real Firehose
```bash
aws firehose list-delivery-streams
aws firehose describe-delivery-stream --delivery-stream-name logs-to-opensearch
```
Verify:
- Is the `index_name` the same?
- Is the Lambda transform still attached?
- Does the destination ARN point to the right OpenSearch domain?

### Common OpenSearch Drift to Watch For
- Someone bumped `instance_count` up to handle load → higher cost, not in code.
- Access policy changed by hand → security risk.
- Storage (`volume_size`) increased manually.
- Engine version auto-upgraded by AWS.

---

<a name="best-practices"></a>
## 7. Best Practices

1. **Never edit AWS by hand ("ClickOps").** Always change things through Terraform so code and reality stay in sync.
2. **Store state remotely.** Use an S3 backend with DynamoDB locking so your team shares one source of truth.
3. **Run drift checks on a schedule.** Set up a nightly job that runs `terraform plan -refresh-only` and alerts you if anything drifted.
4. **Use automated drift tools:**
   - **`driftctl`** — scans AWS and finds unmanaged resources.
   - **AWS Config** — records every change and can flag non-compliance.
   - **Terraform Cloud/Enterprise** — has built-in drift detection.
5. **Tag everything.** Add tags like `managed-by = terraform` so you can instantly tell what's supposed to be code-managed.
6. **Review in read-only first.** Always use `-refresh-only` and `plan` before any `apply`.
7. **Encrypt everything** (S3, RDS, OpenSearch, EBS) and enforce HTTPS.
8. **Keep one resource per change when importing** so you don't break things.

---

<a name="pros-cons"></a>
## 8. Pros and Cons of Each Method

### Method 1: `terraform plan -refresh-only`
**Pros:** Built-in, free, safe (read-only), shows exact differences.
**Cons:** Only finds drift in resources Terraform already manages — it **won't** find unmanaged/"ghost" resources.

### Method 2: AWS CLI manual checks
**Pros:** Direct truth from AWS, great for confirming a single resource.
**Cons:** Slow and tedious for a whole system; easy to miss things.

### Method 3: `driftctl` (or similar tools)
**Pros:** Finds BOTH drift *and* unmanaged resources; gives a coverage percentage.
**Cons:** Extra tool to install/learn; may have gaps for newer AWS services.

### Method 4: AWS Config
**Pros:** Continuous, records history, great for audits and compliance.
**Cons:** Costs money; setup is more involved; not Terraform-aware by itself.

### Method 5: Terraform Cloud/Enterprise drift detection
**Pros:** Automatic, scheduled, nice UI, alerts built in.
**Cons:** Paid product; requires moving your workflow into their platform.

**Recommended combo for a data team:** Use `terraform plan -refresh-only` for managed drift + `driftctl` for unmanaged resources + AWS CLI to spot-check tricky items like OpenSearch.

---

<a name="troubleshooting"></a>
## 9. Troubleshooting

| Problem | Likely Cause | Fix |
|---------|--------------|-----|
| `terraform plan` shows huge changes on first run | State is stale or you're in the wrong workspace | Run `terraform init` and check `terraform workspace show` |
| "Error acquiring the state lock" | Someone else is running Terraform | Wait, or force-unlock only if you're sure it's safe |
| CLI says "Access Denied" | Your IAM user lacks read permissions | Ask for `ReadOnlyAccess` policy for the review |
| Resource in AWS but not in `state list` | It's unmanaged | Use `terraform import` to adopt it, or document it |
| OpenSearch version differs from code | AWS auto-upgraded the engine | Update `engine_version` in code to match |
| Numbers keep drifting back | Auto-scaling or a script is changing them | Move that setting out of Terraform or manage the scaler in code |

---

## Final Checklist (Print This)

- [ ] Terraform and AWS CLI installed and logged in
- [ ] Found all `.tf` folders and state files
- [ ] Ran `terraform state list` → saved managed resource list
- [ ] Ran `terraform plan -refresh-only` → saved drift report
- [ ] Listed real AWS resources per service → found unmanaged ones
- [ ] Checked OpenSearch + ETL (Firehose/Glue/Lambda) specifically
- [ ] Built status table (✅ / ⚠️ / ❓ / 🗑️ for each resource)
- [ ] Decided fix vs. import vs. document for each issue
- [ ] Scheduled a recurring drift check going forward

**You now have a complete, current status of your system.** 🎉
