# AMI Baseline Build Pipeline

A complete, runnable GitLab CI/CD pipeline that:

1. **Terraform** discovers the **latest Amazon Linux 2023** AMI.
2. **Packer** launches a temporary instance from it and runs **Ansible** to install **Java**, **Python**, and a **Kafka prerequisite**, and to deploy an **HTML status page stamped with the patch date**, served on **port 7777**.
3. Packer snapshots the result into a new AMI named **`baseline-demo-<datetime>`**.
4. A **test** stage boots the new AMI and verifies it works and that the HTML page is reachable on **7777**.

This README explains **every line** of the Terraform, the Ansible, the Packer template, and the GitLab pipeline, then walks the flow end to end. Two SVG diagrams are in `docs/`.

---

## Diagrams

**Tool flow** — what each tool does and how artifacts pass between them:

![Tool flow](docs/flow-diagram.svg)

**Pipeline** — the GitLab stages and jobs, left-to-right execution order:

![Pipeline](docs/pipeline-diagram.svg)

---

## Repository layout

```
.
├── .gitlab-ci.yml              # The pipeline (stages, jobs, flow)
├── ci/
│   └── variables.yml           # Tunable settings (region, versions, port)
├── terraform/
│   ├── main.tf                 # Looks up the latest AL2023 AMI
│   ├── variables.tf            # Input: aws_region
│   └── outputs.tf              # Outputs: the resolved AMI id/name
├── packer/
│   └── baseline.pkr.hcl        # Builds the baseline-demo AMI (calls Ansible)
├── ansible/
│   ├── playbooks/baseline.yml  # Installs Java/Python/Kafka, deploys HTML+service
│   └── files/index.html.j2     # The patched-date HTML page (Jinja2 template)
├── tests/
│   └── verify-ami.sh           # Boots the new AMI, checks 7777, cleans up
└── docs/
    ├── flow-diagram.svg
    └── pipeline-diagram.svg
```

---

## Prerequisites

- A GitLab project with a runner.
- An AWS account. The pipeline authenticates with **OIDC** (recommended): set a protected CI/CD variable `AWS_ROLE_ARN` pointing at an IAM role GitLab can assume. (Static `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` also work as a fallback.)
- The role/user needs permissions for: EC2 (run/terminate instances, create/delete security groups, create images/snapshots, describe\*), and SSM `GetParameter` for the AMI lookup.

No local tooling is required — every job runs in a pinned container image.

---

# Part 1 — Terraform (discover the AMI), line by line

File: `terraform/main.tf`. **Terraform here is a read-only lookup. It creates no infrastructure** — it only resolves the latest AL2023 AMI id and outputs it.

### `terraform/main.tf`

```hcl
terraform {
  required_version = ">= 1.6.0"
```
- `terraform { ... }` is the settings block for Terraform itself.
- `required_version = ">= 1.6.0"` refuses to run on Terraform older than 1.6, so everyone uses a compatible CLI.

```hcl
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```
- `required_providers` declares which provider plugins are needed.
- `aws = { ... }` names the provider locally as `aws`.
- `source = "hashicorp/aws"` is where to download it (the official AWS provider).
- `version = "~> 5.0"` is a *pessimistic* constraint: any `5.x` but not `6.0`. This pins major behavior while allowing patches.

```hcl
provider "aws" {
  region = var.aws_region
}
```
- Configures the AWS provider. `region = var.aws_region` takes the region from an input variable so the same code runs anywhere. Credentials come from the environment (the pipeline injects them), so they are deliberately not written here.

```hcl
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
```
- `data "..." "..."` is a **data source**: it *reads* existing information, it never creates anything.
- `aws_ssm_parameter` reads a value from AWS Systems Manager Parameter Store.
- This specific public parameter is maintained by AWS and **always points at the newest AL2023 x86_64 AMI** for the current region. `kernel-default` follows the current default kernel. This is the authoritative way to "get the latest AL2023 AMI."

```hcl
data "aws_ami" "al2023_search" {
  most_recent = true
  owners      = ["amazon"]
```
- A second, alternative lookup using the EC2 AMI catalog (shown so you can see both idioms).
- `most_recent = true` → if several AMIs match, pick the newest by creation date.
- `owners = ["amazon"]` → only official Amazon-owned images (security: avoids third-party look-alikes).

