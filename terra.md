# Terraform + AWS: A Friendly Tutorial You Can Actually Understand

*Written so a middle schooler could follow it, but deep enough to actually build real systems.*

-----

## Table of Contents

1. [What Even Is Terraform? (The Big Idea)](#part-1)
1. [What Is AWS and What Are We Building?](#part-2)
1. [How to Read a Terraform File (Line by Line)](#part-3)
1. [Every Keyword and Tag, Explained](#part-4)
1. [Building EC2 Servers (Kafka, NiFi, Postgres)](#part-5)
1. [Building Load Balancers](#part-6)
1. [Building an EKS Cluster (Kubernetes)](#part-7)
1. [Multi-Tenant EKS: The Deep Dive](#part-8)
1. [Putting It All Together](#part-9)
1. [Glossary (Cheat Sheet)](#glossary)

-----

<a name="part-1"></a>

## Part 1: What Even Is Terraform? (The Big Idea)

### The LEGO instruction sheet analogy

Imagine you build an amazing LEGO castle. It has towers, a drawbridge, little flags — everything. Your friend across town wants the *exact same* castle. How do you help them?

You could call them on the phone and describe every single brick. That would take hours, and they’d probably mess something up. **OR** you could write down the instructions: “Take 4 red bricks, stack them here. Add 1 blue brick on top.” Then you hand them the instruction sheet, and they build the identical castle perfectly.

**Terraform is the instruction sheet for building computer systems on the internet.**

Instead of clicking around on a website for hours to set up servers (and forgetting what you did), you write down the instructions in a file. Then Terraform reads your file and builds *everything* automatically. If you want to build it again, you just run the file again. If your friend wants the same setup, you hand them the file.

### Why this matters (the problem it solves)

Before Terraform, people built their internet systems by hand. They’d log into a website, click “create server,” fill out forms, click more buttons, and so on. This caused three big problems:

**Problem 1 — Forgetting.** Six months later, nobody remembers exactly which 200 buttons they clicked. If the system breaks, good luck rebuilding it.

**Problem 2 — Mistakes.** Humans clicking buttons make typos and skip steps. One forgotten checkbox can take down a whole company’s website.

**Problem 3 — Copying is painful.** A company often needs the same setup three times: one for testing (called “dev”), one for almost-final testing (“staging”), and one for real customers (“production”). Clicking it all out three times by hand is slow and error-prone.

Terraform fixes all three. Your instructions live in a file, so nothing is forgotten. The computer follows them exactly, so no human mistakes. And you can build the same thing as many times as you want.

This whole idea has a fancy name: **Infrastructure as Code (IaC)**. “Infrastructure” means the computer servers and networking. “As Code” means we describe it in a text file like a program. So: *describing your servers using a text file.*

### The magic word: “declarative”

Terraform is **declarative**. That’s a big word with a simple meaning. It means **you describe what you WANT, not the steps to get there.**

Think about ordering pizza. You tell the restaurant, “I want a large pepperoni pizza.” You do NOT say, “First knead the dough, then add sauce, then sprinkle cheese…” You just declare the end result you want, and they figure out how to make it.

Terraform works the same way. You write, “I want 3 servers and a load balancer.” You don’t write the step-by-step. Terraform looks at what you want, compares it to what already exists, and figures out the steps to make reality match your wish. This is different from older tools where you had to spell out every single step in order.

### How Terraform actually works (the three-step dance)

When you use Terraform, you mostly run three commands. Here’s the dance:

**Step 1: `terraform init`** — This is “get ready.” Terraform downloads the tools it needs to talk to AWS (or whatever cloud you’re using). You run this once when you start a project. Think of it as unpacking your toolbox before a project.

**Step 2: `terraform plan`** — This is “show me what you’re about to do.” Terraform reads your file, looks at what already exists in the real world, and then prints a preview: “I will CREATE 3 servers. I will CHANGE 1 load balancer. I will DESTROY nothing.” Nothing actually happens yet — it’s just a preview. This is your chance to catch mistakes before they’re real. Always read the plan!

**Step 3: `terraform apply`** — This is “okay, do it for real.” Terraform actually builds everything. It shows you the plan one more time and asks “are you sure?” You type `yes`, and it goes to work.

There’s also a fourth command for when you’re done:

**`terraform destroy`** — This is “tear it all down.” It deletes everything Terraform built. Super useful for test environments you don’t need anymore, so you stop paying for them. (Yes — you pay money for these servers by the hour, so deleting unused ones saves real money.)

### The “state file” — Terraform’s memory

Here’s something important. Terraform keeps a special memory file called the **state file** (named `terraform.tfstate`). This is Terraform’s diary of everything it has built.

Why does it need a diary? Because when you run `plan`, Terraform needs to compare three things:

1. What you WANT (your `.tf` files)
1. What Terraform THINKS exists (the state file / its memory)
1. What ACTUALLY exists (the real AWS account)

By comparing these, it figures out what to add, change, or remove. Without the state file, Terraform would have amnesia and not know what it built before.

**Big safety rule:** The state file can contain secrets (like passwords). In a real company, you never store it on your laptop. You store it in a shared, locked, safe place — usually an AWS S3 bucket (think of S3 as Google Drive for companies) with locking turned on so two people can’t edit it at the same time and corrupt it. We’ll show this later.

-----

<a name="part-2"></a>

## Part 2: What Is AWS and What Are We Building?

### AWS in one sentence

**AWS (Amazon Web Services) is a giant company that rents out computers over the internet.** Instead of buying your own expensive servers and keeping them in your basement, you rent Amazon’s computers by the hour. Need 100 servers for one day? Rent them, use them, give them back. You only pay for what you use.

AWS offers hundreds of different services. We’ll focus on the ones you asked about. Here’s the cast of characters for our tutorial:

### The systems we’re going to build

Let me introduce each piece in plain language, because the names sound scary but the ideas are simple.

**EC2 — the basic rental computer.** EC2 stands for “Elastic Compute Cloud,” but just think: *a computer you rent from Amazon.* “Elastic” means you can get more or fewer whenever you want. We’ll put three programs on EC2 computers: Kafka, NiFi, and Postgres.

**Kafka — the post office for data.** Imagine a giant, super-fast post office. Programs drop off messages, and other programs pick them up. Kafka makes sure messages get delivered in order and nothing gets lost, even when millions of messages fly through every second. Companies use it so different parts of their system can talk to each other without getting tangled up. (Real name: Apache Kafka.)

**NiFi — the conveyor belt for data.** NiFi (say “nigh-fy”) is like a conveyor belt system in a factory. It picks up data from one place, cleans it, reshapes it, and drops it somewhere else. You draw the conveyor belts on a screen by dragging boxes and arrows. It’s used to move and transform data automatically. (Real name: Apache NiFi.)

**Postgres — the filing cabinet.** Postgres (full name PostgreSQL, say “post-gres-cue-el”) is a **database** — a super-organized digital filing cabinet that stores information in neat tables (like a giant spreadsheet) and lets you look things up instantly. When an app needs to remember something (your username, your high score), it usually lives in a database like Postgres.

**EKS — the robot manager for many small programs.** EKS stands for “Elastic Kubernetes Service.” To understand it, first understand **containers**: a container is a program packed into a tidy lunchbox with everything it needs to run, so it works the same anywhere. Now imagine you have *hundreds* of these lunchboxes and you need someone to decide which computer each one runs on, restart them if they crash, and add more when things get busy. That manager is called **Kubernetes**, and **EKS is Amazon running Kubernetes for you** so you don’t have to babysit it yourself. (We’ll go very deep on this later, including the “multi-tenant” part.)

**Load Balancer — the traffic cop.** If a million people visit your website at once, one computer would melt. So you run several copies and put a **load balancer** in front. It’s a traffic cop that sends each visitor to whichever computer is the least busy. This keeps your site fast and means if one computer dies, the cop just stops sending people to it — visitors never notice.

### How they fit together (the restaurant analogy)

Picture a busy restaurant:

- The **load balancer** is the host at the front, sending customers to open tables.
- The **EKS cluster** is the kitchen full of cooks (containers), each making one dish, with a head chef (Kubernetes) assigning work.
- **Kafka** is the order-ticket rail where waiters clip orders and cooks grab them.
- **NiFi** is the prep station that washes and chops ingredients before cooking.
- **Postgres** is the recipe book and the record of every order ever made.

All these pieces work together. And we’re going to describe *all of them* in Terraform files. Let’s learn to read those files first.

-----

<a name="part-3"></a>

## Part 3: How to Read a Terraform File (Line by Line)

### The file extension

Terraform files end in **`.tf`**. You can have one giant file or split things across many `.tf` files in a folder — Terraform reads them all together as if they were one. People usually split them up to stay organized, like:

- `main.tf` — the main stuff you’re building
- `variables.tf` — the settings you might change
- `outputs.tf` — info you want printed at the end
- `providers.tf` — which cloud you’re talking to

The names don’t matter to Terraform; they’re just for humans. Terraform smushes all `.tf` files in the folder together.

### The shape of every block

Almost everything in Terraform is written in a shape called a **block**. Once you learn this one shape, you can read 90% of any Terraform file. Here’s the shape:

```hcl
block_type "label_one" "label_two" {
  setting_name = "setting_value"
  other_setting = 42
}
```

This language is called **HCL** (HashiCorp Configuration Language — HashiCorp is the company that made Terraform). Let me break the shape down piece by piece.

- **`block_type`** — What *kind* of thing this is. The most common is `resource`, which means “a real thing I want to build.”
- **`"label_one"`** — Usually *what type of resource*. For example `"aws_instance"` means “an AWS EC2 computer.”
- **`"label_two"`** — *Your nickname* for this specific thing, so you can refer to it later. You pick this name. Like naming a pet.
- **The `{ ... }` curly braces** — Everything inside describes the settings for this thing.
- **`setting = value`** — Each line sets one property. The thing on the left is the setting’s name (called an **argument** or **attribute**), and the thing on the right is what you’re setting it to.

### A real example, fully decoded

Let’s read an actual block that creates one rented computer:

```hcl
resource "aws_instance" "web_server" {
  ami           = "ami-0abcd1234"
  instance_type = "t3.micro"

  tags = {
    Name = "MyFirstServer"
  }
}
```

Reading it out loud in plain English, left to right, top to bottom:

> “I want a **resource** (a real thing). It’s an **aws_instance** (an AWS rental computer). I’ll nickname it **web_server**. Its starting software image (**ami**) is the one called ami-0abcd1234. Its size (**instance_type**) is t3.micro, which is a small, cheap one. And I’m sticking a **tag** (a sticky label) on it that says its **Name** is MyFirstServer.”

That’s it! That block, run through `terraform apply`, creates a real computer in the cloud. Every Terraform file is just stacks of blocks like this.

### Referring to one thing from another (the secret handshake)

Here’s where Terraform gets powerful. Things can point at each other. Suppose you build a network and then want to put a computer *inside* that network. You reference the network by its address, which follows this pattern:

```
resource_type.nickname.attribute
```

For example:

```hcl
resource "aws_vpc" "my_network" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "my_subnet" {
  vpc_id     = aws_vpc.my_network.id
  cidr_block = "10.0.1.0/24"
}
```

See the line `vpc_id = aws_vpc.my_network.id`? That’s the subnet saying: “Put me inside the network. *Which* network? The `aws_vpc` one I nicknamed `my_network`. Use its `id`.”

You don’t have to know the network’s ID yourself — Terraform fills it in automatically after it builds the network. This referencing also tells Terraform the **order** to build things: it knows it must build the network *before* the subnet, because the subnet depends on it. Terraform builds a mental map of these dependencies automatically. This map is called a **dependency graph**, and it’s why you don’t usually have to tell Terraform what order to do things in.

### Comments (notes to yourself)

Anything after a `#` or `//` on a line is a **comment** — Terraform ignores it. It’s just a note for humans reading the file. Use comments to explain *why* you did something.

```hcl
# This server runs our website. Do not delete on Fridays!
resource "aws_instance" "web_server" {
  instance_type = "t3.large"  # Bumped up from micro because traffic grew
}
```

-----

<a name="part-4"></a>

## Part 4: Every Keyword and Tag, Explained

Now let’s go through every important word you’ll see in Terraform files. I’ll explain each one, what it does, and when you use it. Think of this as your decoder ring.

### The five block types

There are five main `block_type` words. Here’s each one:

**1. `resource` — “Build me a real thing.”**
This is the workhorse. A `resource` block creates an actual thing in the cloud: a server, a network, a database. 95% of your blocks will be resources.

```hcl
resource "aws_instance" "kafka_node" {
  instance_type = "m5.large"
}
```

**2. `data` — “Look up something that already exists.”**
Sometimes you don’t want to *build* a thing — you just want to *find* an existing thing and use its info. A `data` block (called a “data source”) looks things up without changing anything. For example, “find me the newest official Ubuntu image.”

```hcl
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical, the company that makes Ubuntu
}
```

The difference between `resource` and `data` is simple: **`resource` builds, `data` only reads.**

**3. `variable` — “A setting someone can fill in.”**
A `variable` is a blank you can fill in later, like `___` in a worksheet. Instead of hard-coding the number of servers, you make it a variable, so you can change it without editing your main code. This makes your code reusable.

```hcl
variable "server_count" {
  description = "How many servers to create"
  type        = number
  default     = 3
}
```

You then use it elsewhere by writing `var.server_count`.

**4. `output` — “Print this when you’re done.”**
An `output` shows you useful info after Terraform finishes — like the website address of the thing you just built, so you don’t have to go hunting for it.

```hcl
output "website_address" {
  value = aws_instance.web_server.public_ip
}
```

**5. `provider` — “Which cloud am I talking to?”**
A `provider` block tells Terraform *which* service to talk to (AWS, Google, Microsoft, etc.) and basic settings like which region of the world to build in.

```hcl
provider "aws" {
  region = "us-east-1"  # Build in Amazon's Northern Virginia data centers
}
```

There’s also a special `terraform` block (lowercase, exactly that word) that sets up Terraform itself — like which version to use and where to keep the state file. More on that in Part 9.

### The argument words you’ll see constantly

These are the `setting = value` lines that show up over and over. Here’s what each commonly-seen one means:

**`ami`** — “Amazon Machine Image.” The starting software for a computer — basically which operating system and pre-installed programs it boots up with. Like choosing whether a new phone comes with Android or iOS. Every AMI has an ID like `ami-0abcd1234`.

**`instance_type`** — The *size* of the computer: how much brain (CPU) and memory (RAM) it has. Names look like `t3.micro` (tiny, cheap), `m5.large` (medium), or `r5.4xlarge` (huge, for memory-hungry jobs). Bigger = faster = more expensive per hour.

**`tags`** — Sticky labels you attach to things. They don’t change how the thing works; they’re just notes that help you organize, search, and track costs. You’ll see `tags` *everywhere*. We’ll cover them in depth in the next section because you specifically asked.

**`cidr_block`** — A way of describing a *range* of network addresses. `10.0.0.0/16` means “all addresses that start with 10.0.” It’s like saying “all houses on Maple Street.” We’ll explain the weird `/16` and `/24` numbers below.

**`vpc_id`, `subnet_id`, `security_group_id`** — These are all “put me inside *that* thing” pointers, referencing a network, a sub-network, or a firewall by its ID.

**`count`** — “Make this many copies.” If you write `count = 3`, Terraform makes three identical things. Great for making a fleet of servers.

```hcl
resource "aws_instance" "kafka" {
  count         = 3   # Creates kafka[0], kafka[1], kafka[2]
  instance_type = "m5.large"
}
```

**`for_each`** — A fancier version of `count`. Instead of “make 3 copies,” it’s “make one for each item in this list,” and each gets a name. Use it when your copies are slightly different from each other.

**`depends_on`** — “Build this *after* that, even though I didn’t reference it.” Usually Terraform figures out order on its own, but occasionally you must spell it out. This is the manual override.

**`lifecycle`** — Special rules about how to treat a thing. The famous one is `prevent_destroy = true`, which means “NEVER delete this, even if I ask by accident” — perfect for a production database you can’t afford to lose.

```hcl
resource "aws_instance" "production_db" {
  lifecycle {
    prevent_destroy = true  # Safety lock!
  }
}
```

### Things that make blocks reusable

**`module`** — A *bundle* of Terraform blocks you can reuse as one unit. Imagine someone already wrote all the instructions for “a complete network setup,” packed it into a box, and now you just use the box without redoing the work. A module is that box. You’ll use modules a lot in real projects so you’re not reinventing the wheel.

```hcl
module "network" {
  source = "terraform-aws-modules/vpc/aws"  # Use this pre-made bundle
  name   = "my-network"
}
```

**`locals`** — Nicknames for values you reuse a lot inside one project. If you keep typing the same long thing, make it a local once and reference it as `local.thing`. It’s like a shortcut.

```hcl
locals {
  common_name = "acme-prod"
}
```

### Understanding those network numbers (CIDR)

You’ll keep seeing things like `10.0.0.0/16` and `10.0.1.0/24`. Let me demystify these once and for all.

Every computer on a network has an **IP address** — its house number — like `10.0.1.5`. A **CIDR block** describes a *whole neighborhood* of these addresses. The number after the slash tells you how big the neighborhood is. Here’s the counterintuitive part: **a SMALLER number after the slash means a BIGGER neighborhood.**

- `/16` is a big neighborhood (about 65,000 addresses). `10.0.0.0/16` = “everything starting with 10.0.”
- `/24` is a small neighborhood (256 addresses). `10.0.1.0/24` = “everything starting with 10.0.1.”
- `/32` is a single house (1 address).

Why backwards? The slash number is how many digits are “locked.” More locked digits = fewer free digits = fewer possible houses. You usually make one big `/16` network (the VPC) and chop it into several `/24` sub-networks (the subnets). Think: one big city, divided into streets.

-----

<a name="part-4-tags"></a>

## Part 4.5: Tags — The Sticky Labels (Deep Dive)

You specifically asked about tags, so let’s spend real time here, because tags are one of the most important and most *underestimated* parts of building cloud systems.

### What a tag actually is

A **tag** is a little sticky label made of two parts: a **key** (the label’s name) and a **value** (what it says). Together they’re a “key-value pair.” In Terraform they look like this:

```hcl
tags = {
  Name        = "kafka-broker-1"
  Environment = "production"
  Team        = "data-platform"
  CostCenter  = "12345"
  ManagedBy   = "terraform"
}
```

Each line is one tag. `Name` is a key, `"kafka-broker-1"` is its value. The thing now wears five sticky labels.

**Tags do not change how the thing works.** A server with the tag `Environment = production` works identically to one with no tags. So why bother? Because when you have *hundreds* of servers, tags are the only way to stay sane. Here’s what they’re actually for.

### Why tags matter (the four superpowers)

**Superpower 1 — Finding things.** With 500 servers, you can’t remember what each one does. But you can search: “show me everything tagged `Team = data-platform`.” Instantly you see only your team’s servers. Tags are how you filter a giant pile down to what you care about.

**Superpower 2 — Tracking money.** This is huge. AWS charges money, and the bill can be enormous. With tags, AWS can break the bill down: “the `marketing` team spent $4,000, the `data-platform` team spent $11,000.” Without tags, you get one giant unexplained bill and no idea who’s spending what. The tag that does this is often called `CostCenter` or `Team`. Companies *require* these tags so they can split the bill fairly.

**Superpower 3 — Automation and safety rules.** Computers can read tags and act on them. You can write a rule like “every night, turn off all servers tagged `Environment = dev` to save money” (nobody works at night, so why pay?). Or “never let anyone delete things tagged `Environment = production`.” Or “automatically back up anything tagged `Backup = daily`.” Tags become instructions for robots.

**Superpower 4 — Knowing who’s in charge.** When something breaks at 2 AM, the tag `Team = data-platform` or `Owner = jane@company.com` tells you exactly who to wake up. The tag `ManagedBy = terraform` reminds everyone “don’t hand-edit this — it’ll get overwritten by the Terraform file.”

### The special `Name` tag

One tag is extra special: the tag with the key **`Name`** (capital N). AWS uses it as the *display name* in its website dashboard. So when you log into AWS and look at your servers, the `Name` tag is the friendly name you see in the list. Without it, you’d just see scary IDs like `i-0a1b2c3d4e`. Always set a `Name` tag so you can tell your things apart at a glance.

```hcl
tags = {
  Name = "postgres-primary-db"   # This is what shows in the AWS dashboard
}
```

### Don’t repeat yourself: `default_tags`

In a real project, you want *every single thing* to have the same baseline tags (like `Environment`, `Team`, `ManagedBy`). Copy-pasting them onto 200 resources would be miserable and easy to mess up. So AWS’s provider lets you set **default tags** once, at the top, and they automatically stick to everything:

```hcl
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = "production"
      Team        = "data-platform"
      ManagedBy   = "terraform"
    }
  }
}
```

Now every resource you build gets those three tags for free, without you typing them again. You only add *specific* tags (like a unique `Name`) on each individual resource. This is the professional way to do it: set the common stuff once, add the unique stuff per-thing.

### A smart pattern: build tags with `locals`

Pros often define their tags in one `locals` block and reuse them, sometimes merging in extras. Here’s a clean pattern you’ll see in good codebases:

```hcl
locals {
  common_tags = {
    Environment = "production"
    Team        = "data-platform"
    ManagedBy   = "terraform"
    Project     = "streaming-pipeline"
  }
}

resource "aws_instance" "kafka" {
  instance_type = "m5.large"

  # "merge" combines two sets of tags into one.
  # We take the common tags AND add a Name just for this server.
  tags = merge(local.common_tags, {
    Name = "kafka-broker-1"
    Role = "kafka"
  })
}
```

The `merge()` function glues two tag sets together. Here it says: “use all the common tags, *plus* these extra two.” So this Kafka server ends up with all six tags. This keeps your tagging consistent and your code clean. **This pattern — common tags in locals, merged with per-resource tags — is one of the most important habits in professional Terraform.**

-----

<a name="part-5"></a>

## Part 5: Building EC2 Servers (Kafka, NiFi, Postgres)

Now we build real things. We’ll create EC2 computers to run Kafka, NiFi, and Postgres. First, every server needs a home — a network. So let’s build that, then the servers.

### Step 1: The network (VPC and subnets)

Before any servers exist, we need a private network for them to live in. This is called a **VPC** (Virtual Private Cloud) — your own private, walled-off section of Amazon’s cloud where your stuff lives safely away from strangers.

```hcl
# Our own private network in the cloud.
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"  # Big neighborhood: ~65,000 addresses
  enable_dns_hostnames = true           # Let servers have friendly names
  enable_dns_support   = true           # Let servers look up names

  tags = {
    Name = "platform-vpc"
  }
}
```

Reading this: “Build a VPC (private network). Give it the big address range 10.0.0.0/16. Turn on DNS so servers can have and look up names. Name it platform-vpc.”

Now we chop that big network into smaller **subnets** (sub-networks). We make two kinds:

- **Public subnets** — can be reached from the internet. The load balancer lives here.
- **Private subnets** — hidden from the internet. Our actual servers (Kafka, Postgres) live here for safety. They can reach out, but strangers can’t reach in.

```hcl
# A PUBLIC subnet — reachable from the internet (for load balancers).
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id   # Put it inside our VPC
  cidr_block              = "10.0.1.0/24"     # Small slice: 256 addresses
  availability_zone       = "us-east-1a"      # Which physical data center
  map_public_ip_on_launch = true              # Give things here a public address

  tags = {
    Name = "public-subnet-a"
    Tier = "public"
  }
}

# A PRIVATE subnet — hidden from the internet (for real servers).
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "private-subnet-a"
    Tier = "private"
  }
}
```

**What’s an `availability_zone`?** Amazon’s data centers in one region are split into separate buildings called Availability Zones (AZs), like `us-east-1a`, `us-east-1b`, `us-east-1c`. They’re far enough apart that if one building loses power, the others keep running. **Pro move:** spread your servers across multiple AZs so a single building failure doesn’t take you down. We’d normally make `public_a`, `public_b`, `private_a`, `private_b`, etc. (For brevity I’m showing one of each, but real setups use 2–3 zones.)

### Step 2: The firewall (security groups)

A **security group** is a firewall — a bouncer that decides which network traffic is allowed in and out of a server. You list rules like “allow web traffic in” or “allow this server to talk to that one.” Anything not explicitly allowed is blocked by default. This is one of your most important safety tools.

Let’s make a security group for our Kafka servers:

```hcl
resource "aws_security_group" "kafka" {
  name        = "kafka-sg"
  description = "Firewall rules for Kafka brokers"
  vpc_id      = aws_vpc.main.id

  # INBOUND rule: who is allowed to send traffic TO Kafka.
  ingress {
    description = "Kafka client traffic"
    from_port   = 9092          # Kafka's normal port (door number)
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]  # Only computers inside our VPC. Not the internet!
  }

  # INBOUND rule: let Kafka brokers talk to each other.
  ingress {
    description = "Inter-broker communication"
    from_port   = 9093
    to_port     = 9093
    protocol    = "tcp"
    self        = true   # "self" means other servers in THIS same group
  }

  # OUTBOUND rule: what Kafka is allowed to reach.
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"            # "-1" means all protocols
    cidr_blocks = ["0.0.0.0/0"]   # 0.0.0.0/0 means "anywhere/everywhere"
  }

  tags = {
    Name = "kafka-sg"
    Role = "kafka"
  }
}
```

Let’s decode the new words:

- **`ingress`** = incoming traffic rules (traffic coming IN to the server).
- **`egress`** = outgoing traffic rules (traffic going OUT from the server).
- **`from_port` / `to_port`** = a range of **ports**. A port is like a numbered door on a computer; different programs listen at different door numbers. Kafka listens at door 9092. Setting from and to the same number means just that one door.
- **`protocol`** = the *language* of the traffic. `tcp` is the most common (reliable delivery). `-1` is shorthand for “any language.”
- **`cidr_blocks`** = which address neighborhoods are allowed. Notice we used `10.0.0.0/16` (only our own network) for incoming Kafka traffic — we do NOT want random people on the internet talking to Kafka! But for outbound we used `0.0.0.0/0` (“anywhere”) so Kafka can download updates.
- **`self = true`** = a neat trick meaning “allow other servers that are also in this same security group.” Perfect for letting a cluster’s members chat among themselves.

**Key safety lesson:** Notice how we let the *internet* reach the load balancer (later), but we only let *internal* traffic reach Kafka and Postgres. This layered approach — public stuff exposed, private stuff hidden — is called **defense in depth**, and it’s how you keep databases from getting hacked.

### Step 3: The Kafka servers (using `count`)

Kafka usually runs as a team of 3 or more servers (called **brokers**) so that if one dies, the others carry on and no data is lost. We’ll use `count` to make three identical brokers.

```hcl
# Look up the newest Ubuntu image so we don't hard-code an old one.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical (makers of Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Three Kafka broker servers.
resource "aws_instance" "kafka" {
  count = 3   # <-- Makes kafka[0], kafka[1], kafka[2]

  ami                    = data.aws_ami.ubuntu.id   # Use the image we looked up
  instance_type          = "m5.large"               # 2 CPUs, 8 GB memory
  subnet_id              = aws_subnet.private_a.id   # Hidden, private subnet
  vpc_security_group_ids = [aws_security_group.kafka.id]  # Apply the firewall

  # A bigger, faster hard drive for storing messages.
  root_block_device {
    volume_size = 100      # 100 gigabytes
    volume_type = "gp3"    # A fast modern disk type
  }

  tags = {
    Name = "kafka-broker-${count.index + 1}"  # kafka-broker-1, -2, -3
    Role = "kafka"
  }
}
```

The cool part is `count.index`. When `count = 3`, Terraform builds the block three times, and `count.index` is the copy number (0, 1, 2). So `"kafka-broker-${count.index + 1}"` produces `kafka-broker-1`, `kafka-broker-2`, `kafka-broker-3`. The `${ ... }` is how you stick a value inside a piece of text — it’s called **string interpolation** (fancy word for “fill in the blank inside text”).

New words here:

- **`root_block_device`** — the server’s main hard drive. We made it 100 GB because Kafka stores lots of messages.
- **`volume_type = "gp3"`** — a type of disk. `gp3` is fast and affordable. Kafka likes fast disks.
- **`vpc_security_group_ids`** — a *list* (note the square brackets `[ ]`) of firewalls to apply. You can apply several.

### Step 4: The NiFi server

NiFi typically runs on its own server (or a small cluster). Same pattern, different size and firewall. NiFi has a web dashboard you log into, usually on port 8443.

```hcl
resource "aws_security_group" "nifi" {
  name        = "nifi-sg"
  description = "Firewall for NiFi"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "NiFi web UI (HTTPS)"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]   # Only reachable from inside our network
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nifi-sg"
    Role = "nifi"
  }
}

resource "aws_instance" "nifi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "m5.xlarge"   # Bigger: NiFi moves lots of data
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.nifi.id]

  root_block_device {
    volume_size = 200    # NiFi buffers data on disk, so give it room
    volume_type = "gp3"
  }

  tags = {
    Name = "nifi-server"
    Role = "nifi"
  }
}
```

Notice we didn’t use `count` here — just one NiFi server. The pattern is identical; we just leave out `count` when we want a single thing.

### Step 5: Postgres — two ways

You asked specifically for **Postgres on EC2**, so I’ll show that. But I also want you to know the other, usually-better way, because a good tutorial tells you the trade-offs.

#### Way A: Postgres on EC2 (what you asked for — you manage it yourself)

Here you rent a computer and install Postgres on it yourself. You’re in full control, but *you* are responsible for backups, updates, and fixing it when it breaks.

```hcl
resource "aws_security_group" "postgres" {
  name        = "postgres-sg"
  description = "Firewall for the Postgres database"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Postgres connections"
    from_port   = 5432           # Postgres's normal port
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]   # ONLY internal. Never expose a DB to the internet!
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "postgres-sg"
    Role = "database"
  }
}

resource "aws_instance" "postgres" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "r5.xlarge"   # "r" series = lots of memory, good for databases
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.postgres.id]

  root_block_device {
    volume_size = 500     # Databases grow; give plenty of space
    volume_type = "gp3"
  }

  lifecycle {
    prevent_destroy = true   # SAFETY LOCK: never accidentally delete the database!
  }

  tags = {
    Name = "postgres-primary"
    Role = "database"
  }
}
```

Two important details here:

- **`instance_type = "r5.xlarge"`** — the `r` family has extra memory, which databases love.
- **`prevent_destroy = true`** — this `lifecycle` rule is a safety lock. If anyone ever runs a command that would delete this database, Terraform refuses. For a database holding real customer data, this can save your job.

#### Way B: Amazon RDS (the managed way — Amazon babysits it for you)

There’s a service called **RDS** (Relational Database Service) where Amazon runs Postgres *for* you — automatic backups, automatic updates, automatic failover if it crashes. Most companies prefer this because it’s way less work. I’m showing it so you know it exists:

```hcl
resource "aws_db_instance" "postgres_managed" {
  identifier        = "platform-postgres"
  engine            = "postgres"
  engine_version    = "16.3"
  instance_class    = "db.r5.xlarge"
  allocated_storage = 500
  storage_type      = "gp3"

  db_name  = "platformdb"
  username = "dbadmin"
  password = var.db_password   # Comes from a variable — never hard-code passwords!

  multi_az               = true    # Keep a backup copy in another building (auto-failover)
  backup_retention_period = 7      # Keep 7 days of automatic backups
  skip_final_snapshot    = false

  tags = {
    Name = "platform-postgres"
    Role = "database"
  }
}
```

**The trade-off in plain terms:** EC2 Postgres = maximum control, maximum responsibility (you’re the babysitter). RDS Postgres = less control, but Amazon handles backups, patches, and crash recovery (Amazon’s the babysitter). For learning and special setups, EC2 is great. For most real production databases, RDS saves enormous headache. Now you know both.

**One more note on passwords:** see `password = var.db_password`? We never type real passwords into our code (anyone who sees the file would steal them). Instead we use a variable and feed the secret in separately, or better yet pull it from a secret-storage service. Treat secrets like your house key — never leave them lying in the code.

-----

<a name="part-6"></a>

## Part 6: Building Load Balancers

Remember the traffic-cop analogy? Now we build one. AWS’s modern load balancer is called an **ALB** (Application Load Balancer). Building one takes three pieces that work together:

1. **The load balancer itself** — the traffic cop standing at the front door.
1. **A target group** — the list of servers the cop is allowed to send people to.
1. **A listener** — the rule for *which* door the cop watches and where to send traffic.

Let’s build them.

### Piece 1: A firewall for the load balancer

The load balancer faces the internet, so its firewall *does* allow public traffic (unlike our hidden servers):

```hcl
resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "Firewall for the public load balancer"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow web traffic (HTTPS) from anyone"
    from_port   = 443             # 443 is the door for secure web traffic
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # Anyone on the internet — this is intentional here
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-sg"
  }
}
```

### Piece 2: The load balancer itself

```hcl
resource "aws_lb" "main" {
  name               = "platform-alb"
  internal           = false           # false = faces the internet (public)
  load_balancer_type = "application"   # "application" = the smart ALB type
  security_groups    = [aws_security_group.alb.id]

  # The cop stands in the PUBLIC subnets, across two zones for safety.
  subnets = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]

  tags = {
    Name = "platform-alb"
  }
}
```

New words:

- **`internal = false`** — whether the load balancer is public (false) or private/internal-only (true). False means the internet can reach it.
- **`load_balancer_type = "application"`** — there are a few types; “application” is the smart one that understands web traffic and can route based on the URL.
- **`subnets`** — a list of *public* subnets, in two different zones, so the load balancer itself survives a data-center outage.

### Piece 3: The target group (the list of servers)

The target group is the list of servers that should receive traffic, plus a **health check** — the load balancer pokes each server regularly to ask “are you alive and healthy?” If a server stops answering, the cop quietly stops sending people to it.

```hcl
resource "aws_lb_target_group" "web" {
  name     = "web-targets"
  port     = 80                  # The door on the servers to send traffic to
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # Health check: keep poking servers to see if they're okay.
  health_check {
    enabled             = true
    path                = "/health"   # A web address that returns "I'm fine"
    interval            = 30          # Check every 30 seconds
    timeout             = 5           # Wait up to 5 seconds for an answer
    healthy_threshold   = 2           # 2 good checks in a row = healthy
    unhealthy_threshold = 3           # 3 bad checks in a row = take it out
  }

  tags = {
    Name = "web-targets"
  }
}
```

The **health check** is one of the most valuable features in all of computing. It’s what lets a website stay up even when individual servers crash — the broken ones are automatically removed from rotation and visitors never notice. Decoding the settings: every 30 seconds (`interval`) the balancer requests the `/health` page; if it gets 2 good answers in a row (`healthy_threshold`) the server is “in,” and if it gets 3 bad ones (`unhealthy_threshold`) it’s “out.”

### Piece 4: The listener (the routing rule)

The listener connects everything: “When secure web traffic arrives at the front door (port 443), forward it to the web target group.”

```hcl
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn          # Attach to our load balancer
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.ssl_certificate_arn  # The lock/encryption certificate

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn  # Send traffic here
  }
}
```

New word: **`arn`**. ARN stands for “Amazon Resource Name.” It’s a long, unique, official ID for a thing in AWS — like its full legal name and address combined. It looks like `arn:aws:elasticloadbalancing:us-east-1:1234:...`. You’ll see `.arn` used a lot when one thing needs to point precisely at another. (Earlier we used `.id` for simpler references; `.arn` is the fuller, globally-unique version that some connections require.)

Now the full chain works: **internet → listener (port 443) → target group → healthy servers.** The traffic cop is on duty.

-----

<a name="part-7"></a>

## Part 7: Building an EKS Cluster (Kubernetes)

This is the big one. Let’s build Kubernetes the easy way (with EKS), and I’ll explain every concept as we go.

### Wait — what problem does Kubernetes solve?

Let’s slow down and really get this, because it’s the heart of modern systems.

Imagine you have 50 different small programs (microservices) that make up your app. Each needs to run somewhere. Each might crash. When lots of users show up, you need more copies of the busy ones. When it’s quiet, you want fewer to save money. Doing all this by hand — deciding which computer runs what, restarting crashes, scaling up and down — would require a small army of humans watching screens 24/7.

**Kubernetes is a robot that does all of that automatically.** You tell it, “I want 5 copies of my checkout program running at all times.” Kubernetes finds computers with room, starts 5 copies, watches them, and if one crashes it instantly starts a replacement — no human needed. If a whole computer dies, Kubernetes moves its programs to healthy computers. This is called **container orchestration** (“orchestration” = coordinating many moving parts, like a conductor leading an orchestra).

**EKS is Amazon running the Kubernetes robot for you**, so you don’t have to install and maintain the (very complicated) robot’s brain yourself.

### The pieces of Kubernetes (vocabulary)

Before the code, learn these five words. They’ll make everything click:

- **Cluster** — the whole Kubernetes system: the brain plus all the worker computers, together.
- **Control plane** — the *brain* of the cluster. It makes all the decisions (what runs where). With EKS, Amazon runs and protects the brain for you.
- **Node** — a single worker computer that actually runs your programs. (It’s really just an EC2 server with Kubernetes software on it.)
- **Node group** — a team of identical worker computers (nodes) that can grow or shrink together.
- **Pod** — the smallest unit Kubernetes runs: one (or a few tightly-related) containers together. Your programs run inside pods, and pods run on nodes.

Putting it together: *Your program runs in a **pod**, the pod runs on a **node**, many nodes form a **node group**, and the **control plane** (brain) decides where everything goes — all together that’s the **cluster**.*

### Step 1: A role that lets EKS act on your behalf

EKS needs *permission* to create and manage things in your AWS account on your behalf. In AWS, permissions are handled by **IAM** (Identity and Access Management). We create an **IAM role** — basically a costume with a permission badge that EKS can “wear” to be allowed to do its job.

```hcl
# A role the EKS control plane (brain) will wear.
resource "aws_iam_role" "eks_cluster" {
  name = "eks-cluster-role"

  # This policy says WHO is allowed to wear this costume: the EKS service.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = {
    Name = "eks-cluster-role"
  }
}

# Attach Amazon's official "you may run an EKS cluster" permission to the role.
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
```

Decoding the new stuff:

- **IAM role** — a set of permissions a service can temporarily “wear.” Roles are how AWS services safely act for you without sharing passwords.
- **`assume_role_policy`** — the rule for *who* is allowed to wear this role. Here, only the EKS service (`eks.amazonaws.com`) can. This prevents random things from grabbing these powers.
- **`jsonencode({...})`** — a helper that turns Terraform’s tidy format into JSON (a data format AWS expects for policies). You write it the easy way; `jsonencode` converts it.
- **`policy_attachment`** — sticks a permission policy *onto* the role. `AmazonEKSClusterPolicy` is a ready-made permission set from Amazon meaning “allowed to run an EKS cluster.”

Don’t stress about memorizing IAM — just understand the idea: **roles are permission costumes, and we’re handing EKS the right costume to do its job.**

### Step 2: The EKS cluster (the brain)

```hcl
resource "aws_eks_cluster" "main" {
  name     = "platform-cluster"
  role_arn = aws_iam_role.eks_cluster.arn   # Wear the role we made
  version  = "1.30"                         # Kubernetes version

  vpc_config {
    # The brain needs to live in our network, across multiple zones.
    subnet_ids = [
      aws_subnet.private_a.id,
      aws_subnet.private_b.id
    ]
    endpoint_private_access = true    # Reachable from inside our network
    endpoint_public_access  = true    # Also reachable from outside (for admins)
  }

  # Make sure permissions exist BEFORE building the cluster.
  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = {
    Name = "platform-cluster"
  }
}
```

Notice **`depends_on`** here. We’re telling Terraform: “build the permission attachment first, *then* the cluster.” We need it because the cluster will fail to build if its permissions aren’t ready yet, and this dependency isn’t obvious from a simple reference. This is one of those rare times you spell out the order by hand.

Also notice the cluster brain lives across **two zones** (`private_a` and `private_b`). That way the brain survives if one data center has problems.

### Step 3: A role for the worker nodes

The worker computers *also* need a permission costume (a different one — workers need different powers than the brain):

```hcl
resource "aws_iam_role" "eks_nodes" {
  name = "eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }   # Worker nodes are EC2 computers
    }]
  })

  tags = {
    Name = "eks-node-role"
  }
}

# Workers need these three official permission sets:
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}
resource "aws_iam_role_policy_attachment" "node_registry" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
```

The three policies, in plain terms: the first lets a computer *be* an EKS worker, the second handles pod networking (giving pods their addresses), and the third lets workers *download* the container lunchboxes they’re supposed to run. Workers need all three to function.

### Step 4: The node group (the team of workers)

Now the actual worker computers, as a group that can automatically grow and shrink:

```hcl
resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "general-workers"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]

  instance_types = ["m5.large"]   # Size of each worker computer

  # Auto-scaling: grow and shrink the team based on demand.
  scaling_config {
    desired_size = 3   # Try to keep 3 workers normally
    min_size     = 2   # Never go below 2
    max_size     = 10  # Never go above 10
  }

  # During updates, only take down 1 worker at a time (stay online).
  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_registry
  ]

  tags = {
    Name = "general-workers"
  }
}
```

The star here is **`scaling_config`**, which is what makes Kubernetes feel magical:

- **`desired_size = 3`** — aim to keep 3 workers running.
- **`min_size = 2`** — even when super quiet, keep at least 2 (so you’re never totally down).
- **`max_size = 10`** — when slammed with traffic, grow up to 10, but no more (to cap your bill).

So during a quiet night you might run 2 workers (cheap), and during a big rush you automatically grow toward 10 (fast), then shrink back down afterward. You pay for what you need, when you need it. **`update_config { max_unavailable = 1 }`** means when upgrading workers, only one goes offline at a time, so your app never fully goes dark during maintenance.

That’s a complete, auto-scaling Kubernetes cluster! Now for the part you really wanted: making it **multi-tenant.**

-----

<a name="part-8"></a>

## Part 8: Multi-Tenant EKS — The Deep Dive

This is the section you asked to go deep on. Let’s build it up carefully, starting with the *why*, because the why makes the how obvious.

### What does “multi-tenant” even mean?

Think about an apartment building versus a bunch of separate houses.

- **Single-tenant** is like everyone getting their own separate house. Lots of space and privacy, but expensive — each house needs its own roof, plumbing, heating, yard. If you have 20 families, you build 20 complete houses.
- **Multi-tenant** is like one big apartment building where 20 families each rent an apartment. They share the building’s structure, plumbing, and elevator, which is way cheaper and easier to maintain. But each family has their own locked apartment — they can’t wander into yours, and you can’t hear (much of) theirs.

In computing, a **tenant** is a separate user, team, customer, or project that shares the same system. **Multi-tenant** means *many tenants share one cluster*, each in their own locked “apartment,” instead of each getting a whole separate cluster.

### The problem multi-tenancy solves (the real-world background)

Here’s the situation companies face. Suppose your company has 15 different teams, and each team wants to run their apps on Kubernetes. You have two choices:

**Option A — Give each team their own cluster (single-tenant).** Now you’re running 15 separate clusters. Each cluster has its own brain (control plane) that costs money every hour even when idle. Each needs its own monitoring, upgrades, and security patching. With 15 clusters, your platform team is drowning in maintenance, and you’re paying for 15 brains and tons of half-used worker computers. Hugely wasteful and exhausting.

**Option B — Put all 15 teams on ONE big shared cluster (multi-tenant).** Now there’s one brain to maintain, one place to monitor, one upgrade process. Worker computers are shared, so a quiet team’s unused space can be used by a busy team — far less waste. *This* is the dream. But it creates a brand-new problem: **how do you keep the 15 teams from stepping on each other?**

That last question is what multi-tenant Kubernetes is all about. Specifically, you must solve four sub-problems:

1. **Isolation** — Team A must not see, touch, or break Team B’s stuff. (Locks on the apartment doors.)
1. **Fair resource sharing** — One greedy team must not hog all the CPU and starve everyone else. (No single family using all the building’s water.)
1. **Security** — A break-in in one apartment shouldn’t spread to others. (Fire doors between units.)
1. **Fair cost tracking** — You need to know how much each team actually used, to bill them fairly. (Separate utility meters per apartment.)

Let’s solve each one. The good news: Kubernetes has built-in tools for all four. Here are the key concepts, then the Terraform.

### The four tools that make multi-tenancy work

**Tool 1 — Namespaces (the apartment walls).**
A **namespace** is a named section *inside* a cluster that keeps one tenant’s stuff separated from another’s. Team A gets the `team-a` namespace, Team B gets `team-b`. Things in different namespaces don’t automatically see each other. It’s the fundamental “wall” that divides the shared building into separate apartments. Almost everything else in multi-tenancy is built on top of namespaces.

**Tool 2 — Resource Quotas and Limits (the utility caps).**
A **ResourceQuota** is a cap on how much of the cluster’s total resources (CPU, memory) a single namespace is allowed to use. This is what stops one greedy team from eating everything. You say “Team A may use at most 20 CPUs and 40 GB of memory total,” and Kubernetes enforces it. A related tool, **LimitRange**, sets sensible defaults and ceilings for *individual* programs so nobody accidentally launches one giant memory-hog. Together they guarantee fair sharing.

**Tool 3 — RBAC (the apartment keys).**
**RBAC** stands for “Role-Based Access Control.” It’s the system of keys deciding *who can do what, where*. You give Team A members keys that work only on the `team-a` namespace door. They literally cannot open Team B’s namespace. This is how you enforce “you can only touch your own stuff.” Without RBAC, anyone could mess with anyone’s apartment.

**Tool 4 — Network Policies (the fire doors).**
By default in Kubernetes, every pod can talk to every other pod across all namespaces — like a building where every apartment door is unlocked and connected by hallways. A **NetworkPolicy** locks those internal doors: “pods in `team-a` may only talk to other `team-a` pods, not to `team-b`.” This contains break-ins and stops accidental cross-talk. It’s the fire door that keeps a problem in one apartment from spreading.

Now let’s build all of this in Terraform.

### Step 1: Create a namespace per tenant

Terraform can manage things *inside* Kubernetes too, using the Kubernetes provider. We’ll create one namespace per team. (Setup note: to manage Kubernetes objects, you configure a `kubernetes` provider pointed at the EKS cluster we built; for brevity I’ll show the resources themselves, which is where the multi-tenant logic lives.)

```hcl
# Define our list of tenants in one place.
variable "tenants" {
  description = "The list of teams sharing this cluster"
  type        = list(string)
  default     = ["team-a", "team-b", "team-c"]
}

# Make one namespace for EACH tenant using for_each.
resource "kubernetes_namespace" "tenant" {
  for_each = toset(var.tenants)   # Loop over each team name

  metadata {
    name = each.value             # e.g. "team-a"

    # Labels help us find and manage namespaces by tenant.
    labels = {
      tenant      = each.value
      managed-by  = "terraform"
    }
  }
}
```

Here we meet **`for_each`** properly. Unlike `count` (which just makes N copies), `for_each` makes one copy *per item in a list*, and each copy knows *which* item it is via `each.value`. So this single block creates three namespaces: `team-a`, `team-b`, `team-c`. If you later add `team-d` to the list and re-run, Terraform adds just that one new namespace and leaves the others untouched. (`toset` just converts the list into a “set,” which is the form `for_each` wants.) The **labels** are tags for Kubernetes — same idea as AWS tags: notes that let you find and organize things by tenant.

### Step 2: Give each tenant a resource quota (fair sharing)

Now we cap each team’s resource usage so nobody hogs the cluster:

```hcl
resource "kubernetes_resource_quota" "tenant" {
  for_each = toset(var.tenants)

  metadata {
    name      = "quota"
    namespace = each.value   # Apply to this tenant's namespace
  }

  spec {
    hard = {
      # The total this whole namespace may use:
      "requests.cpu"    = "20"     # Reserve up to 20 CPU cores
      "requests.memory" = "40Gi"   # Reserve up to 40 gigabytes of memory
      "limits.cpu"      = "40"     # Hard ceiling of 40 CPU cores
      "limits.memory"   = "80Gi"   # Hard ceiling of 80 gigabytes
      "pods"            = "50"     # No more than 50 pods at once
    }
  }
}
```

Decoding this fair-sharing tool:

- **`requests` vs `limits`** — a *request* is what a program reserves up front (“I need at least this much”). A *limit* is the absolute ceiling it can ever use (“never more than this”). The quota caps both the team’s total requests and total limits.
- **`"40Gi"`** — 40 “gibibytes,” basically 40 gigabytes of memory.
- **`"pods" = "50"`** — the team can’t run more than 50 pods, preventing one team from flooding the cluster with thousands of tiny programs.

Now Team A literally cannot consume more than its share, no matter what — Kubernetes will refuse to start anything that would push them over. Crisis of the greedy neighbor: solved.

It’s also wise to add a **LimitRange** so individual pods get sane defaults and can’t be created absurdly large:

```hcl
resource "kubernetes_limit_range" "tenant" {
  for_each = toset(var.tenants)

  metadata {
    name      = "limits"
    namespace = each.value
  }

  spec {
    limit {
      type = "Container"
      default = {                 # If a program doesn't say, give it this much:
        cpu    = "500m"           # 500m = half a CPU core
        memory = "512Mi"          # 512 megabytes
      }
      default_request = {         # And reserve at least this much:
        cpu    = "250m"
        memory = "256Mi"
      }
      max = {                     # No single container may exceed:
        cpu    = "4"
        memory = "8Gi"
      }
    }
  }
}
```

`"500m"` means “500 milli-CPUs,” which is half of one CPU core (1000m = 1 whole core). This ensures that even forgetful developers who don’t specify sizes get reasonable defaults, and nobody can launch a single monster container that eats a whole worker.

### Step 3: Give each tenant locked-down access with RBAC (the keys)

Now we make keys so each team can manage *only their own* namespace. RBAC has two parts: a **Role** (what actions are allowed) and a **RoleBinding** (who gets those actions). Think of the Role as defining what a key *can unlock*, and the RoleBinding as *handing that key to a specific person*.

```hcl
# A Role = a set of allowed actions, scoped to ONE namespace.
resource "kubernetes_role" "tenant_admin" {
  for_each = toset(var.tenants)

  metadata {
    name      = "tenant-admin"
    namespace = each.value         # This role only works in this namespace
  }

  # What actions does this role allow?
  rule {
    api_groups = ["", "apps", "batch"]   # Categories of things
    resources  = ["pods", "deployments", "services", "jobs", "configmaps"]
    verbs      = ["get", "list", "watch", "create", "update", "delete"]
  }
}

# A RoleBinding = hand the role's key to specific people/groups.
resource "kubernetes_role_binding" "tenant_admin" {
  for_each = toset(var.tenants)

  metadata {
    name      = "tenant-admin-binding"
    namespace = each.value
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.tenant_admin[each.key].metadata[0].name
  }

  # WHO gets the key: the group for this team.
  subject {
    kind      = "Group"
    name      = "${each.value}-admins"   # e.g. the "team-a-admins" group
    api_group = "rbac.authorization.k8s.io"
  }
}
```

Decoding RBAC:

- **`verbs`** — the *actions* allowed: `get`/`list`/`watch` (look at things), `create`/`update`/`delete` (change things). You can hand out read-only keys (just the looking verbs) or full keys (all verbs). Here team admins get full control — but *only inside their own namespace*.
- **`resources`** — *what kinds of things* the key works on (pods, deployments, services, etc.).
- **`role_ref`** — which Role this binding hands out.
- **`subject`** — *who* receives it. Here, the `team-a-admins` group. Members of that group can fully manage `team-a` and are completely locked out of `team-b` and `team-c`.

This is the crucial isolation guarantee: **Team A’s keys physically do not fit Team B’s locks.** Even if a Team A member tried to delete Team B’s pods, Kubernetes would reject them. (Sidebar: there’s also a cluster-wide version called `ClusterRole`/`ClusterRoleBinding` for permissions that span the whole cluster — used carefully for platform admins, not regular tenants.)

### Step 4: Lock the internal doors with Network Policies (fire doors)

Finally, we stop tenants’ pods from talking across namespaces. First a “default deny” policy that blocks all incoming cross-talk, then we allow only same-namespace traffic:

```hcl
# DEFAULT DENY: by default, block all incoming traffic to this namespace.
resource "kubernetes_network_policy" "default_deny" {
  for_each = toset(var.tenants)

  metadata {
    name      = "default-deny-ingress"
    namespace = each.value
  }

  spec {
    pod_selector {}              # Empty = applies to ALL pods in the namespace
    policy_types = ["Ingress"]   # We're controlling incoming traffic
    # No "ingress" rules listed = nothing is allowed in. Full lockdown.
  }
}

# ALLOW SAME-NAMESPACE: let pods in this namespace talk to each other.
resource "kubernetes_network_policy" "allow_same_namespace" {
  for_each = toset(var.tenants)

  metadata {
    name      = "allow-same-namespace"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        # Only allow traffic from pods in this SAME namespace.
        namespace_selector {
          match_labels = {
            tenant = each.value
          }
        }
      }
    }
  }
}
```

How these two work together (this is a classic, powerful pattern):

- The first policy is a **default deny** — `pod_selector {}` (empty) means “every pod here,” and listing *no* allowed sources means “block all incoming traffic.” Total lockdown.
- The second policy then *opens one specific door*: it allows traffic, but only `from` pods whose namespace carries the matching `tenant` label. So same-team pods can chat, while pods from other tenants are still blocked by the default-deny baseline.

The result: **Team A’s pods can talk to each other but cannot reach into Team B’s namespace**, and vice versa. If one tenant’s app gets hacked, the attacker is trapped inside that one namespace’s network — the fire doors hold. This is exactly the containment a shared building needs.

### Step 5 (optional but smart): separate worker pools per tenant tier

Sometimes you want certain tenants on their *own* worker computers (for stronger isolation or special hardware), even within one cluster. You can run multiple node groups and steer each tenant’s pods to specific nodes using **taints** (a node saying “only specially-marked pods may run here”) and **tolerations** (a pod’s permission slip to run on a tainted node). Here’s a dedicated node group:

```hcl
resource "aws_eks_node_group" "premium" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "premium-workers"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  instance_types  = ["m5.2xlarge"]   # Bigger workers for premium tenants

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 6
  }

  # A "taint" repels normal pods — only pods that "tolerate" it land here.
  taint {
    key    = "tier"
    value  = "premium"
    effect = "NO_SCHEDULE"
  }

  labels = {
    tier = "premium"
  }

  tags = {
    Name = "premium-workers"
    Tier = "premium"
  }
}
```

In plain terms: this group’s workers carry a “premium-only” sign (`taint`). Regular pods are repelled and won’t be placed here. Only pods carrying a matching permission slip (a *toleration*, set in the pod’s own config) are allowed to run on these beefier machines. This gives premium tenants dedicated, isolated hardware while everything else still shares the general pool — the best of both worlds.

### Multi-tenancy: the whole picture

Let’s zoom out and see how the four tools combine into one coherent system. In our shared apartment building (the cluster):

- **Namespaces** are the apartment walls dividing tenants. *(isolation of resources)*
- **Resource Quotas + LimitRanges** are the metered utility caps, so nobody hogs water or power. *(fair sharing)*
- **RBAC** is the set of keys, so each tenant opens only their own door. *(access control)*
- **Network Policies** are the fire doors, so a problem in one unit can’t spread. *(security containment)*
- **Taints/tolerations + labels** optionally give some tenants their own private rooms with special equipment. *(dedicated hardware)*
- And **tags/labels** everywhere let you meter each tenant’s usage for fair billing. *(cost tracking)*

Together, these turn one big shared cluster into many safe, fair, isolated apartments — capturing the huge savings of sharing *without* the chaos of tenants stepping on each other. **That is the entire promise of multi-tenant Kubernetes, and now you understand both why it matters and exactly how each piece is built.**

-----

<a name="part-9"></a>

## Part 9: Putting It All Together

### The professional project structure

A real project organizes files like this:

```
my-platform/
├── providers.tf      # Which cloud + the special terraform block
├── variables.tf      # All the fill-in-the-blank settings
├── network.tf        # VPC, subnets, security groups
├── compute.tf        # EC2: Kafka, NiFi, Postgres
├── load_balancer.tf  # ALB, target groups, listeners
├── eks.tf            # The cluster and node groups
├── multi_tenant.tf   # Namespaces, quotas, RBAC, network policies
└── outputs.tf        # Useful info to print at the end
```

Remember: Terraform reads *all* `.tf` files in the folder together, so this split is purely for human sanity. You could put it all in one file, but please don’t — your future self will thank you.

### The special `terraform` block (where state lives)

Remember the state file — Terraform’s memory? In a real project, store it safely in the cloud, not on your laptop. Here’s the setup block that does it, plus pinning versions so everyone uses the same tools:

```hcl
terraform {
  required_version = ">= 1.6"   # Use Terraform 1.6 or newer

  # Pin the AWS provider so everyone gets the same version.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"        # Any 5.x version
    }
  }

  # Store the state file safely in an S3 bucket, with locking.
  backend "s3" {
    bucket         = "my-company-terraform-state"
    key            = "platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"   # Prevents two people editing at once
    encrypt        = true                # Scramble the state file (it has secrets)
  }
}
```

Decoding this important block:

- **`required_version`** — which Terraform versions are allowed, so an old or too-new version doesn’t cause surprises.
- **`required_providers`** with **`version = "~> 5.0"`** — pin the AWS provider to the 5.x line. The `~>` means “this major version, accept minor updates.” Pinning stops a surprise upgrade from breaking your build.
- **`backend "s3"`** — store the state file in an S3 bucket (cloud storage) instead of your laptop, so the whole team shares one source of truth.
- **`dynamodb_table`** — a **lock** so two teammates can’t run `apply` at the same time and corrupt the shared memory. Whoever runs first gets the lock; others wait. This prevents a nasty class of bugs.
- **`encrypt = true`** — scramble the stored state, because it can contain secrets.

This block is a hallmark of professional Terraform. If you see it, you’re looking at a real, team-ready setup.

### Helpful outputs

Finally, print the info you’ll actually need after building:

```hcl
output "kafka_private_ips" {
  description = "Private IP addresses of the Kafka brokers"
  value       = aws_instance.kafka[*].private_ip   # [*] = all of them
}

output "load_balancer_dns" {
  description = "The public web address of the load balancer"
  value       = aws_lb.main.dns_name
}

output "eks_cluster_endpoint" {
  description = "The address to connect to the Kubernetes cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "tenant_namespaces" {
  description = "The namespaces created for each tenant"
  value       = [for ns in kubernetes_namespace.tenant : ns.metadata[0].name]
}
```

The `[*]` in `aws_instance.kafka[*].private_ip` is a **splat** — it means “give me this attribute from *all* the copies.” Since we made 3 Kafka brokers with `count`, this outputs all 3 of their addresses at once. The last output uses a `for` expression to list every tenant namespace. Outputs save you from digging through the AWS dashboard hunting for addresses.

### The full workflow, start to finish

Here’s everything you’d actually type to build this whole platform:

```bash
# 1. Get ready: download the tools Terraform needs.
terraform init

# 2. Check your files for typos and obvious mistakes.
terraform validate

# 3. Auto-tidy your formatting (optional but nice).
terraform fmt

# 4. Preview EXACTLY what will be built. Read this carefully!
terraform plan

# 5. Build it all for real (it'll ask you to confirm with "yes").
terraform apply

# ... later, when you want to tear down a test environment ...

# 6. Destroy everything Terraform built (also asks to confirm).
terraform destroy
```

Two new helpers above: **`terraform validate`** checks your files for errors *before* you try to build (catches typos early), and **`terraform fmt`** auto-formats your code so it’s neat and consistent. Run both often — they’re free and save headaches.

-----

## The Big Recap

Let’s tie the whole journey together in plain language:

**Terraform** is the instruction sheet for building cloud systems. You *declare* what you want in `.tf` files, Terraform *plans* the changes, then *applies* them — and remembers everything in a *state file*.

**Every Terraform file** is just stacks of **blocks**, each shaped `block_type "type" "nickname" { settings }`. The main block types are `resource` (build a thing), `data` (look up a thing), `variable` (a fill-in setting), `output` (print info), and `provider` (which cloud).

**Tags** are sticky labels that don’t change how things work but are essential for finding things, tracking who spends what money, automating safety rules, and knowing who’s in charge. Set common ones once with `default_tags`, and merge in specific ones per resource.

**On AWS**, we built: a private network (**VPC** with public and private subnets), firewalls (**security groups**), rented computers (**EC2**) running **Kafka**, **NiFi**, and **Postgres**, a traffic cop (**load balancer** with target groups and health checks), and a self-managing container system (**EKS** / Kubernetes with auto-scaling node groups).

**Multi-tenant EKS** lets many teams safely share one cluster — like an apartment building instead of separate houses. It solves the cost-and-maintenance nightmare of giving everyone their own cluster, using four tools: **namespaces** (apartment walls), **resource quotas** (utility caps), **RBAC** (keys to your own door), and **network policies** (fire doors between units) — plus optional dedicated worker pools via **taints and tolerations**.

You now have the vocabulary and the mental models to *read* a real Terraform file, *understand* what infrastructure it builds, and *reason about* one of the trickiest topics in the field — multi-tenancy. Go read some real `.tf` files; you’ll be surprised how much makes sense now.

-----

<a name="glossary"></a>

## Glossary (Cheat Sheet)

**AMI** — Amazon Machine Image; the starting software/operating system for a server.

**ARN** — Amazon Resource Name; a thing’s long, unique, official ID in AWS.

**Availability Zone (AZ)** — a separate data-center building in a region; spread across several for safety.

**Block** — the basic shape of Terraform code: `type "label" "name" { settings }`.

**CIDR block** — a range of network addresses; smaller slash number = bigger range (`/16` big, `/24` small).

**Cluster** — a whole Kubernetes system: brain + worker computers.

**Container** — a program packed in a tidy “lunchbox” so it runs the same anywhere.

**Control plane** — the brain of a Kubernetes cluster that decides what runs where.

**`count`** — make N identical copies of a resource.

**`data`** — a block that looks up an existing thing without building it.

**Declarative** — describing *what* you want, not the steps to get there.

**`default_tags`** — tags set once on the provider that stick to everything.

**`depends_on`** — manually force one thing to build after another.

**EC2** — a rented computer in Amazon’s cloud.

**EKS** — Amazon running Kubernetes for you.

**`egress` / `ingress`** — outgoing / incoming traffic rules in a firewall.

**`for_each`** — make one copy per item in a list, each knowing which item it is.

**Health check** — the load balancer repeatedly poking servers to see if they’re alive.

**HCL** — HashiCorp Configuration Language; the language Terraform files are written in.

**IAM role** — a permission “costume” an AWS service can wear to act on your behalf.

**Infrastructure as Code (IaC)** — describing your servers in text files.

**`instance_type`** — the size (CPU + memory) of a server, like `t3.micro` or `m5.large`.

**Kafka** — a super-fast “post office” for passing messages between programs.

**`lifecycle` / `prevent_destroy`** — special rules; `prevent_destroy` locks a thing against deletion.

**LimitRange** — sensible default and max sizes for individual programs in a namespace.

**Load balancer (ALB)** — a traffic cop spreading visitors across many servers.

**`locals`** — reusable nicknames for values inside one project.

**`merge()`** — combine two sets of tags (or maps) into one.

**`module`** — a reusable bundle of Terraform blocks.

**Multi-tenant** — many teams/customers safely sharing one system (apartment building).

**Namespace** — a walled-off section inside a Kubernetes cluster for one tenant.

**NiFi** — a drag-and-drop “conveyor belt” for moving and transforming data.

**Node / Node group** — a worker computer / a team of worker computers in Kubernetes.

**Network Policy** — rules controlling which pods may talk to which (the fire doors).

**`output`** — info Terraform prints after building.

**Pod** — the smallest unit Kubernetes runs; holds one or a few containers.

**Port** — a numbered “door” on a computer where a specific program listens.

**Postgres (PostgreSQL)** — an organized database (digital filing cabinet).

**`provider`** — which cloud Terraform talks to (AWS, Google, etc.).

**RBAC** — Role-Based Access Control; the system of keys for who-can-do-what-where.

**RDS** — Amazon’s managed database service (Amazon babysits your database).

**ResourceQuota** — a cap on total resources a namespace may use (fair sharing).

**`resource`** — a block that builds a real thing.

**Security group** — a firewall/bouncer controlling traffic to a server.

**Splat (`[*]`)** — “give me this attribute from all the copies.”

**State file** — Terraform’s memory of everything it has built (`terraform.tfstate`).

**Subnet** — a smaller slice of a VPC; public (internet-facing) or private (hidden).

**Tag** — a sticky key-value label for organizing, billing, and automating.

**Taint / Toleration** — a node repelling pods / a pod’s permission to run on a tainted node.

**`terraform` block** — special setup block for versions and where state is stored.

**`terraform init / plan / apply / destroy`** — get ready / preview / build / tear down.

**`variable` (`var.x`)** — a fill-in-the-blank setting that makes code reusable.

**VPC** — your own private, walled-off network inside Amazon’s cloud.