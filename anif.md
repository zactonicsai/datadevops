# The Complete Beginner's Guide: Keycloak + NiFi on AWS with Terraform

*Explained in plain language, step by step*

---

## Part 1: What Are We Building? (The Big Picture)

Imagine you're building a clubhouse with two rooms:

1. **The NiFi room** — This is where the fun stuff happens. Apache NiFi is a tool that moves data around, like a system of conveyor belts in a factory. Data comes in one side, gets sorted, changed, or cleaned, and goes out the other side.
2. **The Keycloak room** — This is the security desk at the front door. Keycloak is a program whose whole job is checking IDs. It keeps a list of usernames and passwords, and when someone wants to enter the NiFi room, Keycloak checks their ID first.

Instead of building these rooms in your house, we're renting them from **Amazon Web Services (AWS)**. Each "room" is a virtual computer called an **EC2 instance** (Elastic Compute Cloud — basically a computer you rent in Amazon's data center).

And instead of clicking around the AWS website to set everything up (which is slow and easy to mess up), we'll write our whole setup as code using **Terraform**. Terraform is like a LEGO instruction booklet: you write down exactly what you want built, and Terraform builds it for you — the same way, every single time.

Here's a picture of what we're building:

```
                        THE INTERNET
                             |
                    +--------+--------+
                    |   Your laptop    |
                    +--------+--------+
                             |
              ===============|===============
              |         AWS  VPC             |
              |     (your private network)   |
              |                              |
              |   +----------------------+   |
              |   |    Public Subnet     |   |
              |   |                      |   |
              |   |  +----------------+  |   |
              |   |  | Keycloak EC2   |  |   |
              |   |  | (security desk)|  |   |
              |   |  |   port 8080    |  |   |
              |   |  +-------+--------+  |   |
              |   |          |           |   |
              |   |  +-------+--------+  |   |
              |   |  |   NiFi EC2     |  |   |
              |   |  | (data factory) |  |   |
              |   |  |   port 8443    |  |   |
              |   |  +----------------+  |   |
              |   +----------------------+   |
              ================================
```

### The vocabulary you need (don't skip this!)

| Word | What it really means |
|------|---------------------|
| **EC2 instance** | A computer you rent from Amazon. It lives in their building, but you control it. |
| **VPC** | Virtual Private Cloud. Your own private, fenced-off section of Amazon's network. Like having your own gated neighborhood. |
| **Subnet** | A smaller street inside your gated neighborhood. A **public subnet** has a gate to the internet; a private one doesn't. |
| **Security Group** | A bouncer standing in front of each computer. It has a list of rules: "Only let in visitors knocking on door 8080" or "Only let in people from THIS address." |
| **Port** | A numbered door on a computer. Computers have 65,535 doors. Each program listens at a specific door. Web traffic usually uses door 80 or 443, SSH uses door 22, and so on. |
| **Terraform** | A tool that reads your "instruction booklet" (files ending in `.tf`) and builds cloud stuff automatically. |
| **Keycloak** | An open-source "identity provider." It stores users and passwords and hands out digital hall passes (tokens). |
| **Apache NiFi** | An open-source data-flow tool. Drag-and-drop boxes that move and transform data. |
| **Realm** | In Keycloak, a realm is like a separate school with its own list of students. Users in one realm don't exist in another. |
| **OIDC (OpenID Connect)** | The "language" NiFi and Keycloak use to talk about logins. It's a standard protocol, like how all mail uses envelopes with addresses in the same spot. |

### The ports we will use (memorize this table!)

| Port | Who uses it | What it's for |
|------|-------------|---------------|
| **22** | Both servers | SSH — the remote control that lets you type commands on the server from your laptop |
| **8080** | Keycloak | Keycloak's web page (HTTP — not encrypted, fine for learning, NOT for real production) |
| **8443** | NiFi | NiFi's web page (HTTPS — encrypted) |

---