```hcl
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }
```
- Filters narrow the search. This one matches the AL2023 GA **name pattern** (`*` are wildcards).

```hcl
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
```
- Restrict to 64-bit Intel/AMD (`x86_64`), modern virtualization (`hvm`), and only images that are ready to use (`available`).

```hcl
data "aws_ami" "al2023_from_ssm" {
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [data.aws_ssm_parameter.al2023.value]
  }
}
```
- Looks up the **full AMI record** for the id we got from SSM, so we can print friendly metadata (name, creation date).
- `data.aws_ssm_parameter.al2023.value` is a **reference** to the SSM parameter's value above — this is how Terraform passes data between resources.

### `terraform/variables.tf`

```hcl
variable "aws_region" {
  description = "AWS region in which to look up the AL2023 AMI"
  type        = string
  default     = "us-east-1"
}
```
- Declares one input. `type = string` enforces the kind of value; `default` makes it optional. The pipeline overrides it with `TF_VAR_aws_region` (Terraform automatically reads `TF_VAR_*` env vars into variables).

### `terraform/outputs.tf`

```hcl
output "al2023_ami_id" {
  description = "Latest Amazon Linux 2023 AMI ID (from SSM public parameter)"
  value       = data.aws_ssm_parameter.al2023.value
}
```
- **Outputs are how Terraform hands values to the outside world.** The pipeline runs `terraform output -raw al2023_ami_id` to capture this and feed it to Packer.

```hcl
output "al2023_ami_name"          { ... value = data.aws_ami.al2023_from_ssm.name }
output "al2023_ami_creation_date" { ... value = data.aws_ami.al2023_from_ssm.creation_date }
output "al2023_ami_id_via_search" { ... value = data.aws_ami.al2023_search.id }
output "aws_region"               { ... value = var.aws_region }
```
- Friendly metadata and the alternative search result (for comparison), plus the region echoed back for clarity in logs.

---

# Part 2 — Ansible (provision the image), line by line

File: `ansible/playbooks/baseline.yml`. Packer runs this **on the temporary build instance**; everything it does is baked into the AMI.

```yaml
- name: Build baseline demo image
  hosts: all
  become: true
```
- A *play*. `name` is a label. `hosts: all` targets whatever host Packer injects (the build instance). `become: true` runs tasks with `sudo` (root), required to install packages and write system files.

```yaml
  vars:
    kafka_version: "3.7.1"
    kafka_scala_version: "2.13"
    kafka_install_dir: "/opt/kafka"
    http_port: 7777
    web_root: "/var/www/baseline"
```
- Reusable variables. Centralizing them means changing the Kafka version or port is a one-line edit. `http_port: 7777` is the required HTTP port.

```yaml
  tasks:
    - name: Record the patch timestamp
      ansible.builtin.set_fact:
        patch_timestamp: "{{ ansible_date_time.iso8601 }}"
```
- `set_fact` creates a variable at runtime. `ansible_date_time` is a *fact* (auto-collected system info); `.iso8601` formats it like `2026-06-29T19:45:00Z`. We capture it **once** so the HTML page and the marker file show the identical patch time.

```yaml
    - name: Update all system packages
      ansible.builtin.dnf:
        name: "*"
        state: latest
        update_cache: true
```
- `dnf` is the AL2023 package manager module. `name: "*"` with `state: latest` upgrades **every** installed package → the baseline starts fully patched. `update_cache: true` refreshes metadata first.

```yaml
    - name: Install Java (Amazon Corretto 21 JDK)
      ansible.builtin.dnf:
        name: java-21-amazon-corretto-devel
        state: present
```
- Installs **Java** — Amazon Corretto 21, the LTS JDK shipped in the AL2023 repos. The `-devel` package includes `javac`. **This also satisfies the Kafka prerequisite**, because Kafka requires a JVM. `state: present` means "ensure it's installed" (idempotent).

```yaml
    - name: Install Python 3 and pip
      ansible.builtin.dnf:
        name:
          - python3
          - python3-pip
        state: present
```
- Installs **Python 3** and `pip`. A list installs several packages in one task.

