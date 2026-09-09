# Automating Grafana Dashboards for AWS Resources with Terraform

A step-by-step tutorial. We start with one complete example (an EC2 app that gets its own Grafana dashboard and alert the moment `terraform apply` runs), then cover the background, the Grafana API, costs, and how to extend the pattern to every AWS service.

---

## Part 1 — Step-by-step: one EC2 app, one auto-created dashboard

### What we're building

```
terraform apply
   │
   ├─► AWS:      EC2 instance (tagged App=payments, Env=prod)
   │             + CloudWatch agent installed via user_data
   │
   └─► Grafana:  Folder "prod"
                 + Dashboard "payments (i-0abc123)"
                 + Alert rule "payments CPU > 80%"
```

Destroy the instance and the dashboard and alert disappear too. Nothing is clicked in the Grafana UI.

### Step 1 — Give Grafana permission to read CloudWatch

Grafana needs an IAM role. Attach this policy to the role Grafana runs under (EC2 instance profile, EKS IRSA, or an IAM user with keys as a last resort).

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:DescribeAlarmsForMetric",
        "logs:DescribeLogGroups",
        "logs:StartQuery",
        "logs:GetQueryResults",
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "tag:GetResources"
      ],
      "Resource": "*"
    }
  ]
}
```

### Step 2 — Create a Grafana service account token

In Grafana: **Administration → Service accounts → Add service account** (role: Editor or Admin) → **Add token**. Copy the token. Store it as `TF_VAR_grafana_token` or in your secrets manager, never in git.

### Step 3 — Terraform: providers

`providers.tf`

```hcl
terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    grafana = { source = "grafana/grafana", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags {                 # every resource gets these automatically
    tags = {
      Env       = var.env
      ManagedBy = "terraform"
    }
  }
}

provider "grafana" {
  url  = var.grafana_url         # e.g. https://grafana.example.com
  auth = var.grafana_token       # service-account token
}

variable "region"        { default = "us-east-1" }
variable "env"           { default = "prod" }
variable "grafana_url"   {}
variable "grafana_token" { sensitive = true }
```

### Step 4 — Terraform: the CloudWatch data source (once per Grafana)

`grafana-datasource.tf`

```hcl
resource "grafana_data_source" "cloudwatch" {
  type = "cloudwatch"
  name = "CloudWatch"
  uid  = "cloudwatch"            # fixed uid so dashboards can reference it

  json_data_encoded = jsonencode({
    authType      = "default"    # uses the IAM role Grafana runs with
    defaultRegion = var.region
  })
}

resource "grafana_folder" "env" {
  title = var.env
}
```

### Step 5 — Terraform: the EC2 instance with the CloudWatch agent

`ec2.tf`

```hcl
locals {
  app_name = "payments"
}

# Instance profile so the agent can push metrics
resource "aws_iam_role" "app" {
  name = "${local.app_name}-ec2"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.app_name}-ec2"
  role = aws_iam_role.app.name
}

resource "aws_instance" "app" {
  ami                  = data.aws_ami.al2023.id
  instance_type        = "t3.small"
  iam_instance_profile = aws_iam_instance_profile.app.name
  monitoring           = true     # 1-minute metrics instead of 5-minute

  tags = { Name = local.app_name, App = local.app_name }

  user_data = templatefile("${path.module}/user_data.sh", {
    app_name = local.app_name
    env      = var.env
  })
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
```

`user_data.sh` — installs the agent so we get memory and disk usage (EC2 alone doesn't provide those):

```bash
#!/bin/bash
dnf install -y amazon-cloudwatch-agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/config.json <<'CFG'
{
  "metrics": {
    "namespace": "App/${app_name}",
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" },
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/"] }
    }
  }
}
CFG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json -s
```

### Step 6 — Terraform: the dashboard from a JSON template

`grafana-dashboard.tf`

```hcl
resource "grafana_dashboard" "app" {
  folder    = grafana_folder.env.id
  overwrite = true

  config_json = templatefile("${path.module}/dashboards/ec2-app.json.tftpl", {
    app_name       = local.app_name
    instance_id    = aws_instance.app.id
    region         = var.region
    datasource_uid = grafana_data_source.cloudwatch.uid
  })
}
```

`dashboards/ec2-app.json.tftpl` — a minimal 2-panel dashboard. Placeholders are `${...}`:

```json
{
  "uid": "ec2-${app_name}",
  "title": "${app_name} (${instance_id})",
  "tags": ["ec2", "${app_name}", "terraform"],
  "timezone": "browser",
  "schemaVersion": 39,
  "refresh": "1m",
  "time": { "from": "now-6h", "to": "now" },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "CPU %",
      "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
      "datasource": { "type": "cloudwatch", "uid": "${datasource_uid}" },
      "targets": [{
        "refId": "A",
        "region": "${region}",
        "namespace": "AWS/EC2",
        "metricName": "CPUUtilization",
        "statistic": "Average",
        "period": "60",
        "dimensions": { "InstanceId": "${instance_id}" }
      }]
    },
    {
      "id": 2,
      "type": "timeseries",
      "title": "Memory %",
      "gridPos": { "x": 12, "y": 0, "w": 12, "h": 8 },
      "datasource": { "type": "cloudwatch", "uid": "${datasource_uid}" },
      "targets": [{
        "refId": "A",
        "region": "${region}",
        "namespace": "App/${app_name}",
        "metricName": "mem_used_percent",
        "statistic": "Average",
        "period": "60",
        "dimensions": { "InstanceId": "${instance_id}" }
      }]
    }
  ]
}
```

### Step 7 — Terraform: an alert that ships with the app

`grafana-alerts.tf`

```hcl
resource "grafana_contact_point" "slack" {
  name = "slack-${var.env}"
  slack {
    url = var.slack_webhook
  }
}

