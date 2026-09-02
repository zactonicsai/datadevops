# Hello-World Python Lambda with Terraform (the plain-English guide)

This guide is written so anyone who can follow a recipe can follow it. Big words get explained the first time they show up.

---

## Part 1: Build it step by step (about 10 minutes)

### What you need before starting

| Thing | Why | How to check |
|---|---|---|
| An AWS account | Lambda lives in AWS | You can log in at console.aws.amazon.com |
| AWS CLI installed and logged in | Terraform borrows the CLI's login | `aws sts get-caller-identity` prints your account number |
| Terraform 1.x installed | This is the tool that builds things for you | `terraform version` |
| Internet | Terraform downloads "providers" the first time | — |

### Step 1: Make a folder and two files

Make a folder called `hello-lambda`. Inside it, create these two files.

**File 1: `handler.py`** (the actual program that runs)

```python
import json

def lambda_handler(event, context):
    # "event" is whatever data was sent to us.
    # "context" is info about the run (time left, request id, etc).
    name = event.get("name", "World") if isinstance(event, dict) else "World"
    return {
        "statusCode": 200,
        "body": json.dumps({"message": f"Hello, {name}!"})
    }
```

**File 2: `main.tf`** (the instructions for Terraform)

```hcl
terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "us-east-1"   # change to your favorite region
}

# ---- 1. Zip the code -------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/handler.py"
  output_path = "${path.module}/build/hello.zip"
}

# ---- 2. Permission slip (IAM role) the function runs as -------------
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "hello-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Lets the function write logs (that's all it needs for hello world)
resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ---- 3. Log group (make it ourselves so we control retention) ------
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/hello-python"
  retention_in_days = 14
}

# ---- 4. The Lambda function itself ---------------------------------
resource "aws_lambda_function" "hello" {
  function_name = "hello-python"
  role          = aws_iam_role.lambda_role.arn

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "handler.lambda_handler"   # file_name.function_name
  runtime = "python3.14"               # newest GA Python runtime as of Sept 2026

  memory_size   = 128   # MB
  timeout       = 10    # seconds (default is only 3)
  architectures = ["arm64"]  # cheaper; use ["x86_64"] if you need it

  environment {
    variables = {
      GREETING_STYLE = "friendly"
    }
  }

  # Wait for the permission slip and log group to exist first
  depends_on = [
    aws_iam_role_policy_attachment.logs,
    aws_cloudwatch_log_group.lambda_logs,
  ]
}

output "function_name" {
  value = aws_lambda_function.hello.function_name
}
output "function_arn" {
  value = aws_lambda_function.hello.arn
}
```

### Step 2: Run Terraform

```bash
cd hello-lambda
terraform init      # downloads the aws + archive providers (one time)
terraform plan      # shows what WILL happen, changes nothing
terraform apply     # actually builds it; type "yes"
```

`init` is like installing the ingredients. `plan` is reading the recipe out loud. `apply` is cooking.

### Step 3: Test it

```bash
aws lambda invoke \
  --function-name hello-python \
  --cli-binary-format raw-in-base64-out \
  --payload '{"name": "Terraform"}' \
  response.json

cat response.json
```

You should see: `{"statusCode": 200, "body": "{\"message\": \"Hello, Terraform!\"}"}`

### Step 4: Change the code and update

Edit `handler.py` (for example change "Hello" to "Howdy"), then:

```bash
terraform apply
```

Terraform notices the zip changed (thanks to `source_code_hash`, explained below) and uploads the new version. If it says "No changes", read the gotchas section.

### Step 5: Clean up when done

```bash
terraform destroy
```

This removes everything it created, so you don't pay for anything.

---

## Part 2: How it actually works

### What is Lambda?