```yaml
    - name: Install supporting tools (tar, gzip, curl)
      ansible.builtin.dnf:
        name: [tar, gzip, curl-minimal]
        state: present
```
- Utilities needed to download and unpack the Kafka client. (`curl-minimal` is the AL2023 default curl package.)

```yaml
    - name: Create Kafka install directory
      ansible.builtin.file:
        path: "{{ kafka_install_dir }}"
        state: directory
        mode: "0755"
```
- `file` with `state: directory` creates `/opt/kafka`. `mode: "0755"` sets standard read/execute permissions.

```yaml
    - name: Download and extract the Kafka client
      ansible.builtin.unarchive:
        src: "https://archive.apache.org/dist/kafka/{{ kafka_version }}/kafka_{{ kafka_scala_version }}-{{ kafka_version }}.tgz"
        dest: "{{ kafka_install_dir }}"
        remote_src: true
        extra_opts: ["--strip-components=1"]
        creates: "{{ kafka_install_dir }}/bin/kafka-topics.sh"
```
- **The Kafka prerequisite, staged on the box.** `unarchive` downloads and extracts in one step.
  - `src` is the official Apache Kafka tarball URL, built from the version vars.
  - `remote_src: true` → download happens **on the build instance**, not the runner.
  - `--strip-components=1` drops the top-level `kafka_2.13-3.7.1/` folder so files land directly in `/opt/kafka`.
  - `creates: .../kafka-topics.sh` makes it **idempotent**: if that file already exists, the task is skipped.

```yaml
    - name: Create web root directory
      ansible.builtin.file:
        path: "{{ web_root }}"
        state: directory
        mode: "0755"
```
- Creates `/var/www/baseline`, where the HTML page will live.

```yaml
    - name: Render the patched-date HTML page
      ansible.builtin.template:
        src: index.html.j2
        dest: "{{ web_root }}/index.html"
        mode: "0644"
```
- `template` renders a **Jinja2** template through Ansible's variable engine and writes the result. `src` is `ansible/files/index.html.j2`; placeholders like `{{ patch_timestamp }}` get filled in, producing a page stamped with this build's patch date.

```yaml
    - name: Install the baseline-web systemd service unit
      ansible.builtin.copy:
        dest: /etc/systemd/system/baseline-web.service
        mode: "0644"
        content: |
          [Unit]
          Description=Baseline demo HTTP page on port {{ http_port }}
          After=network-online.target
          Wants=network-online.target

          [Service]
          ExecStart=/usr/bin/python3 -m http.server {{ http_port }} --directory {{ web_root }}
          Restart=always
          User=root

          [Install]
          WantedBy=multi-user.target
```
- Writes a **systemd service** that serves the page. Using `copy` with inline `content` creates the unit file.
  - `[Unit]` + `After/Wants=network-online.target` → start after networking is up.
  - `ExecStart=python3 -m http.server 7777 --directory /var/www/baseline` → a zero-dependency static web server on **7777** (Python is already installed, so no extra software needed).
  - `Restart=always` → if it crashes, systemd restarts it.
  - `WantedBy=multi-user.target` → start at normal boot. Because this is baked into the AMI, **every instance launched from the image serves the page automatically.**