resource "grafana_rule_group" "app" {
  name             = "${local.app_name}-rules"
  folder_uid       = grafana_folder.env.uid
  interval_seconds = 60

  rule {
    name      = "${local.app_name} CPU high"
    condition = "C"
    for       = "5m"
    labels    = { severity = "warning", app = local.app_name }
    annotations = { summary = "CPU > 80% on ${aws_instance.app.id}" }
    notification_settings { contact_point = grafana_contact_point.slack.name }

    data {
      ref_id = "A"
      relative_time_range { from = 600, to = 0 }
      datasource_uid = grafana_data_source.cloudwatch.uid
      model = jsonencode({
        region     = var.region
        namespace  = "AWS/EC2"
        metricName = "CPUUtilization"
        statistic  = "Average"
        period     = "60"
        dimensions = { InstanceId = aws_instance.app.id }
      })
    }
    data {
      ref_id = "B"
      relative_time_range { from = 0, to = 0 }
      datasource_uid = "__expr__"
      model = jsonencode({ type = "reduce", expression = "A", reducer = "last" })
    }
    data {
      ref_id = "C"
      relative_time_range { from = 0, to = 0 }
      datasource_uid = "__expr__"
      model = jsonencode({
        type = "threshold", expression = "B",
        conditions = [{ evaluator = { type = "gt", params = [80] } }]
      })
    }
  }
}

variable "slack_webhook" { sensitive = true }
```

### Step 8 — Run it

```bash
export TF_VAR_grafana_url=https://grafana.example.com
export TF_VAR_grafana_token=glsa_xxxxxxxx
export TF_VAR_slack_webhook=https://hooks.slack.com/...
terraform init
terraform plan
terraform apply
```

Open Grafana → folder **prod** → dashboard **payments (i-…)**. Memory appears after the agent's first push (about 1–2 minutes).

---

## Part 2 — Background: how it actually works

### The three pieces

| Piece | Job | Where it lives |
|---|---|---|
| **CloudWatch** | AWS's metric store. Every AWS service emits metrics here for free (EC2, RDS, ALB, Lambda…). Custom metrics (memory, app counters) cost money. | AWS |
| **Grafana data source** | A saved connection telling Grafana "query CloudWatch in region X using role Y." Created once. | Grafana |
| **Dashboard JSON** | A JSON document describing panels and their queries. Grafana stores it in its database; anything can POST it via the API. | Grafana |

Grafana never "adds an instance." It runs a query every refresh: *"give me CPUUtilization where InstanceId = i-0abc."* So automating means automating the **query text** and pushing it through the API — which is exactly what the Terraform provider does under the hood.

### What the Terraform provider is doing behind the scenes

```
terraform apply
  └─ grafana_dashboard resource
       └─ POST https://grafana/api/dashboards/db
            Authorization: Bearer <service-account token>
            Body: { "dashboard": {...json...}, "folderUid": "...", "overwrite": true }