## Part 2: What You Need Before Starting (Prerequisites)

1. **An AWS account** — sign up at aws.amazon.com. You'll need a credit card. ⚠️ **This tutorial costs money!** Roughly $0.06–$0.10 per hour for both servers. Delete everything when done (Part 9 shows how).
2. **Terraform installed** on your laptop — download from developer.hashicorp.com/terraform/downloads. Verify with:
   ```bash
   terraform -version
   ```
3. **AWS CLI installed and configured** — download from aws.amazon.com/cli, then run:
   ```bash
   aws configure
   ```
   It will ask for your **Access Key ID** and **Secret Access Key** (create these in AWS Console → IAM → Users → Security credentials → Create access key). Set your default region (this guide uses `us-east-1`).
4. **An SSH key pair** — this is like a physical key for your servers. Make one:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/tutorial-key
   ```
   Press Enter through the prompts. This creates two files:
   - `~/.ssh/tutorial-key` — your **private** key (NEVER share this)
   - `~/.ssh/tutorial-key.pub` — your **public** key (safe to share; we'll give it to AWS)
5. **Know your public IP address** — go to https://checkip.amazonaws.com and write it down. We'll use it to say "only MY laptop can connect."

---

## Part 3: The Terraform Project

### Step 3.1 — Make a project folder

```bash
mkdir keycloak-nifi-tutorial
cd keycloak-nifi-tutorial
```

We'll create 5 files in this folder:

```
keycloak-nifi-tutorial/
├── providers.tf      → tells Terraform "we're using AWS"
├── variables.tf      → the settings you can change
├── network.tf        → VPC, subnet, internet gateway (the neighborhood)
├── security.tf       → security groups (the bouncers)
├── servers.tf        → the two EC2 instances (the computers)
└── outputs.tf        → prints the IP addresses when done
```

### Step 3.2 — `providers.tf`

**What this does:** Tells Terraform which "plugin" to download (the AWS one) and which region of the world to build in.

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

### Step 3.3 — `variables.tf`

**What this does:** These are the knobs you can turn. Instead of burying your IP address deep in the code, we put it here at the top where it's easy to find and change.

```hcl
variable "aws_region" {
  description = "Which AWS data center region to use"
  type        = string
  default     = "us-east-1"
}

variable "my_ip" {
  description = "YOUR laptop's public IP address, with /32 on the end"
  type        = string
  # Example: "203.0.113.25/32"  <- replace with YOUR IP from checkip.amazonaws.com
  # The /32 means "exactly this one address, nobody else"
}

variable "public_key_path" {
  description = "Path to your SSH public key file"
  type        = string
  default     = "~/.ssh/tutorial-key.pub"
}

variable "keycloak_instance_type" {
  description = "Server size for Keycloak (needs about 2 GB of RAM)"
  type        = string
  default     = "t3.small"
}

variable "nifi_instance_type" {
  description = "Server size for NiFi (needs about 4 GB of RAM)"
  type        = string
  default     = "t3.medium"
}
```

> 🧠 **Why different sizes?** Keycloak is fairly lightweight — `t3.small` (2 GB of memory) is enough for learning. NiFi is a Java-heavy data engine and gets cranky with less than 4 GB, so it gets a `t3.medium`.

### Step 3.4 — `network.tf` (the neighborhood: VPC + Subnet)

**What this does:** Builds your private neighborhood (VPC), one street in it (a public subnet), the gate to the internet (internet gateway), and the road signs telling traffic how to reach the internet (route table).

```hcl
# ---------------------------------------------------------------
# 1. THE VPC — your private slice of AWS.
#    "10.0.0.0/16" means: this neighborhood can hold about
#    65,000 addresses, all starting with "10.0.x.x".
# ---------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "tutorial-vpc"
  }
}

