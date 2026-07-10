I'll update the Terraform to pull a Docker image from Artifactory, plus explain the automation flow.

```hcl
# Provider block: tells Terraform we're using AWS and in which region
provider "aws" {
  region = "us-east-1"  # Change to your region
}

# Data source: looks up the latest Amazon Linux 2023 AMI so you don't hardcode an ID
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# --- Variables: keep secrets/config out of the main body ---

variable "artifactory_url" {
  description = "Artifactory Docker registry host, e.g. mycompany.jfrog.io"
  type        = string
}

variable "artifactory_repo" {
  description = "Docker repo/image path, e.g. docker-local/myapp"
  type        = string
}

variable "image_tag" {
  description = "Image tag to pull"
  type        = string
  default     = "latest"
}

variable "artifactory_user" {
  description = "Artifactory username"
  type        = string
  sensitive   = true  # Hides value in Terraform output/logs
}

variable "artifactory_token" {
  description = "Artifactory API token or password"
  type        = string
  sensitive   = true
}

# IAM Role: the identity the EC2 instance assumes so SSM can talk to it
resource "aws_iam_role" "ssm_role" {
  name = "ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Attach AWS-managed SSM policy to the role (grants SSM connectivity)
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance Profile: the wrapper that lets an EC2 instance use the IAM role
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ec2-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# The EC2 instance itself
resource "aws_instance" "server" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = "subnet-xxxxxxxx"               # Your existing subnet
  vpc_security_group_ids = ["sg-xxxxxxxx"]                 # Your existing security group
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  # user_data: a boot script that runs ONCE when the instance first launches.
  # This is the automation that installs Docker and pulls your image.
  user_data = <<-EOF
    #!/bin/bash
    set -e  # Exit immediately if any command fails

    # Install Docker from the AL2023 package repo
    dnf install -y docker

    # Start Docker now and enable it to start on every reboot
    systemctl enable --now docker

    # Log in to Artifactory's Docker registry using the injected credentials
    echo "${var.artifactory_token}" | docker login "${var.artifactory_url}" \
      --username "${var.artifactory_user}" --password-stdin

    # Pull the specified image from Artifactory
    docker pull "${var.artifactory_url}/${var.artifactory_repo}:${var.image_tag}"

    # Run the container, restarting it automatically unless manually stopped
    docker run -d --restart unless-stopped \
      --name myapp \
      "${var.artifactory_url}/${var.artifactory_repo}:${var.image_tag}"
  EOF

  tags = {
    Name = "simple-ec2"
  }
}

# Output the instance ID so you can grab it after apply
output "instance_id" {
  value = aws_instance.server.id
}
```

## How the automation works

The automation lives in the **`user_data`** block. Here's the flow end to end:

1. **Terraform injects values at apply time.** The `${var.*}` placeholders inside the script are resolved by Terraform before the script reaches AWS. So the instance boots with a script that already contains your real registry URL, image path, and credentials baked in.

2. **AWS runs `user_data` on first boot.** When EC2 launches the instance, the cloud-init process executes this script exactly once as root. You don't SSH in or trigger anything manually — it's fully hands-off.

3. **The script provisions everything in order:** installs Docker → starts the daemon → authenticates to Artifactory → pulls your image → runs the container. `set -e` ensures that if any step fails, the script stops rather than continuing in a broken state.

4. **`--restart unless-stopped`** means Docker relaunches your container after a reboot or crash, so the app stays up without further automation.

## Providing the variables

Create a `terraform.tfvars` file (and add it to `.gitignore` — it holds secrets):

```hcl
artifactory_url   = "mycompany.jfrog.io"
artifactory_repo  = "docker-local/myapp"
image_tag         = "1.0.0"
artifactory_user  = "svc-deploy"
artifactory_token = "your-token-here"
```

Then run `terraform init`, `plan`, and `apply` as before.

## Important caveats

- **Credentials in user_data are visible.** Anyone with access to the instance metadata or the EC2 console can read `user_data`. For production, pull the Artifactory token from **AWS Secrets Manager** or **SSM Parameter Store** inside the script instead of injecting it directly — that also requires adding a small IAM policy granting the role read access to that secret.

- **Network path to Artifactory.** Your existing SG needs outbound 443, and the subnet needs a route to reach Artifactory (internet-facing via NAT/IGW, or your internal network if it's self-hosted).

- **Changing `user_data` later** won't re-run on an existing instance — it only fires on first boot. Terraform will want to *replace* the instance if you edit the script. To re-pull without replacing, connect via SSM and run the docker commands manually, or use a proper CI/CD pipeline for redeploys.

- **To verify after launch,** connect with `aws ssm start-session --target <instance_id>` and run `docker ps` to confirm the container is running.