```

Terraform stores the returned `uid` and `version` in state so it can update or delete later.

---

## Part 3 — Process flow: generating dashboard JSON and using the Grafana API

### Flow A — Design in the UI, export, template it (most common)

```
1. Build the dashboard by hand in Grafana once
2. Dashboard settings → JSON Model → copy
3. Strip "id" (keep "uid"), delete "version"
4. Replace hard-coded values with ${placeholders}
5. Save as dashboards/<service>.json.tftpl
6. Reference from grafana_dashboard + templatefile()
```

Or pull it with the API instead of copying:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$GRAFANA_URL/api/dashboards/uid/ec2-payments" | jq '.dashboard' > ec2-app.json
```

### Flow B — Start from a community dashboard

```bash
# Example: grafana.com dashboard id 617 (AWS EC2). Check the site for current IDs.
curl -s https://grafana.com/api/dashboards/617/revisions/latest/download > ec2-community.json
```

Community JSON uses `${DS_CLOUDWATCH}` input placeholders. Replace them with your datasource uid before importing.

### Flow C — Generate JSON with code (no hand-editing)

For many similar dashboards, generate JSON from a small program instead of maintaining templates:

- **Grafonnet** (Jsonnet library, official) — `jsonnet -J vendor dash.jsonnet > dash.json`
- **grafanalib** (Python) — `generate-dashboard -o out.json dash.dashboard.py`
- **Grizzly** (`grr`) — Grafana's CLI that applies Jsonnet/YAML/JSON to Grafana like `kubectl apply`

Terraform can still own the upload: `config_json = file("generated/dash.json")`.

### Grafana API cheat sheet

| Task | Method & path |
|---|---|
| Create/update dashboard | `POST /api/dashboards/db` |
| Get dashboard | `GET /api/dashboards/uid/{uid}` |
| Delete dashboard | `DELETE /api/dashboards/uid/{uid}` |
| Search dashboards | `GET /api/search?query=payments` |
| Create data source | `POST /api/datasources` |
| Create folder | `POST /api/folders` |
| Alert rules | `POST /api/v1/provisioning/alert-rules` |
| Contact points | `POST /api/v1/provisioning/contact-points` |
| Export alert rules as Terraform | `GET /api/v1/provisioning/alert-rules/export?format=hcl` |

Manual import example (what Terraform does for you):

```bash
jq -n --slurpfile d ec2-app.json \
  '{dashboard: $d[0], folderUid: "prod", overwrite: true}' | \
curl -s -X POST "$GRAFANA_URL/api/dashboards/db" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d @-
```

### Alternative to the API: file provisioning

If you run Grafana yourself, drop JSON in a folder and point Grafana at it. No API calls; Grafana re-reads every 10 s.

`/etc/grafana/provisioning/dashboards/aws.yaml`
```yaml
apiVersion: 1
providers:
  - name: aws
    folder: prod
    type: file
    options:
      path: /var/lib/grafana/dashboards/aws
```

Terraform can write the file with `local_file` or upload to S3 that a sidecar syncs. Good for Kubernetes (ConfigMap + sidecar), worse for Grafana Cloud (no filesystem).

---

## Part 4 — The scalable pattern: one dashboard, tag-driven variables

Per-instance dashboards are fine for a handful of apps. For fleets, make **one** dashboard whose queries are driven by variables that CloudWatch fills in from tags. New instances appear with **zero Grafana changes** — you only need to tag correctly (which `default_tags` guarantees).

Dashboard variables (`templating.list` in the JSON):

```json
"templating": {
  "list": [
    {
      "name": "app", "type": "query", "multi": false, "includeAll": false,
      "datasource": { "type": "cloudwatch", "uid": "cloudwatch" },
      "query": {
        "queryType": "dimensionValues",
        "region": "us-east-1",
        "namespace": "AWS/EC2",
        "metricName": "CPUUtilization",
        "dimensionKey": "InstanceId"
      },
      "refresh": 2
    }
  ]
}
```

Better: use a **resource query by tag** so the dropdown shows app names, not instance IDs:

```json
{
  "name": "instances", "type": "query", "multi": true, "includeAll": true,
  "datasource": { "type": "cloudwatch", "uid": "cloudwatch" },
  "query": {
    "queryType": "ec2InstanceAttribute",
    "region": "us-east-1",
    "attributeName": "InstanceId",
    "filters": { "tag:App": ["$app"], "tag:Env": ["prod"] }
  },
  "refresh": 2
}
```

Panel query then uses `"dimensions": { "InstanceId": "$instances" }`. Use `"matchExact": false` and Metric Search with `"expression": "SEARCH('{AWS/EC2,InstanceId} MetricName=\"CPUUtilization\"', 'Average', 60)"` if you want every instance in the account regardless of tags.