# ---------------------------------------------------------------
# 2. THE PUBLIC SUBNET — one street in the neighborhood.
#    "10.0.1.0/24" means: this street has about 250 addresses,
#    all starting with "10.0.1.x".
#    map_public_ip_on_launch = true means: every computer that
#    moves onto this street automatically gets a PUBLIC address
#    so the internet can reach it.
# ---------------------------------------------------------------
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "tutorial-public-subnet"
  }
}

# ---------------------------------------------------------------
# 3. THE INTERNET GATEWAY — the gate between your neighborhood
#    and the internet. Without this, your servers are cut off.
# ---------------------------------------------------------------
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "tutorial-igw"
  }
}

# ---------------------------------------------------------------
# 4. THE ROUTE TABLE — road signs.
#    This rule says: "Any traffic going to 0.0.0.0/0 (which means
#    ANYWHERE on the internet), send it through the gate."
# ---------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "tutorial-public-routes"
  }
}

# ---------------------------------------------------------------
# 5. ATTACH the road signs to our street.
# ---------------------------------------------------------------
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
```

> 🧠 **What's with the slashes, like /16 and /24?** That's called CIDR notation. Think of it as saying how much of the address is "locked in." A bigger number after the slash = a smaller, more specific range. `/32` = exactly one address. `/24` = about 250 addresses. `/16` = about 65,000. `/0` = every address on Earth.

### Step 3.5 — `security.tf` (the bouncers: Security Groups)

**What this does:** Creates the two bouncers. Security groups work like this:
- **Ingress rules** = who's allowed IN, and through which door (port)
- **Egress rules** = who's allowed OUT (we allow everything out, which is normal)
- If a rule doesn't exist, the answer is **NO**. Security groups deny everything by default.

```hcl
# ---------------------------------------------------------------
# BOUNCER #1: The Keycloak security group.
# Rules:
#   - Door 22 (SSH): only YOUR laptop
#   - Door 8080 (Keycloak web page): open, because BOTH your
#     browser AND the NiFi server need to talk to Keycloak.
# ---------------------------------------------------------------
resource "aws_security_group" "keycloak" {
  name        = "keycloak-sg"
  description = "Rules for the Keycloak server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my laptop only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "Keycloak web + OIDC traffic"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # See warning below!
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means "all protocols"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "keycloak-sg"
  }
}

# ---------------------------------------------------------------
# BOUNCER #2: The NiFi security group.
# Rules:
#   - Door 22 (SSH): only YOUR laptop
#   - Door 8443 (NiFi web page): only YOUR laptop
# ---------------------------------------------------------------
resource "aws_security_group" "nifi" {
  name        = "nifi-sg"
  description = "Rules for the NiFi server"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my laptop only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "NiFi HTTPS web page from my laptop only"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nifi-sg"
  }
}
```

> ⚠️ **Why is Keycloak's port 8080 open to everyone (`0.0.0.0/0`)?** Two different "visitors" need to reach Keycloak:
> 1. **Your browser**, to see the login page.
> 2. **The NiFi server itself**, behind the scenes, to verify tokens. NiFi reaches out from its own public IP, which we don't know until after everything is built.
>
> For a learning lab, opening 8080 is the simplest fix. **In a real production system you would never do this** — you'd lock it down to specific IPs, put Keycloak behind HTTPS with a real certificate, and probably use a load balancer. Big warning delivered!

### Step 3.6 — `servers.tf` (the two computers)

**What this does:** Finds the newest Ubuntu Linux image, uploads your SSH public key, and launches the two servers. Each server has a **user_data** script — a to-do list the server runs automatically the very first time it turns on. Ours installs Docker and starts Keycloak/NiFi.

```hcl
# ---------------------------------------------------------------
# Find the newest Ubuntu 24.04 image automatically, so we never
# hard-code an outdated one.
# ---------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (the company behind Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------
# Upload your public key so you can SSH in later.
# ---------------------------------------------------------------
resource "aws_key_pair" "tutorial" {
  key_name   = "tutorial-key"
  public_key = file(var.public_key_path)
}