Lambda is "code without a computer." Normally you rent a server, install Python, copy your code onto it, and keep it running 24/7 even when nobody is using it. With Lambda you just hand AWS a zip file and say "run this when something happens." AWS finds a computer, runs your function for a few milliseconds, and turns it off. You pay only for the time it runs (and there's a big free tier).

### What is Terraform?

Terraform is a "describe what you want" tool. Instead of clicking around the AWS website 20 times, you write down the end result in a text file. Terraform compares that file to what exists in AWS and does the clicking for you. It also remembers what it built in a **state file** (`terraform.tfstate`) so it can update or delete later.

### The four pieces every Python Lambda needs

1. **The code** — a `.py` file with a function that takes `(event, context)`.
2. **A zip of the code** — Lambda only accepts zips (or container images, see Part 5).
3. **An IAM role** — a permission slip. "This function is allowed to write logs" or "allowed to read that S3 bucket." Without it, AWS won't run your function.
4. **The `aws_lambda_function` resource** — glues the other three together and sets settings like memory, timeout, and runtime.

### The `handler` string decoded

`handler = "handler.lambda_handler"` means:

- `handler` → the file `handler.py` (no `.py`)
- `lambda_handler` → the function inside that file

If you named your file `app.py` and your function `main`, the handler would be `app.main`.

### What is `event` and `context`?

- **event** — a Python dict with whatever called you. From the CLI it's your `--payload`. From API Gateway it's the HTTP request. From S3 it's "a file was uploaded."
- **context** — an object with info like `context.aws_request_id` and `context.get_remaining_time_in_millis()`.

---

## Part 3: The gotchas (things that bite people)

### Gotcha 1: Terraform doesn't see your code changes

**Symptom:** You edit `handler.py`, run `terraform apply`, and it says "No changes."

**Why:** Terraform only tracks the *arguments* you write in `main.tf`. The `filename` argument still says `build/hello.zip` — the same string as before — so nothing looks different.

**Fix:** Always set `source_code_hash`. It's a fingerprint (SHA-256) of the zip. New code → new fingerprint → Terraform updates.

```hcl
source_code_hash = data.archive_file.lambda_zip.output_base64sha256
# or if you made the zip yourself:
source_code_hash = filebase64sha256("build/hello.zip")
```

### Gotcha 2: Terraform updates the function EVERY time even when nothing changed

**Symptom:** Every `apply` re-uploads the function.

**Why:** Your zip is not "reproducible." Regular `zip` tools store the file's modification time inside the zip, so zipping the same file twice gives two different fingerprints.

**Fix options:**
- Use the `archive_file` data source (it writes fixed timestamps so the hash is stable).
- If you must zip by hand, use `zip -X` and normalize timestamps, e.g. `touch -t 202001010000 *.py` before zipping, or use a tool like `strip-nondeterminism`.
- Don't zip the `build/` folder into itself (put the zip outside the source folder).

### Gotcha 3: Size limits for the zip

| Limit | Number | What it means for you |
|---|---|---|
| Direct upload (Terraform `filename`) | **50 MB zipped** | Terraform sends the zip through the API. Over 50 MB = error. |
| Upload via S3 (`s3_bucket` + `s3_key`) | **50 MB zipped** per the API, but S3 path is required for anything big | Upload the zip to S3 first, point Lambda at it. |
| Unzipped size (code + all layers) | **250 MB** | Big libraries like pandas + numpy eat this fast. |
| Container image | **10 GB** | If you blow past 250 MB, switch to a container image. |
| Console editor | 3 MB | Only matters if you edit in the browser. |

**Also:** even under 50 MB, a 40 MB zip makes every `terraform apply` slow because Terraform reads the whole file, hashes it, and uploads it. Past ~10 MB, consider the S3 route:

```hcl
resource "aws_s3_object" "code" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "hello/${data.archive_file.lambda_zip.output_md5}.zip"
  source = data.archive_file.lambda_zip.output_path
  etag   = data.archive_file.lambda_zip.output_md5
}

resource "aws_lambda_function" "hello" {
  # ...
  s3_bucket        = aws_s3_object.code.bucket
  s3_key           = aws_s3_object.code.key
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}
```

Putting the hash in the S3 key (`${output_md5}.zip`) is a neat trick: each new build gets a new key, so you never accidentally overwrite the old one and old versions still work.

### Gotcha 4: Python libraries must be *inside* the zip, at the top level

`import requests` fails with "No module named requests" unless the `requests` folder is sitting right next to `handler.py` inside the zip. Lambda does not run `pip install` for you.

```bash
pip install -r requirements.txt --target build/package
cp handler.py build/package/
cd build/package && zip -r ../hello.zip . && cd ../..
```

Then point `archive_file` at the folder (`source_dir = "build/package"`) instead of a single file.

### Gotcha 5: Compiled libraries must match Lambda's computer

Libraries with C code (numpy, pandas, cryptography, psycopg2) are built for a specific CPU and OS. Lambda runs **Amazon Linux 2023** on either **x86_64** or **arm64**. A numpy installed on your Mac will crash on Lambda.

Fix: install with platform flags, build inside Docker, or use a Lambda **layer** that AWS or the community pre-built.

```bash
pip install --platform manylinux2014_aarch64 --only-binary=:all: \
  --target build/package -r requirements.txt
```
(use `manylinux2014_x86_64` if your `architectures` is `x86_64`)

### Gotcha 6: The log group that never dies

If you don't create the CloudWatch log group yourself, Lambda auto-creates `/aws/lambda/<name>` with **never-expire** retention. Terraform doesn't know about it, so `terraform destroy` leaves it behind, and it slowly costs money. That's why the example creates the log group explicitly with `retention_in_days`.

### Gotcha 7: "The role defined for the function cannot be assumed by Lambda"

IAM is "eventually consistent" — the role exists but AWS hasn't told every server yet. Happens right after creating the role. The `depends_on` in the example helps; if it still fails, just run `apply` again. The provider also retries automatically for a while.

### Gotcha 8: Some changes replace the function instead of updating it

Changing `function_name` deletes the function and makes a new one (new ARN — anything pointing at the old ARN breaks). Changing `runtime`, `memory_size`, `timeout`, `handler`, environment variables, or code is an in-place update. Watch `terraform plan`: `~` means update, `-/+` means destroy-and-recreate.

### Gotcha 9: Default timeout is 3 seconds

Anything that calls another service will probably blow past 3 seconds on a cold start. Set `timeout` to something sensible (max is 900 seconds = 15 minutes).

### Gotcha 10: Environment variables end up in your state file

`terraform.tfstate` stores everything in plain text, including `environment.variables`. Never put passwords in there. Use Secrets Manager or SSM Parameter Store and read them at runtime.

### Gotcha 11: Old runtimes get shut off

AWS retires Python versions about a year after python.org stops supporting them. Right now (Sept 2026): 3.9 is already deprecated, 3.10 loses support Oct 31 2026, and 3.14 is the newest GA runtime (3.15 is in public preview). Keep `runtime` current or one day `terraform apply` will refuse to update the function.

### Gotcha 12: Windows line endings and permissions

If you zip on Windows, files can have CRLF line endings or no execute permission. Python is forgiving about line endings, but shebang scripts and layers are not. The `archive_file` data source sets sane permissions for you; `zip.exe` may not.

---

## Part 4: Stuck on an older Terraform or older AWS provider?

Some arguments and resources simply don't exist in old provider versions. Run `terraform providers` to see your version, then check this table.

| Feature | Needs AWS provider | Workaround if you're older |
|---|---|---|
| `aws_lambda_function` (basic) | any | — |
| `source_code_hash` | any | — |
| `architectures = ["arm64"]` | ≥ 3.61 | Leave it out (defaults to x86_64) |
| `aws_lambda_function_url` | ≥ 4.6 | `null_resource` + `aws lambda create-function-url-config` (below) |
| `ephemeral_storage` block | ≥ 4.9 | Leave it out (512 MB default) |
| `snap_start` block | ≥ 4.42 | Skip (Java only anyway) |
| `logging_config` (JSON logs) | ≥ 5.24 | Set log format via CLI `update-function-configuration --logging-config` |
| `aws_lambda_invocation` data source with triggers | ≥ 5.x | `null_resource` + `aws lambda invoke` |
| `replace_security_groups_on_destroy` | ≥ 4.x | — |
| Python 3.14 in runtime validation | ≥ 6.x (roughly late 2025) | Older providers validate the `runtime` string and reject unknown values — upgrade, or use the CLI to change runtime after Terraform creates the function |

**Terraform core version notes:**
- **Terraform 0.11 and older:** `filebase64sha256()` does not exist. Use `base64sha256(file("hello.zip"))` — but this reads the file as text and can break on binaries. Better: upgrade to ≥ 0.12.
- **Terraform 0.12–0.14:** everything in the example works, but `required_providers` `source =` syntax needs ≥ 0.13.
- **Terraform ≥ 1.5:** you get `import {}` blocks and `check {}` blocks. Nice but not required.

### The universal escape hatch: `null_resource` + AWS CLI

If a resource doesn't exist in your provider, you can have Terraform run the CLI for you:

```hcl
resource "null_resource" "function_url" {
  triggers = {
    function = aws_lambda_function.hello.arn
  }

  provisioner "local-exec" {
    command = <<EOT
      aws lambda create-function-url-config \
        --function-name ${aws_lambda_function.hello.function_name} \
        --auth-type NONE || true
      aws lambda add-permission \
        --function-name ${aws_lambda_function.hello.function_name} \
        --statement-id public-url \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type NONE || true
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws lambda delete-function-url-config --function-name hello-python || true"
  }
}
```

Downsides: Terraform can't "see" what the CLI made, so `plan` won't show drift, and destroy is best-effort. Use this as a bridge, not a home.

### Other escape hatches

- **`aws_cloudformation_stack` resource** — wrap the missing thing in a tiny CloudFormation template. CloudFormation usually gets new Lambda features on day one.
- **Pin a newer provider only for one module** — you can't mix provider versions in a single root module, but you can split the Lambda into its own root module/workspace with a newer provider.
- **Upgrade the provider** — honestly the right answer 90% of the time. `terraform init -upgrade` after changing the version constraint. Read the upgrade guide for 4→5 and 5→6, they each renamed a few things.

---

## Part 5: The same thing with the AWS CLI (no Terraform)

Good for quick experiments or for understanding what Terraform is doing under the hood.

```bash
# 1. Make the permission slip
cat > trust.json <<'EOF'
{ "Version": "2012-10-17",
  "Statement": [{ "Effect": "Allow",
                  "Principal": { "Service": "lambda.amazonaws.com" },
                  "Action": "sts:AssumeRole" }] }
EOF
aws iam create-role --role-name hello-lambda-role \
  --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name hello-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
sleep 10   # give IAM a moment

# 2. Zip
zip hello.zip handler.py

# 3. Create
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws lambda create-function \
  --function-name hello-python \
  --runtime python3.14 \
  --architectures arm64 \
  --handler handler.lambda_handler \
  --role arn:aws:iam::$ACCOUNT:role/hello-lambda-role \
  --zip-file fileb://hello.zip \
  --timeout 10 --memory-size 128

# 4. Test
aws lambda invoke --function-name hello-python \
  --cli-binary-format raw-in-base64-out \
  --payload '{"name":"CLI"}' out.json && cat out.json

# 5. Update just the code (after editing handler.py and re-zipping)
aws lambda update-function-code --function-name hello-python --zip-file fileb://hello.zip

# 5b. Update code from S3 instead (for big zips)
aws s3 cp hello.zip s3://my-artifacts/hello.zip
aws lambda update-function-code --function-name hello-python \
  --s3-bucket my-artifacts --s3-key hello.zip

# 6. Update settings (not code)
aws lambda update-function-configuration --function-name hello-python \
  --timeout 30 --memory-size 256 --environment "Variables={GREETING_STYLE=loud}"

# 7. Wait for the update to finish (Lambda updates are async now)
aws lambda wait function-updated --function-name hello-python

# 8. Publish a frozen, numbered version + alias
aws lambda publish-version --function-name hello-python
aws lambda create-alias --function-name hello-python --name prod --function-version 1

# 9. Give it a public HTTPS URL
aws lambda create-function-url-config --function-name hello-python --auth-type NONE
aws lambda add-permission --function-name hello-python --statement-id url \
  --action lambda:InvokeFunctionUrl --principal "*" --function-url-auth-type NONE

# 10. Look at logs
aws logs tail /aws/lambda/hello-python --follow

# 11. Delete
aws lambda delete-function --function-name hello-python
aws iam detach-role-policy --role-name hello-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role --role-name hello-lambda-role
```

A gotcha unique to the CLI: `update-function-code` and `update-function-configuration` can't run back to back — the second one fails with `ResourceConflictException` if the first isn't finished. Use `aws lambda wait function-updated` in between. Terraform handles this waiting for you.

---

## Part 6: Other ways to build and deploy

| Method | What it is | Best for | Pros | Cons |
|---|---|---|---|---|
| **Terraform (this guide)** | Describe infrastructure in HCL | Teams who already use Terraform for everything else | One tool for all cloud stuff; great plan/diff; huge ecosystem | You package the zip yourself; not Lambda-specialized |
| **terraform-aws-modules/lambda** module | Community Terraform module (v8.x as of 2026) | Terraform users who want packaging done for them | Runs `pip install` for you, handles S3 upload, layers, aliases, Docker builds | Big module, lots of knobs, another thing to learn |
| **AWS SAM** | CloudFormation extension + `sam build` / `sam deploy` | Lambda-only projects | `sam local invoke` runs functions on your laptop; builds deps in a Lambda-like container | CloudFormation-only; harder to mix with non-serverless infra |
| **AWS CDK** | Write infra in Python/TypeScript | Developers who prefer real code over config | Loops, functions, types; `PythonFunction` construct bundles deps | Generates CloudFormation; more layers of abstraction |
| **Serverless Framework** | Third-party YAML tool | Multi-cloud teams | Very quick start; plugin ecosystem | Licensing changed to paid for larger orgs; less momentum than before |
| **AWS Console** | Click in the browser | Learning, one-off demos | Zero setup; edit code in-browser | Nothing is written down; impossible to repeat or review |
| **Container image** | Build a Docker image, push to ECR, point Lambda at it | Code + deps over 250 MB, or weird native libs | 10 GB limit; same image runs locally; full control of OS packages | Slower cold starts; need ECR and Docker; more moving parts |
| **Layers** | A separate zip of shared libs mounted at `/opt` | Sharing big libs across many functions | Smaller function zips; faster deploys; reuse | Still counts toward the 250 MB unzipped limit; version juggling |

### Container image version with Terraform (for when zips are too small)

```hcl
resource "aws_lambda_function" "hello_img" {
  function_name = "hello-python-image"
  role          = aws_iam_role.lambda_role.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.hello.repository_url}:${var.image_tag}"
  architectures = ["arm64"]
  timeout       = 10
}
```

You build and push the image separately (`docker build`, `docker push`), and use the image tag or digest as the thing Terraform watches for changes. Gotcha: pushing a new image with the **same** tag does not trigger Terraform — use the digest or a unique tag per build.

---

## Part 7: Best practices checklist

- **Always** set `source_code_hash`. No exceptions.
- Use `archive_file` or another reproducible zipper so the hash only changes when code changes.
- Create the CloudWatch log group yourself with a retention period.
- Set `timeout` and `memory_size` on purpose; the defaults (3 s, 128 MB) are tiny. More memory also means a faster CPU.
- Prefer `arm64` (Graviton) — usually cheaper and often faster for Python. Only use `x86_64` if a dependency has no arm64 build.
- Pin provider versions with `~>` so upgrades are deliberate.
- Keep secrets out of environment variables; read from Secrets Manager / SSM at runtime.
- Give the IAM role only what it needs (least privilege). `AWSLambdaBasicExecutionRole` is fine for hello world; add specific policies as you go.
- Use `publish = true` plus an `aws_lambda_alias` if anything important points at the function — then rollbacks are just repointing the alias.
- Store Terraform state remotely (S3 backend with locking) once more than one person touches it.
- Put the build output (`build/`) and `.terraform/` in `.gitignore`.
- Run `terraform plan` in CI on every pull request; only `apply` from main.
- Move to S3-based upload past ~10 MB and to a container image past 250 MB unzipped.
- Test locally with a tiny script: `python -c "import handler; print(handler.lambda_handler({'name':'me'}, None))"` — no AWS needed for pure logic.

---

## Part 8: Quick reference — `aws_lambda_function` arguments you'll actually use

| Argument | What it does | Default |
|---|---|---|
| `function_name` | Name (changing it recreates the function) | required |
| `role` | IAM role ARN | required |
| `handler` | `file.function` | required for zip |
| `runtime` | e.g. `python3.14` | required for zip |
| `filename` | Local zip path | — |
| `s3_bucket` / `s3_key` / `s3_object_version` | Zip in S3 instead | — |
| `source_code_hash` | Fingerprint so updates are detected | — |
| `package_type` / `image_uri` | `"Image"` + ECR URI for containers | `"Zip"` |
| `memory_size` | 128–10240 MB | 128 |
| `timeout` | 1–900 seconds | 3 |
| `architectures` | `["x86_64"]` or `["arm64"]` | x86_64 |
| `environment { variables = {} }` | Env vars | — |
| `layers` | List of layer ARNs (max 5) | — |
| `publish` | Freeze a numbered version on each change | false |
| `ephemeral_storage { size }` | `/tmp` size, 512–10240 MB | 512 |
| `vpc_config` | Put the function inside a VPC | — |
| `logging_config` | JSON logs, log level, custom log group | text |
| `reserved_concurrent_executions` | Cap how many can run at once | unlimited |
| `tags` | Labels | — |

That's everything you need to go from zero to a working, updatable Python Lambda — and to know why it breaks when it breaks.