---

## Part 5 — Extending to every AWS service created by Terraform

### Pattern: a `grafana-<service>` module called from each service module

Directory layout:

```
modules/
  ec2-app/          → creates instance, calls modules/observability/ec2
  rds/              → creates db,       calls modules/observability/rds
  alb/              → creates lb,       calls modules/observability/alb
  observability/
    ec2/   main.tf + dashboard.json.tftpl + alerts.tf
    rds/   main.tf + dashboard.json.tftpl + alerts.tf
    alb/   ...
    lambda/ ...
```

`modules/observability/rds/main.tf`

```hcl
variable "db_identifier" {}
variable "env"           {}
variable "folder_id"     {}
variable "datasource_uid" {}
variable "region"        {}

resource "grafana_dashboard" "rds" {
  folder    = var.folder_id
  overwrite = true
  config_json = templatefile("${path.module}/dashboard.json.tftpl", {
    db_identifier  = var.db_identifier
    region         = var.region
    datasource_uid = var.datasource_uid
  })
}
```

Called from the RDS module:

```hcl
module "rds_dashboard" {
  source         = "../observability/rds"
  db_identifier  = aws_db_instance.this.identifier
  env            = var.env
  folder_id      = var.grafana_folder_id
  datasource_uid = "cloudwatch"
  region         = var.region
}
```

Key CloudWatch namespaces and dimensions per service:

| Service | Namespace | Dimension | Starter metrics |
|---|---|---|---|
| EC2 | `AWS/EC2` | `InstanceId` | CPUUtilization, NetworkIn/Out, StatusCheckFailed |
| RDS | `AWS/RDS` | `DBInstanceIdentifier` | CPUUtilization, DatabaseConnections, FreeStorageSpace, ReadLatency |
| ALB | `AWS/ApplicationELB` | `LoadBalancer` (arn suffix) | RequestCount, TargetResponseTime, HTTPCode_Target_5XX_Count |
| Lambda | `AWS/Lambda` | `FunctionName` | Invocations, Errors, Duration, Throttles |
| SQS | `AWS/SQS` | `QueueName` | ApproximateNumberOfMessagesVisible, ApproximateAgeOfOldestMessage |
| ECS | `AWS/ECS` | `ClusterName`,`ServiceName` | CPUUtilization, MemoryUtilization |
| DynamoDB | `AWS/DynamoDB` | `TableName` | ConsumedRead/WriteCapacityUnits, ThrottledRequests |

### Other automation to add

1. **`default_tags` on the AWS provider** — the foundation for tag-driven dashboards. Add `App`, `Env`, `Team`, `Owner`.
2. **Baseline alerts per service type** — put `grafana_rule_group` in each observability module so nothing ships without CPU/error/latency alerts.
3. **Folders and permissions** — `grafana_folder` per env/team + `grafana_folder_permission` so teams see only their stuff.
4. **Team and contact-point routing** — `grafana_notification_policy` matches `team=` label to the right Slack channel/PagerDuty.
5. **CI checks** — in the PR pipeline: `terraform validate`, `tflint`, and a custom check that every `aws_instance`/`aws_db_instance` has a matching observability module call.
6. **Dashboard linting** — `dashboard-linter lint dashboard.json` catches missing datasource uids and bad panel configs.
7. **Drift detection** — nightly `terraform plan` job that alerts if someone edited a dashboard in the UI (`overwrite = true` will revert it on next apply).
8. **Grafana Cloud AWS integration** — if you use Grafana Cloud, its CloudWatch scraper discovers resources by tag/account and ships pre-built dashboards. Least code, but it double-bills (CloudWatch API + Grafana Cloud series).
9. **Prometheus instead of CloudWatch for app metrics** — node_exporter + a Prometheus/Mimir target with `ec2_sd_configs` auto-discovers instances by tag. Cheaper at scale, richer metrics, one more thing to run.
10. **Log correlation** — add a CloudWatch Logs Insights panel per dashboard filtered by `@logStream like /${instance_id}/` so errors sit next to metrics.

---

## Part 6 — Costs

Prices are approximate US-East list prices; verify current numbers on the AWS and Grafana pricing pages before budgeting.

### AWS CloudWatch