# ---------------------------------------------------------------
# SERVER #1: KEYCLOAK
# The user_data script:
#   1. installs Docker (a tool that runs apps in neat little boxes
#      called containers)
#   2. pulls the LATEST official Keycloak image
#   3. starts it in "dev mode" on port 8080 with an admin login
# ---------------------------------------------------------------
resource "aws_instance" "keycloak" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.keycloak_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.keycloak.id]
  key_name               = aws_key_pair.tutorial.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable --now docker

    docker run -d \
      --name keycloak \
      --restart unless-stopped \
      -p 8080:8080 \
      -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
      -e KC_BOOTSTRAP_ADMIN_PASSWORD=ChangeMeAdmin123! \
      quay.io/keycloak/keycloak:latest \
      start-dev
  EOF

  tags = {
    Name = "keycloak-server"
  }
}

# ---------------------------------------------------------------
# SERVER #2: NIFI
# Same idea: install Docker, pull the latest Apache NiFi image,
# start it in single-user HTTPS mode on port 8443.
# We'll switch it to Keycloak login in Part 7.
# ---------------------------------------------------------------
resource "aws_instance" "nifi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.nifi_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nifi.id]
  key_name               = aws_key_pair.tutorial.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable --now docker

    docker run -d \
      --name nifi \
      --restart unless-stopped \
      -p 8443:8443 \
      -e SINGLE_USER_CREDENTIALS_USERNAME=admin \
      -e SINGLE_USER_CREDENTIALS_PASSWORD=ChangeMeNifi12345! \
      -e NIFI_WEB_HTTPS_HOST=0.0.0.0 \
      -e NIFI_WEB_PROXY_HOST=0.0.0.0:8443 \
      apache/nifi:latest
  EOF

  tags = {
    Name = "nifi-server"
  }
}
```

> 🧠 **What's Docker and why use it?** Docker packages a program with everything it needs into a "container" — like a lunchbox that includes the food, fork, and napkin. Instead of installing Java, downloading NiFi, unzipping it, etc., we just say "run the NiFi lunchbox," and it works. The **latest Keycloak image** (`quay.io/keycloak/keycloak:latest`, currently version 26.7) comes straight from the Keycloak team.
>
> 🧠 **What's `start-dev`?** Keycloak's practice mode. It skips HTTPS requirements and database setup so you can learn. Real deployments use `start` with a proper database and certificates.
>
> ⚠️ **NIFI_WEB_PROXY_HOST=0.0.0.0:8443** — NiFi is picky about which web addresses it accepts. Setting this to `0.0.0.0:8443` tells it "accept any hostname" so you can reach it by its public IP. Fine for a lab; in production you'd set the real hostname.

### Step 3.7 — `outputs.tf`

**What this does:** After Terraform finishes, it prints the addresses you need — so you don't have to hunt through the AWS console.

```hcl
output "keycloak_public_ip" {
  description = "Public IP of the Keycloak server"
  value       = aws_instance.keycloak.public_ip
}

output "keycloak_url" {
  description = "Open this in your browser"
  value       = "http://${aws_instance.keycloak.public_ip}:8080"
}

output "nifi_public_ip" {
  description = "Public IP of the NiFi server"
  value       = aws_instance.nifi.public_ip
}

output "nifi_url" {
  description = "Open this in your browser (expect a certificate warning)"
  value       = "https://${aws_instance.nifi.public_ip}:8443/nifi"
}

output "ssh_keycloak" {
  value = "ssh -i ~/.ssh/tutorial-key ubuntu@${aws_instance.keycloak.public_ip}"
}