```yaml
    - name: Enable (and start) the baseline-web service
      ansible.builtin.systemd:
        name: baseline-web.service
        enabled: true
        state: started
        daemon_reload: true
```
- `enabled: true` → start on boot. `state: started` → start it now too (so Packer's in-build check can hit it). `daemon_reload: true` → reload systemd so it sees the new unit file.

```yaml
    - name: Write a baseline marker file
      ansible.builtin.copy:
        dest: /etc/baseline-release
        mode: "0644"
        content: |
          baseline_image=baseline-demo
          patched_at={{ patch_timestamp }}
          java=corretto-21
          python=python3
          kafka_client={{ kafka_version }}
          http_port={{ http_port }}
```
- Drops a small machine-readable manifest at `/etc/baseline-release` recording what's in the image and when it was patched — handy for audits and for the test stage.

### `ansible/files/index.html.j2`

A normal HTML document with Jinja2 placeholders. The key lines:
- `Patched:</strong> {{ patch_timestamp }}` → the **patched date** stamped into the page.
- `port <strong>{{ http_port }}</strong>` and the Kafka/Java/Python rows → render from the same vars.
The styling is inline so the page is fully self-contained.

---

# Part 3 — Packer (build the AMI), line by line

File: `packer/baseline.pkr.hcl`. Packer launches a temporary EC2 instance from the Terraform-resolved AMI, runs Ansible on it, then snapshots it into the new AMI.

```hcl
packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.1.0"
    }
  }
}
```
- Declares the plugins Packer needs: `amazon` (provides the `amazon-ebs` builder) and `ansible` (provides the `ansible` provisioner). `packer init` installs them.

```hcl
variable "aws_region"    { type = string, default = "us-east-1" }
variable "source_ami"    { type = string, description = "Base AL2023 AMI id discovered by Terraform" }
variable "instance_type" { type = string, default = "t3.micro" }
variable "ssh_username"  { type = string, default = "ec2-user" }
```
- Inputs supplied by the pipeline. **`source_ami` is the AMI id from Terraform** — this is the hand-off that guarantees we build on the exact image Terraform found. `ec2-user` is the default login on AL2023.

```hcl
locals {
  build_time = regex_replace(timestamp(), "[^0-9]", "")
  ami_name   = "baseline-demo-${local.build_time}"
}
```
- `locals` are computed values.
  - `timestamp()` returns build time as RFC3339 (e.g. `2026-06-29T19:45:01Z`).
  - `regex_replace(..., "[^0-9]", "")` strips every non-digit, giving `20260629194501`.
  - `ami_name = "baseline-demo-${local.build_time}"` → the required **`baseline-demo` name with date-time**.

```hcl
source "amazon-ebs" "baseline" {
  region        = var.aws_region
  source_ami    = var.source_ami
  instance_type = var.instance_type
  ssh_username  = var.ssh_username
  ami_name      = local.ami_name
```
- The **builder**: `amazon-ebs` creates an EBS-backed AMI by launching an instance, provisioning it, and snapshotting. It uses the Terraform AMI as `source_ami`, connects over SSH as `ssh_username`, and names the output `ami_name`.

```hcl
  temporary_security_group_source_public_ip = true
```
- Packer creates a **temporary** security group for the build instance and allows your runner's public IP in. This (plus SSH) lets the in-build HTML check reach the instance. The group is deleted with the build instance and never affects the AMI.

```hcl
  tags = {
    Name        = local.ami_name
    BaseImage   = "amazon-linux-2023"
    BuildTool   = "packer"
    Provisioner = "ansible"
    Pipeline    = "ami-baseline"
  }
  run_tags = { Name = "packer-build-${local.ami_name}" }
}
```
- `tags` are applied to the resulting **AMI and its snapshot** (the test and cleanup stages find images by the `Pipeline = ami-baseline` tag). `run_tags` tag the **temporary build instance** so stray resources are easy to spot.

```hcl
build {
  name    = "baseline"
  sources = ["source.amazon-ebs.baseline"]
```
- The `build` block ties the builder to provisioners. `sources` lists which builder(s) to run (referencing the `source` above).

```hcl
  provisioner "ansible" {
    playbook_file = "../ansible/playbooks/baseline.yml"
    extra_arguments = [
      "--extra-vars", "ansible_python_interpreter=/usr/bin/python3"
    ]
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_ROLES_PATH=../ansible/roles"
    ]
  }
```
- **Provisioner 1 — Ansible.** Packer auto-generates an inventory pointing at the build instance and runs `ansible-playbook` for us.
  - `playbook_file` → our playbook (path is relative to the `packer/` dir).
  - `extra_arguments` → forces the Python interpreter path on the target.
  - `ANSIBLE_HOST_KEY_CHECKING=False` → don't prompt about the brand-new host's SSH key.
  - The provisioner connects using the builder's `ssh_username` automatically (no extra config needed).

```hcl
  provisioner "shell" {
    inline = [
      "echo '=== in-build verification ==='",
      "java -version",
      "python3 --version",
      "test -x /opt/kafka/bin/kafka-topics.sh && echo 'kafka client present'",
      "sudo systemctl is-enabled baseline-web.service",
      "curl -fsS http://localhost:7777 | grep -q 'Baseline Demo Image' && echo 'HTML page OK on 7777'",
      "cat /etc/baseline-release"
    ]
  }
```
- **Provisioner 2 — in-build smoke check**, run **before** snapshotting. It confirms Java, Python, the Kafka client, the enabled service, and that the page answers on 7777 locally. If anything fails here, Packer aborts and **no bad AMI is produced**.

```hcl
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
    custom_data = { ami_name = local.ami_name }
  }
}
```
- After a successful build, the `manifest` post-processor writes `packer-manifest.json` containing the new AMI id (as `artifact_id`, formatted `region:ami-xxxx`). The test stage reads this to know which AMI to boot.

---

# Part 4 — GitLab pipeline, line by line

File: `.gitlab-ci.yml`.

```yaml
include:
  - local: '/ci/variables.yml'
```
- Pulls in the variables file so settings live in one place.

```yaml
stages:
  - validate
  - ami-lookup
  - build
  - test
  - cleanup
```
- Declares the **ordered phases**. A stage only starts once the previous one fully passes — so a broken image can never reach `test`, and a failed `test` blocks nothing downstream because it's last (except optional manual cleanup).

```yaml
.aws-auth:
  id_tokens:
    AWS_ID_TOKEN:
      aud: "sts.amazonaws.com"
```
- A **hidden job** (the leading `.`) that other jobs reuse. `id_tokens` makes GitLab mint an **OIDC token** with audience `sts.amazonaws.com`, which AWS trusts.

```yaml
  before_script:
    - set -euo pipefail
    - |
      if [ -n "${AWS_ROLE_ARN:-}" ]; then
        CREDS=$(aws sts assume-role-with-web-identity \
          --role-arn "${AWS_ROLE_ARN}" \
          --role-session-name "gitlab-${CI_PIPELINE_ID}" \
          --web-identity-token "${AWS_ID_TOKEN}" \
          --duration-seconds 3600 --query Credentials --output json)
        export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)
        export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)
        export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)
      fi
      export AWS_DEFAULT_REGION="${AWS_REGION}"
      aws sts get-caller-identity
```
- `set -euo pipefail` → fail fast on errors/unset vars.
- If `AWS_ROLE_ARN` is set, exchange the OIDC token for temporary AWS credentials via `assume-role-with-web-identity` and export them. (If not set, the job falls back to static keys from CI/CD variables.)
- `get-caller-identity` proves auth works before doing anything.

### validate stage

```yaml
validate:terraform:
  stage: validate
  image: "hashicorp/terraform:${TERRAFORM_VERSION}"
  script:
    - cd "${TF_DIR}"
    - terraform fmt -check -recursive
    - terraform init -backend=false
    - terraform validate
```
- Runs in the pinned Terraform image. `fmt -check` fails if code isn't canonically formatted; `init -backend=false` installs providers without touching remote state; `validate` checks correctness. Read-only.

```yaml
validate:packer:
  ...
  script:
    - cd "${PACKER_DIR}"
    - packer init .
    - packer fmt -check .
    - packer validate -var "source_ami=ami-00000000000000000" -var "aws_region=${AWS_REGION}" .
```
- Installs plugins, checks formatting, and validates the template. `validate` requires a syntactically valid AMI id, so a dummy is passed — we're only checking the template, not building.

```yaml
validate:ansible:
  ...
  script:
    - ansible-playbook ansible/playbooks/baseline.yml --syntax-check
    - ansible-lint ... (advisory)
```
- `--syntax-check` parses the playbook and templates without running them. Lint is advisory.

### ami-lookup stage

```yaml
ami-lookup:
  stage: ami-lookup
  extends: .aws-auth
  image: "hashicorp/terraform:${TERRAFORM_VERSION}"
  before_script:
    - apk add --no-cache aws-cli jq bash >/dev/null
    - !reference [.aws-auth, before_script]
```
- `extends: .aws-auth` inherits the OIDC login. The Terraform image lacks `aws`/`jq`, so we install them, then run the shared auth via `!reference` (GitLab's way of splicing in another job's script lines).

```yaml
  script:
    - cd "${TF_DIR}"
    - terraform init -backend=false
    - terraform apply -auto-approve -var "aws_region=${AWS_REGION}"
    - SOURCE_AMI=$(terraform output -raw al2023_ami_id)
    - AMI_NAME=$(terraform output -raw al2023_ami_name)
    - echo "Resolved AL2023 AMI: ${SOURCE_AMI} (${AMI_NAME})"
    - echo "SOURCE_AMI=${SOURCE_AMI}" > "${CI_PROJECT_DIR}/ami.env"
```
- `terraform apply` here just resolves the data sources (no resources are created). We read the AMI id with `output -raw` and write it to `ami.env` as a `KEY=value` line.

```yaml
  artifacts:
    reports:
      dotenv: ami.env
    paths: [ami.env]
    expire_in: 1 day
```
- `reports: dotenv: ami.env` is the magic bit: GitLab loads those `KEY=value` pairs as **environment variables in downstream jobs**. So `build:packer` automatically gets `$SOURCE_AMI`.

### build stage

```yaml
build:packer:
  stage: build
  extends: .aws-auth
  image: "hashicorp/packer:${PACKER_VERSION}"
  needs:
    - job: ami-lookup
      artifacts: true
```
- `needs` makes this start as soon as `ami-lookup` finishes (and imports its artifacts, i.e. `ami.env` → `$SOURCE_AMI`).

```yaml
  before_script:
    - apk add --no-cache aws-cli jq bash python3 py3-pip openssh-client >/dev/null
    - pip install --break-system-packages "ansible-core" >/dev/null 2>&1 || pip install ansible-core >/dev/null
    - !reference [.aws-auth, before_script]
```
- The Packer image is minimal; we add `aws`, `jq`, `python3`, **`ansible-core`** (so the Ansible provisioner can run), and `openssh-client` (Packer SSHes into the build instance). Then shared auth.

```yaml
  script:
    - cd "${PACKER_DIR}"
    - packer init .
    - packer build -var "aws_region=${AWS_REGION}" -var "source_ami=${SOURCE_AMI}" -var "instance_type=${PACKER_INSTANCE_TYPE}" .
    - cat packer-manifest.json
  artifacts:
    paths: [packer/packer-manifest.json]
    expire_in: 1 week
```
- `packer build` does the real work: launch instance from `$SOURCE_AMI` → run Ansible → in-build checks → snapshot → write manifest. The manifest is saved as an artifact for the test stage.

### test stage

```yaml
test:verify-ami:
  stage: test
  extends: .aws-auth
  image: "amazon/aws-cli:2.17.0"
  needs:
    - job: build:packer
      artifacts: true
  before_script:
    - yum install -y jq bash >/dev/null 2>&1
    - !reference [.aws-auth, before_script]
  script:
    - chmod +x tests/verify-ami.sh
    - ./tests/verify-ami.sh
```
- Imports `packer-manifest.json`, installs `jq`/`bash`, authenticates, and runs the verification script (explained next).

### cleanup stage

```yaml
cleanup:old-amis:
  stage: cleanup
  extends: .aws-auth
  image: "amazon/aws-cli:2.17.0"
  ...
  script:
    - if [ "${ALLOW_DEREGISTER}" != "true" ]; then echo refusing; exit 1; fi
    - OLD=$(aws ec2 describe-images --owners self --region "${AWS_REGION}" \
        --filters "Name=tag:Pipeline,Values=ami-baseline" \
        --query 'sort_by(Images,&CreationDate)[:-1].ImageId' --output text)
    - for ami in ${OLD}; do aws ec2 deregister-image --image-id "${ami}"; done
  rules:
    - when: manual
      allow_failure: true
```
- **Manual + double-gated.** It only deregisters when `ALLOW_DEREGISTER=true`. The JMESPath `sort_by(Images,&CreationDate)[:-1]` lists our pipeline's AMIs oldest→newest and **drops the newest** (`[:-1]`), so the latest baseline is always kept. `when: manual` means it never runs automatically.

---

# Part 5 — The verification script, line by line

File: `tests/verify-ami.sh`. It proves the new AMI boots and serves the page.

```bash
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
HTTP_PORT="${HTTP_PORT:-7777}"
INSTANCE_TYPE="${TEST_INSTANCE_TYPE:-t3.micro}"
MANIFEST="${PACKER_MANIFEST:-packer/packer-manifest.json}"
INSTANCE_ID=""; SG_ID=""
```
- Strict mode, then config from env vars with sensible defaults. `INSTANCE_ID`/`SG_ID` are tracked so cleanup can remove them.

```bash
cleanup() { ... terminate instance ... delete security group ... }
trap cleanup EXIT
```
- `trap cleanup EXIT` guarantees cleanup runs **on any exit** — success, failure, or error — so the test never leaks a running instance or security group. The SG deletion retries because the network interface can take a few seconds to detach after termination.

```bash
AMI_ID=$(jq -r '.builds[-1].artifact_id' "${MANIFEST}" | cut -d: -f2)
```
- Reads the newest build's `artifact_id` from the Packer manifest (format `region:ami-xxxx`) and takes the part after the colon → the AMI id.

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 create-security-group --group-name "ami-test-$$-..." --vpc-id "${VPC_ID}" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --ip-permissions "...FromPort=${HTTP_PORT}...CidrIp=0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --ip-permissions "...FromPort=22..."
```
- Finds the default VPC, creates a **throwaway security group**, and opens **7777** (and 22 for optional debugging) so the test can reach the page.

```bash
INSTANCE_ID=$(aws ec2 run-instances --image-id "${AMI_ID}" --instance-type "${INSTANCE_TYPE}" \
  --security-group-ids "${SG_ID}" --associate-public-ip-address ... --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}"
```
- Launches **one** instance from the new AMI with a public IP. `wait instance-running` blocks until it's running; **`wait instance-status-ok` blocks until AWS's health checks pass — i.e. the OS actually booted.** This is the "verify the new image boots" requirement.

```bash
PUBLIC_IP=$(aws ec2 describe-instances ... --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
for attempt in $(seq 1 30); do
  if HTML=$(curl -fsS --max-time 5 "http://${PUBLIC_IP}:${HTTP_PORT}/"); then break; fi
  sleep 10
done
[ -n "${HTML}" ] || { echo "FAIL: page never responded"; exit 1; }
```
- Gets the public IP and polls `http://<ip>:7777/` up to 30 times (≈5 min) to allow for boot + service start. Fails if the page never answers.

```bash
echo "${HTML}" | grep -q "Baseline Demo Image" || { echo "FAIL"; exit 1; }
echo "${HTML}" | grep -q "Patched:"             || { echo "FAIL"; exit 1; }
echo "PASS: HTML page is live on port ${HTTP_PORT} ..."
```
- Asserts the page actually contains our marker text **and** the patch stamp — proving it's *our* baked-in page, not a coincidence. Then the `EXIT` trap tears everything down.

---

## Running it

1. Push the repo to GitLab.
2. Set `AWS_ROLE_ARN` (OIDC) — or static keys — as protected CI/CD variables.
3. Optionally edit `ci/variables.yml` (region, instance sizes, port).
4. Open a pipeline. `validate` → `ami-lookup` → `build` → `test` run in order.
5. On green, your new **`baseline-demo-<datetime>`** AMI is built and verified. Find it in EC2 → AMIs (filter by tag `Pipeline = ami-baseline`).
6. To prune old images later, run the manual `cleanup:old-amis` job with `ALLOW_DEREGISTER=true`.

## Cost & safety notes

- The build and test each launch a single `t3.micro` for a few minutes, then terminate it. The `EXIT` trap in the test script means nothing is left running even if the test fails.
- Packer's temporary security group and key pair are removed automatically at the end of the build.
- `cleanup:old-amis` is manual and refuses to run unless `ALLOW_DEREGISTER=true`, and always keeps the newest baseline.

## Customizing

- **Different Java/Python/Kafka versions** → edit the `vars` in `ansible/playbooks/baseline.yml`.
- **Different port** → change `HTTP_PORT` in `ci/variables.yml` *and* `http_port` in the playbook (kept separate so the pipeline and image can be reasoned about independently; set both to the same value).
- **Add software** → add tasks to the playbook; it's baked into the next build automatically.
- **Different base OS** → change the SSM parameter name in `terraform/main.tf` and the `ssh_username` in the Packer template.