| Item | Price | Notes |
|---|---|---|
| Standard AWS service metrics (5-min) | Free | EC2, RDS, ALB, Lambda… included |
| EC2 detailed monitoring (1-min) | ~$2.10/instance/month (7 metrics × $0.30) | `monitoring = true` in Terraform |
| Custom metrics (CloudWatch agent: memory, disk, app) | $0.30/metric/month first 10k, drops to $0.10 then $0.05 | Each unique metric + dimension combo counts. 3 metrics × 100 instances = 300 metrics ≈ $90/mo |
| `GetMetricData` API | $0.01 per 1,000 metrics requested | This is what Grafana dashboards hit |
| `ListMetrics` / `GetMetricStatistics` | First 1M requests free, then $0.01/1,000 | Variable dropdowns use ListMetrics |
| CloudWatch Logs ingestion | ~$0.50/GB | Only if you ship logs |
| Logs Insights queries | ~$0.005/GB scanned | Log panels on dashboards |

**Worked example — Grafana query cost.** A dashboard with 10 panels, each 1 metric, refreshing every 60 s, open on 3 screens all day:

- 10 metrics × 3 viewers × 1,440 refreshes/day = 43,200 metrics/day
- ≈ 1.3M/month × $0.01/1,000 ≈ **$13/month**

Multiply by dozens of dashboards and 30 s refreshes and it adds up. Mitigations: `refresh: 5m` on overview boards, `period: 300` for long ranges, and Grafana's query caching (Enterprise/Cloud).

### Grafana

| Option | Price | Best for |
|---|---|---|
| Grafana OSS self-hosted | Free (pay for the EC2/EKS it runs on, ~$15–60/mo for a small instance) | Full control, no per-user fees |
| Grafana Cloud Free | $0 — 10k metric series, 50 GB logs, 3 users | Small teams, trials |
| Grafana Cloud Pro | ~$19/mo base + usage (~$8/1k series/mo) | No ops burden, managed alerting |
| Amazon Managed Grafana | ~$9/editor/mo + ~$5/viewer/mo | AWS-native SSO/IAM, no server to run |

### Terraform

Free (OSS) or HCP Terraform per-resource pricing. The Grafana provider itself costs nothing.

---

## Part 7 — Pros and cons of each approach

| Approach | Pros | Cons |
|---|---|---|
| **Per-resource dashboard via Terraform** (Part 1) | Simple to understand; dashboard lifecycle = resource lifecycle; alerts bundled | Many dashboards to maintain; every template change re-applies everywhere; Terraform state grows |
| **One tag-driven dashboard** (Part 4) | Zero per-resource code; new resources appear automatically; one place to improve | Depends on tag discipline; per-app tweaks harder; CloudWatch tag queries cost API calls |
| **File provisioning** | No API token; works air-gapped; Grafana auto-reloads | Self-hosted only; can't edit in UI; needs file distribution |
| **Grafana Cloud AWS integration** | Fastest setup; pre-built dashboards; auto-discovery | Vendor lock-in; double billing; less customizable |
| **Prometheus + exporters** | Cheapest at scale; richest metrics; standard tooling | You run and scale it; two metric systems if you also use CloudWatch |
| **Jsonnet/grafanalib generation** | DRY dashboards; strong reuse; reviewable diffs | Another language/toolchain; learning curve |

---

## Part 8 — Best practices checklist

- Fixed `uid` on every data source and dashboard so references never break.
- `overwrite = true` and a nightly plan so Terraform is the source of truth.
- `default_tags` on the AWS provider; never rely on people remembering to tag.
- Service-account tokens (not user API keys), scoped to Editor, rotated, stored in a secrets manager.
- Refresh intervals ≥ 1 min on detail boards, ≥ 5 min on overviews, to control CloudWatch API spend.
- Bundle alerts with dashboards in the same module so observability can't be skipped.
- Keep dashboard JSON in git next to the infrastructure it describes; review it like code.
- Pin provider versions (`~> 3.0`) — the Grafana provider changes resource schemas between majors.
- Test on a non-prod Grafana org/folder first; `grafana_organization` lets you isolate environments.

---

## Quick glossary

- **CloudWatch** — AWS's built-in metrics and logs service.
- **Data source** — Grafana's saved connection to something it can query.
- **Dashboard JSON model** — the text file that fully describes a dashboard.
- **Provisioning** — loading dashboards/data sources from files or API instead of clicking.
- **Service account token** — a Grafana API key tied to a bot account.
- **Dimension** — a label CloudWatch uses to identify which resource a metric belongs to (e.g., `InstanceId`).
- **Namespace** — the group a CloudWatch metric belongs to (e.g., `AWS/EC2`).
- **IRSA** — IAM Roles for Service Accounts; how pods on EKS get AWS permissions.