output "ssh_nifi" {
  value = "ssh -i ~/.ssh/tutorial-key ubuntu@${aws_instance.nifi.public_ip}"
}
```

---

## Part 4: Build It! (Running Terraform)

Run these three commands in your project folder. Terraform's workflow is always: **init → plan → apply**.

### Step 4.1 — Initialize

```bash
terraform init
```

This downloads the AWS plugin. Like opening the LEGO box and sorting the pieces. You only do this once per project.

### Step 4.2 — Plan (the dress rehearsal)

```bash
terraform plan -var 'my_ip=YOUR.IP.ADDRESS.HERE/32'
```

Replace `YOUR.IP.ADDRESS.HERE` with your IP from Part 2 (keep the `/32`!). Terraform shows you exactly what it *would* build — nothing is created yet. You should see something like `Plan: 10 to add, 0 to change, 0 to destroy.`

### Step 4.3 — Apply (build for real)

```bash
terraform apply -var 'my_ip=YOUR.IP.ADDRESS.HERE/32'
```

Type `yes` when asked. In 2–3 minutes, Terraform prints your outputs:

```
keycloak_url = "http://54.12.34.56:8080"
nifi_url     = "https://54.98.76.54:8443/nifi"
...
```

**Write these down!** We'll call them `KEYCLOAK_IP` and `NIFI_IP` from now on.

> ⏰ **Be patient:** the servers need another 3–5 minutes *after* Terraform finishes to download Docker and the container images. If a page won't load, get a snack and try again.

### Step 4.4 — Check that both are alive

- Open `http://KEYCLOAK_IP:8080` → you should see the Keycloak welcome/login page.
- Open `https://NIFI_IP:8443/nifi` → your browser will scream about an untrusted certificate. That's expected! NiFi made its own "self-signed" certificate, which is like a homemade ID card — real encryption, but no official stamp. Click **Advanced → Proceed anyway**. Log in with `admin` / `ChangeMeNifi12345!`.

---

## Part 5: Set Up Keycloak (Realm, Client, and Users)

Time to configure the security desk.

### Step 5.1 — Log in as admin

1. Go to `http://KEYCLOAK_IP:8080`
2. Username: `admin`, Password: `ChangeMeAdmin123!`

### Step 5.2 — Create the NiFi realm

Remember: a **realm** is a separate school with its own student list.

1. In the top-left corner there's a dropdown that says **Keycloak** (or "master"). Click it.
2. Click **Create realm**.
3. **Realm name:** `nifi` (all lowercase — exact spelling matters later!)
4. Click **Create**.

You're now inside the `nifi` realm. Everything we do next happens here.

### Step 5.3 — Create a client for NiFi

A **client** is an app that's allowed to ask Keycloak "hey, is this person legit?" NiFi will be that app.

1. Left menu → **Clients** → **Create client**
2. **General settings:**
   - Client type: `OpenID Connect`
   - Client ID: `nifi`
   - Click **Next**
3. **Capability config:**
   - **Client authentication: ON** ← important! This makes it a "confidential" client with a secret password of its own.
   - Leave **Standard flow** checked.
   - Click **Next**
4. **Login settings:**
   - **Valid redirect URIs:**
     ```
     https://NIFI_IP:8443/nifi-api/access/oidc/callback
     ```
   - **Valid post logout redirect URIs:**
     ```
     https://NIFI_IP:8443/nifi-api/access/oidc/logout/callback
     ```
   - (Replace `NIFI_IP` with your actual NiFi IP!)
   - Click **Save**

> 🧠 **What's a redirect URI?** After Keycloak checks someone's password, it has to send them *back* to NiFi with their hall pass. The redirect URI is the exact return address. Keycloak refuses to send people anywhere not on this list — it's a safety feature so hall passes can't be stolen by fake websites.

### Step 5.4 — Copy the client secret

1. Open your new `nifi` client → **Credentials** tab
2. Copy the **Client Secret** (a long random string) and save it somewhere. NiFi needs it in Part 7. This is like a password that proves NiFi is really NiFi.

### Step 5.5 — Create users

Let's enroll two students in our school:

**User 1 — Alice (she'll be the NiFi administrator):**
1. Left menu → **Users** → **Create new user** (or **Add user**)
2. Username: `alice`
3. Email: `alice@example.com`
4. Email verified: **ON** (toggle it)
5. First name: `Alice`, Last name: `Anderson`
6. Click **Create**
7. Go to the **Credentials** tab → **Set password**
   - Password: `AlicePassword123!`
   - **Temporary: OFF** (otherwise she'd be forced to change it on first login)
   - Click **Save**

**User 2 — Bob (a regular user):**

Repeat the same steps with:
- Username: `bob`, Email: `bob@example.com`, Email verified: ON
- First name: `Bob`, Last name: `Brown`
- Password: `BobPassword123!`, Temporary: OFF

### Step 5.6 — Test a login (optional but smart)

Open a private/incognito browser window and go to:

```
http://KEYCLOAK_IP:8080/realms/nifi/account
```

Log in as `alice`. If you see her account page, your realm works! 🎉

---

## Part 6: Understanding the Handshake (How NiFi + Keycloak Talk)

Before we wire them together, here's what will happen every time someone logs in. This dance is called the **OIDC Authorization Code Flow**:

```
 You                NiFi                    Keycloak
  |                  |                         |
  |--"Let me in!"--->|                         |
  |                  |                         |
  |<--"Go ask the security desk" (redirect)----|
  |                                            |
  |--"Hi, I'm alice, password is..."---------->|
  |                                            |
  |<--"OK! Take this code back to NiFi"--------|
  |                  |                         |
  |--hands code----->|                         |
  |                  |--"Is this code real?"-->|
  |                  |   (uses client secret)  |
  |                  |<--"Yes! Here's alice's--|
  |                  |    ID token"            |
  |<--"Welcome in!"--|                         |
```

Key idea: **NiFi never sees Alice's password.** Only Keycloak does. NiFi just gets a signed, tamper-proof note saying "this is really alice@example.com — signed, Keycloak."

The address NiFi uses to find Keycloak is called the **discovery URL**. It's a menu of all Keycloak's endpoints, published at a standard location:

```
http://KEYCLOAK_IP:8080/realms/nifi/.well-known/openid-configuration
```

Paste that into your browser right now — you'll see a big page of JSON. If you see it, NiFi will be able to see it too.

---

## Part 7: Configure NiFi to Use Keycloak

Now we tell NiFi: "Stop using your own little password list. From now on, send everyone to Keycloak."

### Step 7.1 — SSH into the NiFi server

```bash
ssh -i ~/.ssh/tutorial-key ubuntu@NIFI_IP
```

(Type `yes` if asked about fingerprints.)

### Step 7.2 — Edit NiFi's settings inside the container

NiFi's brain lives in a file called `nifi.properties`. We'll change five settings. Copy-paste this whole block **after replacing the two placeholders** (`KEYCLOAK_IP` and `YOUR_CLIENT_SECRET`):

```bash
# ==== EDIT THESE TWO LINES FIRST ====
KEYCLOAK_IP="54.12.34.56"                  # your Keycloak public IP
CLIENT_SECRET="YOUR_CLIENT_SECRET"          # from Keycloak, Step 5.4
# ====================================

P=/opt/nifi/nifi-current/conf/nifi.properties

# 1. Tell NiFi where Keycloak's "menu" (discovery document) is
sudo docker exec nifi sed -i \
  "s|^nifi.security.user.oidc.discovery.url=.*|nifi.security.user.oidc.discovery.url=http://$KEYCLOAK_IP:8080/realms/nifi/.well-known/openid-configuration|" $P

# 2. Tell NiFi its client ID (its name at the security desk)
sudo docker exec nifi sed -i \
  "s|^nifi.security.user.oidc.client.id=.*|nifi.security.user.oidc.client.id=nifi|" $P

# 3. Tell NiFi its client secret (its own password at the desk)
sudo docker exec nifi sed -i \
  "s|^nifi.security.user.oidc.client.secret=.*|nifi.security.user.oidc.client.secret=$CLIENT_SECRET|" $P

# 4. Use the email address as each person's identity in NiFi
sudo docker exec nifi sed -i \
  "s|^nifi.security.user.oidc.claim.identifying.user=.*|nifi.security.user.oidc.claim.identifying.user=email|" $P

# 5. Ask Keycloak for profile + email info during login
sudo docker exec nifi sed -i \
  "s|^nifi.security.user.oidc.additional.scopes=.*|nifi.security.user.oidc.additional.scopes=profile,email|" $P

# 6. Turn OFF the built-in single-user login (only one login system at a time!)
sudo docker exec nifi sed -i \
  "s|^nifi.security.user.login.identity.provider=.*|nifi.security.user.login.identity.provider=|" $P

# 7. Switch to the "managed authorizer" which supports OIDC users
sudo docker exec nifi sed -i \
  "s|^nifi.security.user.authorizer=.*|nifi.security.user.authorizer=managed-authorizer|" $P
```

### Step 7.3 — Make Alice the boss (Initial Admin)

Logging in (**authentication** — "who are you?") is only half the story. NiFi also checks **authorization** — "what are you allowed to do?" Brand-new users can do *nothing* until an admin grants permissions. So we must tell NiFi who the very first admin is. That lives in a different file, `authorizers.xml`:

```bash
A=/opt/nifi/nifi-current/conf/authorizers.xml

# Set Alice's email as the Initial Admin Identity (appears twice in the file)
sudo docker exec nifi sed -i \
  's|<property name="Initial Admin Identity">.*</property>|<property name="Initial Admin Identity">alice@example.com</property>|g' $A

sudo docker exec nifi sed -i \
  's|<property name="Initial User Identity 1">.*</property>|<property name="Initial User Identity 1">alice@example.com</property>|g' $A
```

> ⚠️ **The identity must match EXACTLY.** We told NiFi to identify people by their `email` claim (Step 7.2, #4), and Alice's email in Keycloak is `alice@example.com`. If these don't match letter-for-letter, Alice will log in successfully but see "insufficient permissions."

### Step 7.4 — Restart NiFi

```bash
sudo docker restart nifi
```

Wait 2–3 minutes (NiFi is a slow waker-upper). Watch it boot if you're curious:

```bash
sudo docker logs -f nifi
```

Press `Ctrl+C` to stop watching. When you see `Started Application Controller`, it's ready.

### Step 7.5 — The moment of truth 🎉

1. Open a **fresh private/incognito window** (old cookies cause confusion).
2. Go to `https://NIFI_IP:8443/nifi`
3. Click through the certificate warning again.
4. **NiFi should now bounce you to the Keycloak login page!**
5. Log in as `alice` / `AlicePassword123!`
6. You land back inside the NiFi canvas, logged in as **alice@example.com**, with full admin powers.

### Step 7.6 — Give Bob permission

Try logging in as Bob (new incognito window): he'll authenticate fine but see a "no permissions" message. That's authorization at work! To fix it, log in as Alice and:

1. Click the **hamburger menu** (☰, top right) → **Users** → **+** → add `bob@example.com`
2. Then ☰ → **Policies** → pick a policy like **view the user interface** → **+** → add Bob.

Now Bob can log in and see the canvas, but he can't change anything unless Alice grants more policies. Alice is the principal; Bob is a student with a hall pass. 🏫

---

## Part 8: Troubleshooting (When Things Go Wrong)

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Keycloak page won't load | Server still installing Docker/image | Wait 5 min. SSH in and run `sudo docker ps` — you should see the keycloak container. `sudo docker logs keycloak` shows details. |
| NiFi page won't load | Same as above, or wrong URL | NiFi needs `https://` and the `/nifi` path. Give it 3+ min after restart. |
| Browser blocks NiFi entirely | Self-signed certificate | Click Advanced → Proceed. Some corporate laptops forbid this. |
| "Invalid redirect URI" error from Keycloak | Redirect URI in the client doesn't exactly match | In Keycloak → Clients → nifi → check the URI. It must be `https://NIFI_IP:8443/nifi-api/access/oidc/callback` — exact IP, exact path, no trailing slash. |
| Login works but "insufficient permissions" | Identity mismatch | The Initial Admin Identity (`alice@example.com`) must exactly match the email claim from Keycloak — same case, same spelling. Check `sudo docker logs nifi` for the identity NiFi actually saw. Also: NiFi only reads Initial Admin Identity when its `users.xml`/`authorizations.xml` don't exist yet. If you got it wrong once, delete them and restart: `sudo docker exec nifi rm /opt/nifi/nifi-current/conf/users.xml /opt/nifi/nifi-current/conf/authorizations.xml && sudo docker restart nifi` |
| NiFi can't reach the discovery URL | Security group or wrong IP | From the NiFi server run: `curl http://KEYCLOAK_IP:8080/realms/nifi/.well-known/openid-configuration` — if it fails, check the Keycloak security group allows port 8080. |
| Everything broke and you're sad | Nuclear option | `terraform destroy`, then `terraform apply` again. Fresh start in 5 minutes. That's the beauty of Terraform. |

---

## Part 9: Clean Up (Don't Get a Surprise Bill!)

When you're done playing, tear everything down with one command:

```bash
terraform destroy -var 'my_ip=YOUR.IP.ADDRESS.HERE/32'
```

Type `yes`. Terraform deletes both servers, the security groups, the subnet, the VPC — everything it built, in the correct order. This is the superpower of infrastructure-as-code: **build it, break it, rebuild it, delete it — all with a few keystrokes.**

Double-check in the AWS Console (EC2 → Instances) that both instances say "terminated."

---

## Part 10: What You'd Change for the Real World

This lab cuts corners on purpose so you can learn. A production setup would add:

1. **HTTPS everywhere** — Keycloak behind a real TLS certificate (e.g., from Let's Encrypt) and a proper domain name, not a raw IP. OIDC over plain HTTP is only acceptable in a lab.
2. **A real database for Keycloak** — dev mode uses a throwaway file database. Production uses PostgreSQL, and `start` instead of `start-dev`.
3. **Private subnets** — the servers would live on a private street with no internet gate, reachable only through a load balancer or bastion host.
4. **Tighter security groups** — no `0.0.0.0/0` on port 8080. Server-to-server rules would reference security group IDs instead of IPs.
5. **Secrets management** — the client secret and admin passwords would live in AWS Secrets Manager, never in plain text or Terraform files.
6. **Remote Terraform state** — the `terraform.tfstate` file would be stored in S3 with locking, so a team can share it safely.
7. **Real certificates for NiFi** — no more browser warnings.

---

## Quick Reference Card

| Thing | Value |
|-------|-------|
| Keycloak admin console | `http://KEYCLOAK_IP:8080` (admin / ChangeMeAdmin123!) |
| Keycloak realm | `nifi` |
| Keycloak client ID | `nifi` (confidential, secret in Credentials tab) |
| Discovery URL | `http://KEYCLOAK_IP:8080/realms/nifi/.well-known/openid-configuration` |
| NiFi UI | `https://NIFI_IP:8443/nifi` |
| Redirect URI | `https://NIFI_IP:8443/nifi-api/access/oidc/callback` |
| Logout URI | `https://NIFI_IP:8443/nifi-api/access/oidc/logout/callback` |
| NiFi admin user | alice@example.com / AlicePassword123! |
| Regular user | bob@example.com / BobPassword123! |
| Ports | 22 = SSH, 8080 = Keycloak, 8443 = NiFi |
| Versions used | Keycloak 26.7.x (`:latest`), Apache NiFi 2.10.x (`:latest`) |

You did it! You built a private network, launched two servers with code, stood up an identity provider, and wired a data-flow tool to use single sign-on. That's a genuinely professional skill set. 🚀
