# AWS VPC, Public and Private Subnets, Route 53, Load Balancer, and EC2

## Complete AWS CLI Tutorial with Explanations, Debugging, Pros, Cons, and Cleanup

This tutorial teaches you how to build a small AWS web network by using the AWS Command Line Interface, also called the **AWS CLI**.

The language is kept simple. The commands are real AWS commands, but each step explains:

- What you are creating.
- Why you need it.
- How the AWS CLI command is built.
- What the important command options mean.
- How to check that the step worked.
- How to debug common problems.
- The pros and cons of the design.
- How to delete the resources safely.

> **Important:** AWS resources can cost money. Build the lab, test it, and delete it when finished.

---

# 1. What You Will Build

```text
                            Internet
                                |
                         Route 53 DNS
                   hello.your-example-domain.com
                                |
                    Application Load Balancer
                       HTTP listener: port 80
                         /              \
                Public Subnet A    Public Subnet B
                    AZ A               AZ B
                         \              /
                          \            /
                         Target Group
                              |
                       EC2 Web Server
                      Private Subnet A

                 Private Subnet B is reserved
                 for a second server later.
```

The final request path is:

```text
Your browser
    |
    v
Route 53 DNS name
    |
    v
Application Load Balancer
    |
    v
Target group
    |
    v
Private EC2 instance
    |
    v
Hello web page
```

---

# 2. Why This Design Is Useful

The internet does not contact the EC2 server directly.

Instead:

1. The internet contacts the load balancer.
2. The load balancer checks whether the EC2 server is healthy.
3. The load balancer sends the request to the EC2 server.
4. The EC2 server returns the Hello page.
5. The load balancer returns the page to the user.

This gives you a security layer between the internet and the server.

## Cost-saving choice

This lab does **not** use a NAT Gateway.

A NAT Gateway lets private servers make outbound internet connections, such as downloading operating-system packages. It is useful, but it has hourly and data-processing charges.

The Hello server in this tutorial uses Python that is already available on Amazon Linux 2023. It does not need to download a web server package. This lets the instance remain private without a NAT Gateway.

## Limitation of this choice

The private EC2 server cannot directly download updates from the internet.

For a real production system, you would normally use one or more of these:

- A NAT Gateway.
- VPC endpoints for AWS services.
- An internal software repository.
- A proxy server.
- A company-managed patching system.
- A prebuilt and patched Amazon Machine Image.

---

# 3. AWS Words Explained in Simple Language

## AWS Region

A Region is a large geographic AWS area.

Examples:

```text
us-east-1     Northern Virginia
us-east-2     Ohio
us-west-2     Oregon
```

Most resources in this tutorial are created inside one Region.

## Availability Zone

An Availability Zone, or **AZ**, is a separate group of AWS data centers inside a Region.

Examples:

```text
us-east-1a
us-east-1b
```

Using more than one AZ helps protect an application if one location has a problem.

## VPC

A Virtual Private Cloud, or **VPC**, is your private network area inside AWS.

Think of it as fenced land.

Inside the fence, you create:

- Subnets.
- Route tables.
- Security groups.
- EC2 servers.
- Load balancers.
- Other AWS resources.

## CIDR block

A CIDR block is a range of IP addresses.

Example:

```text
10.20.0.0/16
```

The `/16` describes how large the address range is.

This tutorial uses:

```text
VPC:               10.20.0.0/16
Public subnet A:   10.20.1.0/24
Public subnet B:   10.20.2.0/24
Private subnet A:  10.20.11.0/24
Private subnet B:  10.20.12.0/24
```

A `/24` has 256 total IPv4 addresses. AWS reserves five addresses in each subnet, so not all 256 can be assigned to resources.

## Subnet

A subnet is a smaller network inside the VPC.

Think of the VPC as a school building and subnets as rooms.

## Public subnet

A public subnet has a route to an Internet Gateway.

A subnet is not public only because its name says `public`. Its route table is what makes it public.

## Private subnet

A private subnet does not have a direct route to an Internet Gateway.

A private subnet can still communicate with:

- Other subnets in the VPC.
- A load balancer.
- A database.
- VPC endpoints.
- A NAT Gateway, when one is added.

## Internet Gateway

An Internet Gateway connects a VPC to the internet.

Creating the gateway is not enough. You must also:

1. Attach it to the VPC.
2. Add a route that points internet traffic to it.
3. Give the internet-facing resource a public address when required.
4. Allow the traffic in security groups and network ACLs.

## Route table

A route table is a list of network road signs.

Example:

```text
Destination      Target
10.20.0.0/16     local
0.0.0.0/0        Internet Gateway
```

The `local` route lets resources inside the VPC communicate.

The `0.0.0.0/0` route means:

> For any IPv4 address that does not match a more specific route, send the traffic to this target.

## Security group

A security group is a virtual firewall attached to resources such as EC2 instances and Application Load Balancers.

Security groups are **stateful**.

That means when an allowed request enters, the answer is automatically allowed back.

## Network ACL

A Network Access Control List, or **NACL**, is a subnet-level firewall.

NACLs are **stateless**.

This means inbound and outbound traffic must both be allowed.

For a first lab, using the default NACL is simpler. Security groups provide the main filtering in this tutorial.

## EC2

Amazon EC2 provides virtual computers.

The EC2 instance in this tutorial runs Amazon Linux 2023 and a small Python HTTP server.

## AMI

An Amazon Machine Image, or **AMI**, is the starting image used to create an EC2 instance.

It contains:

- An operating system.
- Basic packages.
- Startup settings.
- Root-disk information.

## User data

User data is a script that EC2 can run during the first boot.

This tutorial uses user data to:

- Create the Hello HTML page.
- Create a Linux `systemd` service.
- Start the Python HTTP server.
- Start the server again after a reboot.

## Load balancer

A load balancer receives requests and sends them to healthy servers.

This tutorial uses an **Application Load Balancer**, or **ALB**.

An ALB is designed for HTTP and HTTPS traffic.

## Target group

A target group is a list of destinations that can receive load-balancer traffic.

The target in this lab is the EC2 instance.

## Health check

A health check is a test the load balancer sends to the server.

The load balancer requests:

```text
HTTP GET /
```

A `200` response means the target is healthy.

## Listener

A listener waits for traffic on a load-balancer port.

This lab creates:

```text
Protocol: HTTP
Port:     80
Action:   Forward to the target group
```

## Route 53

Amazon Route 53 is AWS's DNS service.

DNS translates a friendly name such as:

```text
hello.example.com
```

into the AWS load balancer destination.

## Hosted zone

A hosted zone is a container of DNS records for a domain.

A **public hosted zone** answers DNS questions from the internet.

A **private hosted zone** answers DNS questions from associated VPCs.

---

# 4. Pros and Cons of This Lab Design

## Advantages

- The EC2 server does not have a public IPv4 address.
- Port 22 is not opened for SSH.
- The web-server security group accepts HTTP only from the load balancer security group.
- The load balancer performs health checks.
- Two public subnets satisfy the multi-AZ requirement for an Application Load Balancer.
- The design avoids NAT Gateway charges.
- The resources are tagged for easier searching and cleanup.
- The latest Amazon Linux 2023 AMI is found through Systems Manager instead of using an old hard-coded AMI ID.
- IMDSv2 is required for improved EC2 metadata security.

## Disadvantages

- There is only one EC2 server, so the web application is not highly available.
- The server cannot download internet packages because there is no NAT Gateway.
- HTTP traffic is not encrypted.
- There is no Auto Scaling group.
- There is no AWS WAF.
- There are no application logs sent to CloudWatch.
- There is no secure management connection to the private instance.
- An Application Load Balancer has an hourly cost even when it receives little traffic.
- A public hosted zone has a monthly charge.
- Public IPv4 usage can add charges.

---

# 5. AWS CLI Basics

## What is the AWS CLI?

The AWS CLI is a program that lets you control AWS by typing commands.

Instead of clicking buttons in the AWS console, you type commands such as:

```bash
aws ec2 describe-vpcs
```

The CLI sends an API request to AWS. AWS checks:

1. Who you are.
2. Whether you have permission.
3. Whether the request is valid.
4. Whether service limits allow the request.
5. Whether dependent resources exist.

AWS then returns a response, usually as JSON.

## General command shape

```text
aws <service> <operation> <options>
```

Example:

```bash
aws ec2 describe-vpcs --region us-east-1 --output table
```

The pieces are:

```text
aws             Run the AWS CLI program.
ec2             Use the EC2 service API.
describe-vpcs   Ask AWS to list VPC information.
--region        Select the AWS Region.
us-east-1       The Region value.
--output table  Format the answer as a readable table.
```

## Common AWS CLI options

### `--region`

Chooses the AWS Region for the command.

```bash
--region "$REGION"
```

Route 53 is a global service, so some Route 53 commands do not use `--region`.

### `--query`

Filters the returned JSON using JMESPath.

Example:

```bash
--query "Vpc.VpcId"
```

This means:

> From the response, return only the value stored at `Vpc.VpcId`.

### `--output`

Controls how the answer is printed.

Common choices:

```text
json    Best for scripts and complete details.
text    Best when you need one plain value.
table   Best for people reading the screen.
yaml    Useful for readable structured output.
```

### `--filters`

Limits which resources are returned.

Example:

```bash
--filters "Name=vpc-id,Values=$VPC_ID"
```

This means:

> Return only resources whose VPC ID equals this VPC ID.

### `--tag-specifications`

Adds tags while a resource is being created.

Example:

```bash
--tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=${LAB_NAME}-vpc}]"
```

### `--dry-run`

Some EC2 commands support `--dry-run`.

It checks whether the request would be allowed without actually creating or changing the resource.

A successful permission test often returns:

```text
DryRunOperation
```

That looks like an error, but it means permission is available.

### Waiter commands

A waiter pauses until a resource reaches a certain state.

Example:

```bash
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
```

Without a waiter, the next command might run before the instance is ready.

---

# 6. Bash Features Used in This Tutorial

This tutorial is written for Bash on:

- macOS Terminal.
- Linux.
- AWS CloudShell.
- Git Bash.
- Windows Subsystem for Linux.

PowerShell uses different quoting and variable rules.

## Line continuation

A backslash at the end of a line means the command continues:

```bash
aws ec2 describe-vpcs \
  --region "$REGION" \
  --output table
```

Do not place spaces after the backslash.

## Variables

Create a variable:

```bash
export REGION="us-east-1"
```

Use the variable:

```bash
echo "$REGION"
```

Quotes help keep the value together safely.

## Command substitution

This runs a command and stores its answer:

```bash
export VPC_ID=$(aws ec2 create-vpc ...)
```

The inside command runs first. Its output becomes the value of `VPC_ID`.

## Here document

A here document creates a multi-line file:

```bash
cat > example.txt <<'EOF'
Line one
Line two
EOF
```

When the opening marker is quoted, variables inside the block are not expanded by your local shell.

## Safe Bash settings

```bash
set -euo pipefail
```

Meaning:

- `-e`: Stop after a failed command.
- `-u`: Stop when an undefined variable is used.
- `-o pipefail`: Treat failure inside a command pipeline as failure.

These settings help prevent a script from continuing after something goes wrong.

---

# 7. Prerequisites

You need:

- An AWS account.
- AWS CLI version 2.
- Bash or AWS CloudShell.
- IAM permission to create the lab resources.
- An optional domain for Route 53.
- A billing alert or budget.

## Check the AWS CLI

```bash
aws --version
```

What it does:

- Runs the local AWS CLI.
- Prints the installed version.
- Does not contact AWS.

## Check your identity

```bash
aws sts get-caller-identity
```

What it does:

- Calls AWS Security Token Service.
- Returns the AWS account ID.
- Returns the user or role ARN.
- Helps prevent creating resources in the wrong account.

Readable version:

```bash
aws sts get-caller-identity --output table
```

## Check the configured Region

```bash
aws configure get region
```

## See the active configuration

```bash
aws configure list
```

Be careful not to share secret access keys.

## Use a named profile

A named profile is useful when you work with several AWS accounts.

```bash
export AWS_PROFILE="lab"
export AWS_REGION="us-east-1"
```

Then commands use that profile unless another profile is supplied.

---

# 8. IAM Permission Background

AWS checks permissions before it performs each command.

For this lab, the user or role needs actions related to:

- VPCs.
- Subnets.
- Route tables.
- Internet gateways.
- Security groups.
- EC2 instances and volumes.
- Systems Manager public parameters.
- Elastic Load Balancing.
- Route 53, when DNS is used.
- Resource tags.

For a personal sandbox, broad managed policies are sometimes used temporarily.

For production:

- Use a custom least-privilege policy.
- Limit allowed Regions.
- Require tags.
- Prevent very large or expensive instance types.
- Protect shared Route 53 zones.
- Protect production VPCs.
- Use separate development and production accounts.

## Permission debugging

Add `--debug` to a command:

```bash
aws sts get-caller-identity --debug
```

This prints a large amount of technical information.

Use it only when needed because it is noisy.

Common IAM errors include:

```text
AccessDenied
UnauthorizedOperation
not authorized to perform
```

For some EC2 errors, decode the authorization message when your IAM permissions allow it.

---

# 9. Plan the Network Before Creating It

This tutorial uses:

```text
VPC                    10.20.0.0/16
Public subnet A        10.20.1.0/24
Public subnet B        10.20.2.0/24
Private subnet A       10.20.11.0/24
Private subnet B       10.20.12.0/24
```

## Why these ranges?

They are:

- Private IPv4 addresses.
- Easy to read.
- Large enough for a lab.
- Separated so public and private subnet ranges are easy to recognize.
- Non-overlapping.

## What overlapping means

These are bad because they overlap:

```text
10.20.1.0/24
10.20.1.128/25
```

The second range is already inside the first range.

AWS will reject overlapping subnets inside the same VPC.

## Production planning warning

Before choosing CIDR blocks for production, compare them with:

- Company office networks.
- VPN networks.
- Other VPCs.
- Azure virtual networks.
- On-premises data centers.
- Partner networks.
- Kubernetes pod and service networks.

Overlapping address ranges make network connections much harder.

---

# 10. Set Lab Variables

Run these commands in one terminal session:

```bash
set -euo pipefail

export AWS_PAGER=""
export REGION="us-east-1"
export LAB_NAME="hello-vpc-lab"

export VPC_CIDR="10.20.0.0/16"

export PUBLIC_CIDR_A="10.20.1.0/24"
export PUBLIC_CIDR_B="10.20.2.0/24"

export PRIVATE_CIDR_A="10.20.11.0/24"
export PRIVATE_CIDR_B="10.20.12.0/24"

export STATE_FILE="./${LAB_NAME}.env"
```

## What `AWS_PAGER=""` does

The AWS CLI may open long results in a pager program.

Setting this variable to an empty value tells the CLI to print results directly in the terminal.

## Find two available Availability Zones

```bash
export AZ_A=$(aws ec2 describe-availability-zones \
  --region "$REGION" \
  --filters "Name=state,Values=available" \
  --query "AvailabilityZones[0].ZoneName" \
  --output text)

export AZ_B=$(aws ec2 describe-availability-zones \
  --region "$REGION" \
  --filters "Name=state,Values=available" \
  --query "AvailabilityZones[1].ZoneName" \
  --output text)

echo "Availability Zone A: $AZ_A"
echo "Availability Zone B: $AZ_B"
```

### How this works

`describe-availability-zones` asks AWS for AZs.

The filter keeps AZs whose state is `available`.

The queries select the first and second zone names.

The `$(...)` stores each answer in a shell variable.

### Debugging

If either variable is empty:

```bash
aws ec2 describe-availability-zones \
  --region "$REGION" \
  --output table
```

Possible causes:

- Wrong Region.
- Region disabled for the account.
- Credential problem.
- Service control policy restriction.
- Network connection problem.

## Create the state file

```bash
cat > "$STATE_FILE" <<EOF
export REGION='$REGION'
export LAB_NAME='$LAB_NAME'
export VPC_CIDR='$VPC_CIDR'
export AZ_A='$AZ_A'
export AZ_B='$AZ_B'
EOF
```

The file records resource IDs for cleanup.

Protect it:

```bash
chmod 600 "$STATE_FILE"
```

---

# 11. Create the VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --region "$REGION" \
  --cidr-block "$VPC_CIDR" \
  --instance-tenancy default \
  --tag-specifications \
    "ResourceType=vpc,Tags=[{Key=Name,Value=${LAB_NAME}-vpc},{Key=Project,Value=${LAB_NAME}}]" \
  --query "Vpc.VpcId" \
  --output text)

echo "Created VPC: $VPC_ID"
echo "export VPC_ID='$VPC_ID'" >> "$STATE_FILE"
```

## Command explanation

```text
aws ec2 create-vpc
```

Calls the EC2/VPC API and creates a VPC.

```text
--cidr-block "$VPC_CIDR"
```

Assigns the main IPv4 range.

```text
--instance-tenancy default
```

Allows normal shared AWS hardware.

Dedicated tenancy is more expensive and not needed for this lab.

```text
--tag-specifications
```

Adds the `Name` and `Project` tags during creation.

```text
--query "Vpc.VpcId"
```

Keeps only the VPC ID.

```text
--output text
```

Returns a plain value such as:

```text
vpc-0123456789abcdef0
```

## Wait for the VPC

```bash
aws ec2 wait vpc-available \
  --region "$REGION" \
  --vpc-ids "$VPC_ID"
```

This prevents later steps from running before AWS marks the VPC as ready.

## Verify the VPC

```bash
aws ec2 describe-vpcs \
  --region "$REGION" \
  --vpc-ids "$VPC_ID" \
  --query "Vpcs[0].{VpcId:VpcId,CIDR:CidrBlock,State:State,Default:IsDefault}" \
  --output table
```

Expected state:

```text
available
```

## Common errors

### `InvalidVpc.Range`

The CIDR range is not valid.

Check spelling and CIDR notation.

### `VpcLimitExceeded`

The account reached its VPC quota in that Region.

List VPCs:

```bash
aws ec2 describe-vpcs \
  --region "$REGION" \
  --query "Vpcs[].{Id:VpcId,CIDR:CidrBlock,Default:IsDefault}" \
  --output table
```

### Empty `VPC_ID`

Run the create command without `--query` to see the full response.

---

# 12. Enable VPC DNS Features

```bash
aws ec2 modify-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --enable-dns-support '{"Value":true}'

aws ec2 modify-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames '{"Value":true}'
```

## What DNS support means

DNS support lets resources in the VPC use the AWS Route 53 Resolver.

## What DNS hostnames means

DNS hostnames lets eligible EC2 instances receive AWS DNS hostnames.

## Why use two commands?

The API modifies one VPC attribute per request.

## Verify

```bash
aws ec2 describe-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport

aws ec2 describe-vpc-attribute \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames
```

Both values should be `true`.

---

# 13. Create the Public Subnets

## Public subnet A

```bash
export PUBLIC_SUBNET_A=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --availability-zone "$AZ_A" \
  --cidr-block "$PUBLIC_CIDR_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=${LAB_NAME}-public-a},{Key=Project,Value=${LAB_NAME}},{Key=Tier,Value=public}]" \
  --query "Subnet.SubnetId" \
  --output text)

echo "export PUBLIC_SUBNET_A='$PUBLIC_SUBNET_A'" >> "$STATE_FILE"
```

## Public subnet B

```bash
export PUBLIC_SUBNET_B=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --availability-zone "$AZ_B" \
  --cidr-block "$PUBLIC_CIDR_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=${LAB_NAME}-public-b},{Key=Project,Value=${LAB_NAME}},{Key=Tier,Value=public}]" \
  --query "Subnet.SubnetId" \
  --output text)

echo "export PUBLIC_SUBNET_B='$PUBLIC_SUBNET_B'" >> "$STATE_FILE"
```

## Command explanation

`create-subnet` creates an IP-address range inside the VPC.

`--vpc-id` tells AWS which VPC owns the subnet.

`--availability-zone` places the subnet in one AZ.

A subnet exists in only one Availability Zone.

`--cidr-block` assigns the subnet range.

## Enable automatic public IPv4 assignment

```bash
aws ec2 modify-subnet-attribute \
  --region "$REGION" \
  --subnet-id "$PUBLIC_SUBNET_A" \
  --map-public-ip-on-launch

aws ec2 modify-subnet-attribute \
  --region "$REGION" \
  --subnet-id "$PUBLIC_SUBNET_B" \
  --map-public-ip-on-launch
```

This setting asks AWS to assign public IPv4 addresses to normal EC2 network interfaces launched in these subnets.

The ALB handles its own addressing, but the setting clearly marks the intended public-subnet behavior.

## Important lesson

Automatic public IP assignment does not make a subnet public by itself.

The route to the Internet Gateway is the main requirement.

---

# 14. Create the Private Subnets

## Private subnet A

```bash
export PRIVATE_SUBNET_A=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --availability-zone "$AZ_A" \
  --cidr-block "$PRIVATE_CIDR_A" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=${LAB_NAME}-private-a},{Key=Project,Value=${LAB_NAME}},{Key=Tier,Value=private}]" \
  --query "Subnet.SubnetId" \
  --output text)

echo "export PRIVATE_SUBNET_A='$PRIVATE_SUBNET_A'" >> "$STATE_FILE"
```

## Private subnet B

```bash
export PRIVATE_SUBNET_B=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --availability-zone "$AZ_B" \
  --cidr-block "$PRIVATE_CIDR_B" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=${LAB_NAME}-private-b},{Key=Project,Value=${LAB_NAME}},{Key=Tier,Value=private}]" \
  --query "Subnet.SubnetId" \
  --output text)

echo "export PRIVATE_SUBNET_B='$PRIVATE_SUBNET_B'" >> "$STATE_FILE"
```

## Disable automatic public IP assignment

```bash
aws ec2 modify-subnet-attribute \
  --region "$REGION" \
  --subnet-id "$PRIVATE_SUBNET_A" \
  --no-map-public-ip-on-launch

aws ec2 modify-subnet-attribute \
  --region "$REGION" \
  --subnet-id "$PRIVATE_SUBNET_B" \
  --no-map-public-ip-on-launch
```

## Verify all subnets

```bash
aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value,SubnetId:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,AvailableIPs:AvailableIpAddressCount,AutoPublicIP:MapPublicIpOnLaunch}" \
  --output table
```

## Common errors

### `InvalidSubnet.Conflict`

The new subnet overlaps an existing subnet.

### `InvalidParameterValue`

The subnet CIDR may be outside the VPC CIDR.

### Wrong Availability Zone

Make sure the AZ belongs to the selected Region.

---

# 15. Create and Attach the Internet Gateway

## Create it

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${LAB_NAME}-igw},{Key=Project,Value=${LAB_NAME}}]" \
  --query "InternetGateway.InternetGatewayId" \
  --output text)

echo "export IGW_ID='$IGW_ID'" >> "$STATE_FILE"
```

## Attach it

```bash
aws ec2 attach-internet-gateway \
  --region "$REGION" \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"
```

## Why create and attach are separate

The Internet Gateway is its own AWS resource.

Creating it makes the object.

Attaching it connects the object to this VPC.

## Verify

```bash
aws ec2 describe-internet-gateways \
  --region "$REGION" \
  --internet-gateway-ids "$IGW_ID" \
  --query "InternetGateways[0].{Id:InternetGatewayId,AttachedVpc:Attachments[0].VpcId,State:Attachments[0].State}" \
  --output table
```

Expected state:

```text
available
```

## Common errors

### Gateway already attached

An Internet Gateway can be attached to only one VPC at a time.

### `DependencyViolation` during deletion

The VPC may still contain resources using internet access, or the gateway is still attached.

---

# 16. Create the Public Route Table

```bash
export PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=${LAB_NAME}-public-rt},{Key=Project,Value=${LAB_NAME}}]" \
  --query "RouteTable.RouteTableId" \
  --output text)

echo "export PUBLIC_ROUTE_TABLE_ID='$PUBLIC_ROUTE_TABLE_ID'" >> "$STATE_FILE"
```

## Add the internet route

```bash
aws ec2 create-route \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID"
```

## Explain the route

```text
Destination: 0.0.0.0/0
Target:      Internet Gateway
```

This means all IPv4 internet destinations use the Internet Gateway.

The more specific VPC `local` route still handles VPC traffic.

## Associate public subnet A

```bash
export PUBLIC_ASSOC_A=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_A" \
  --query "AssociationId" \
  --output text)

echo "export PUBLIC_ASSOC_A='$PUBLIC_ASSOC_A'" >> "$STATE_FILE"
```

## Associate public subnet B

```bash
export PUBLIC_ASSOC_B=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_B" \
  --query "AssociationId" \
  --output text)

echo "export PUBLIC_ASSOC_B='$PUBLIC_ASSOC_B'" >> "$STATE_FILE"
```

## Why store association IDs?

The association ID is needed to explicitly remove the relationship during cleanup.

## Verify

```bash
aws ec2 describe-route-tables \
  --region "$REGION" \
  --route-table-ids "$PUBLIC_ROUTE_TABLE_ID" \
  --query "RouteTables[0].{Routes:Routes,Associations:Associations}" \
  --output json
```

Look for:

- A `local` route.
- A `0.0.0.0/0` route to the Internet Gateway.
- Associations with both public subnet IDs.

---

# 17. Create the Private Route Table

```bash
export PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=${LAB_NAME}-private-rt},{Key=Project,Value=${LAB_NAME}}]" \
  --query "RouteTable.RouteTableId" \
  --output text)

echo "export PRIVATE_ROUTE_TABLE_ID='$PRIVATE_ROUTE_TABLE_ID'" >> "$STATE_FILE"
```

## Associate private subnet A

```bash
export PRIVATE_ASSOC_A=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_A" \
  --query "AssociationId" \
  --output text)

echo "export PRIVATE_ASSOC_A='$PRIVATE_ASSOC_A'" >> "$STATE_FILE"
```

## Associate private subnet B

```bash
export PRIVATE_ASSOC_B=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_B" \
  --query "AssociationId" \
  --output text)

echo "export PRIVATE_ASSOC_B='$PRIVATE_ASSOC_B'" >> "$STATE_FILE"
```

## Why no internet route?

This lab keeps the private subnets isolated from direct internet access.

The route table contains only the automatic `local` route.

That route is enough for the ALB to reach the EC2 server through private VPC addresses.

## Verify

```bash
aws ec2 describe-route-tables \
  --region "$REGION" \
  --route-table-ids "$PRIVATE_ROUTE_TABLE_ID" \
  --query "RouteTables[0].Routes" \
  --output table
```

You should not see an active `0.0.0.0/0` route.

---

# 18. Route Table Debugging

## Show which route table a subnet uses

```bash
aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=association.subnet-id,Values=$PUBLIC_SUBNET_A" \
  --output table
```

## Check for blackhole routes

```bash
aws ec2 describe-route-tables \
  --region "$REGION" \
  --route-table-ids "$PUBLIC_ROUTE_TABLE_ID" "$PRIVATE_ROUTE_TABLE_ID" \
  --query "RouteTables[].Routes[?State=='blackhole']" \
  --output table
```

A blackhole route points to a missing or unavailable target.

## Common routing mistakes

- The public subnet is associated with the private route table.
- The `0.0.0.0/0` route points to the wrong gateway.
- The Internet Gateway exists but is not attached.
- The resource has no public address when direct internet access is expected.
- A NACL blocks traffic.
- A security group blocks traffic.

---

# 19. Create Security Groups

We create two security groups.

```text
ALB security group:
    Internet -> ALB TCP port 80

Web security group:
    ALB security group -> EC2 TCP port 80
```

This is safer than allowing the whole internet to reach the EC2 server.

## Create the ALB security group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "${LAB_NAME}-alb-sg" \
  --description "Allow public HTTP traffic to the hello Application Load Balancer" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" \
  --output text)

echo "export ALB_SG_ID='$ALB_SG_ID'" >> "$STATE_FILE"
```

## Tag it

```bash
aws ec2 create-tags \
  --region "$REGION" \
  --resources "$ALB_SG_ID" \
  --tags \
    "Key=Name,Value=${LAB_NAME}-alb-sg" \
    "Key=Project,Value=${LAB_NAME}"
```

## Allow HTTP from the internet

```bash
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0"
```

## Create the web-server security group

```bash
export WEB_SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "${LAB_NAME}-web-sg" \
  --description "Allow HTTP only from the hello Application Load Balancer" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" \
  --output text)

echo "export WEB_SG_ID='$WEB_SG_ID'" >> "$STATE_FILE"
```

## Tag it

```bash
aws ec2 create-tags \
  --region "$REGION" \
  --resources "$WEB_SG_ID" \
  --tags \
    "Key=Name,Value=${LAB_NAME}-web-sg" \
    "Key=Project,Value=${LAB_NAME}"
```

## Allow HTTP only from the ALB security group

```bash
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$WEB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --source-group "$ALB_SG_ID"
```

## Why use `--source-group`?

A security-group reference follows resources using that security group.

It is safer and easier than listing changing load-balancer IP addresses.

## Default security-group behavior

A newly created security group normally starts with:

- No inbound rules.
- An outbound rule allowing all outbound traffic.

This lab keeps the default outbound rule for simplicity.

## Security warning

`0.0.0.0/0` means every IPv4 address.

It is acceptable here only for public HTTP to the load balancer.

Do not use it for:

- SSH port 22.
- RDP port 3389.
- Database ports.
- Admin interfaces.
- Internal APIs.

## Verify security-group rules

```bash
aws ec2 describe-security-groups \
  --region "$REGION" \
  --group-ids "$ALB_SG_ID" "$WEB_SG_ID" \
  --query "SecurityGroups[].{Name:GroupName,Id:GroupId,Inbound:IpPermissions,Outbound:IpPermissionsEgress}" \
  --output json
```

---

# 20. Security Groups Versus Network ACLs

| Feature | Security group | Network ACL |
|---|---|---|
| Attached to | Resource or network interface | Subnet |
| Stateful | Yes | No |
| Allow rules | Yes | Yes |
| Deny rules | No | Yes |
| Rule order | All rules considered | Lowest rule number first |
| Return traffic | Automatically allowed | Must be allowed |
| Best use | Main resource firewall | Subnet boundary or explicit deny |

## Why the tutorial keeps the default NACL

Custom NACLs can cause confusing failures because return traffic uses temporary high-numbered ports.

For a first lab:

- Keep the default NACL.
- Learn security groups first.
- Add custom NACLs only when you understand the return path.

---

# 21. Create the Hello Web Startup Script

```bash
cat > hello-user-data.sh <<'USERDATA'
#!/bin/bash

set -euxo pipefail

mkdir -p /opt/hello-web

SERVER_HOSTNAME="$(hostname)"

cat > /opt/hello-web/index.html <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AWS Hello Server</title>
  <style>
    body {
      background: #f5f7fa;
      color: #102a43;
      font-family: Arial, sans-serif;
      margin: 0;
      padding: 40px 20px;
    }

    main {
      background: white;
      border-radius: 12px;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.12);
      margin: auto;
      max-width: 700px;
      padding: 35px;
    }

    h1 {
      color: #0066cc;
    }

    code {
      background: #edf2f7;
      border-radius: 4px;
      padding: 3px 6px;
    }
  </style>
</head>
<body>
  <main>
    <h1>Hello from AWS!</h1>
    <p>The Application Load Balancer successfully reached this EC2 server.</p>
    <p>Server hostname: <code>${SERVER_HOSTNAME}</code></p>
    <p>This server runs in a private subnet and has no public IPv4 address.</p>
  </main>
</body>
</html>
HTML

cat > /etc/systemd/system/hello-web.service <<'UNIT'
[Unit]
Description=Simple Python Hello HTTP Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/hello-web
ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now hello-web.service
USERDATA

chmod 700 hello-user-data.sh
```

## What the script does

### `#!/bin/bash`

Tells Linux to run the file with Bash.

### `set -euxo pipefail`

- Stops on failure.
- Prints commands to the startup log.
- Stops on undefined variables.
- Detects failures in pipelines.

### `mkdir -p /opt/hello-web`

Creates the web-content folder.

The `-p` option avoids an error if the folder already exists.

### `hostname`

Gets the server's host name.

Showing it on the page helps prove which server answered.

### `systemd`

`systemd` manages Linux background services.

The service file tells Linux:

- Where the web files are.
- Which command starts the server.
- To restart the server after failure.
- To start it during future boots.

### Python HTTP server

```bash
/usr/bin/python3 -m http.server 80 --bind 0.0.0.0
```

Meaning:

- Run Python 3.
- Run the built-in `http.server` module.
- Listen on TCP port 80.
- Listen on all instance network interfaces.

## Production warning

Python's built-in HTTP server is for learning and simple testing.

For production, use:

- Nginx.
- Apache HTTP Server.
- A Java, .NET, Node, Go, or Python application server.
- A container service.
- Proper logging, patching, monitoring, and TLS.

---

# 22. Find the Latest Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query "Parameter.Value" \
  --output text)

echo "AMI ID: $AMI_ID"
echo "export AMI_ID='$AMI_ID'" >> "$STATE_FILE"
```

## Why use Systems Manager Parameter Store?

AMI IDs differ by Region and change when AWS releases new images.

The public parameter points to the current Amazon Linux 2023 AMI for the Region.

## Explain the command

```text
aws ssm get-parameter
```

Reads one Systems Manager parameter.

```text
--name
```

Names the public parameter.

```text
--query "Parameter.Value"
```

Returns only the AMI ID.

## Verify the AMI

```bash
aws ec2 describe-images \
  --region "$REGION" \
  --image-ids "$AMI_ID" \
  --query "Images[0].{Id:ImageId,Name:Name,Owner:OwnerId,Architecture:Architecture,State:State,RootDevice:RootDeviceType}" \
  --output table
```

Make sure:

- State is `available`.
- Architecture is `x86_64`.
- The selected EC2 type supports that architecture.

---

# 23. Launch the EC2 Instance

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "t3.micro" \
  --subnet-id "$PRIVATE_SUBNET_A" \
  --security-group-ids "$WEB_SG_ID" \
  --user-data "file://hello-user-data.sh" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=${LAB_NAME}-web-1},{Key=Project,Value=${LAB_NAME}}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=${LAB_NAME}-web-1-root},{Key=Project,Value=${LAB_NAME}}]" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "Created instance: $INSTANCE_ID"
echo "export INSTANCE_ID='$INSTANCE_ID'" >> "$STATE_FILE"
```

## Command explanation

### `run-instances`

Launches one or more EC2 instances.

The default count is one when minimum and maximum counts are not separately supplied through other forms.

### `--image-id`

Chooses the operating-system image.

### `--instance-type`

Chooses CPU, memory, network performance, and price.

A small instance is enough for this lab.

Always confirm that the instance type is offered in your Region and account.

### `--subnet-id`

Places the instance in private subnet A.

### `--security-group-ids`

Attaches the web-server firewall.

### `--user-data`

Uploads the startup script.

The AWS CLI reads the local file and sends its contents with the launch request.

### `--metadata-options`

Requires IMDSv2 tokens.

The Instance Metadata Service can provide information such as:

- Instance ID.
- Region.
- IAM role credentials.
- Network information.

Requiring IMDSv2 provides stronger protection against some metadata-access attacks.

### Volume tags

The second tag specification tags the root EBS volume.

This helps with cost tracking and cleanup.

## Wait for the server

```bash
aws ec2 wait instance-running \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"

aws ec2 wait instance-status-ok \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"
```

The first waiter checks EC2 state.

The second waits for AWS system and instance status checks.

## Get the private IP

```bash
export INSTANCE_PRIVATE_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

echo "Private IP: $INSTANCE_PRIVATE_IP"
echo "export INSTANCE_PRIVATE_IP='$INSTANCE_PRIVATE_IP'" >> "$STATE_FILE"
```

## Verify no public IP

```bash
aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,Subnet:SubnetId,AZ:Placement.AvailabilityZone,Type:InstanceType}" \
  --output table
```

The public IP should be empty or `None`.

---

# 24. EC2 User-Data Debugging

User-data problems are common.

## Get EC2 console output

```bash
aws ec2 get-console-output \
  --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --latest \
  --output text
```

This may show:

- Boot messages.
- Cloud-init output.
- Script errors.
- Service startup errors.

## Important log files inside the instance

When management access is available, check:

```bash
sudo cat /var/log/cloud-init.log
sudo cat /var/log/cloud-init-output.log
sudo systemctl status hello-web.service
sudo journalctl -u hello-web.service
sudo ss -lntp
curl -i http://127.0.0.1/
```

## Why this private instance is harder to manage

It has:

- No public IP.
- No SSH rule.
- No NAT Gateway.
- No Systems Manager VPC endpoints.

That is secure and inexpensive, but interactive debugging is limited.

## Better production management options

### Systems Manager with NAT Gateway

**Pros**

- Easy outbound access.
- Supports package downloads and SSM.
- Managed by AWS.

**Cons**

- Hourly and data-processing costs.
- One NAT Gateway in one AZ can become a dependency for other AZs.
- High availability normally uses one NAT Gateway per active AZ.

### Systems Manager with interface VPC endpoints

**Pros**

- Private AWS API access.
- No general internet access.
- Good for controlled networks.

**Cons**

- Interface endpoints have hourly and data charges.
- Several endpoints may be required.
- DNS and security-group setup must be correct.

### Temporary bastion host

**Pros**

- Familiar SSH workflow.

**Cons**

- Adds another server to patch and protect.
- Requires strict IP restrictions.
- Can become an attack target.
- Often unnecessary when Systems Manager is available.

---

# 25. Create the Target Group

```bash
export TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --region "$REGION" \
  --name "${LAB_NAME}-tg" \
  --protocol HTTP \
  --port 80 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port traffic-port \
  --health-check-path "/" \
  --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher "HttpCode=200" \
  --tags \
    "Key=Name,Value=${LAB_NAME}-tg" \
    "Key=Project,Value=${LAB_NAME}" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

echo "export TARGET_GROUP_ARN='$TARGET_GROUP_ARN'" >> "$STATE_FILE"
```

## Why the command uses `elbv2`

The `elbv2` CLI service covers:

- Application Load Balancers.
- Network Load Balancers.
- Gateway Load Balancers.

## Important options

### `--protocol HTTP`

The ALB communicates with the target over HTTP.

### `--port 80`

The target service listens on port 80.

### `--target-type instance`

Targets are registered by EC2 instance ID.

Other target types include IP addresses and Lambda functions, depending on the load-balancer design.

### `--health-check-path "/"`

The ALB requests the root page.

### Thresholds

```text
healthy-threshold-count = 2
unhealthy-threshold-count = 2
```

This controls how many successful or failed health checks change the target state.

### Matcher

```text
HttpCode=200
```

Only HTTP 200 is considered healthy.

A wider production matcher might use:

```text
200-399
```

but that can hide redirect or application problems.

## Register the EC2 target

```bash
aws elbv2 register-targets \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --targets "Id=$INSTANCE_ID,Port=80"
```

## Verify registration

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --output table
```

At this point, the target may be `unused` because the target group is not yet connected to a listener.

---

# 26. Create the Application Load Balancer

```bash
export ALB_ARN=$(aws elbv2 create-load-balancer \
  --region "$REGION" \
  --name "${LAB_NAME}-alb" \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "$PUBLIC_SUBNET_A" "$PUBLIC_SUBNET_B" \
  --security-groups "$ALB_SG_ID" \
  --tags \
    "Key=Name,Value=${LAB_NAME}-alb" \
    "Key=Project,Value=${LAB_NAME}" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

echo "export ALB_ARN='$ALB_ARN'" >> "$STATE_FILE"
```

## Important options

### `--type application`

Creates an Application Load Balancer for HTTP and HTTPS.

### `--scheme internet-facing`

Makes the ALB reachable from the internet.

An `internal` ALB is reachable only through private networking.

### `--ip-address-type ipv4`

Uses IPv4.

A dual-stack design can support IPv4 and IPv6 when the VPC and subnets are configured for both.

### `--subnets`

Supplies two subnets in different Availability Zones.

An Application Load Balancer requires at least two Availability Zone subnets.

AWS recommends enough free IP addresses in each ALB subnet so the load balancer can scale.

The `/24` subnets used in this lab are more than large enough.

### `--security-groups`

Attaches the ALB firewall.

## Wait for the ALB

```bash
aws elbv2 wait load-balancer-available \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN"
```

## Get DNS and hosted-zone values

```bash
export ALB_DNS=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" \
  --output text)

export ALB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].CanonicalHostedZoneId" \
  --output text)

echo "ALB DNS name: $ALB_DNS"
echo "ALB hosted zone ID: $ALB_ZONE_ID"

echo "export ALB_DNS='$ALB_DNS'" >> "$STATE_FILE"
echo "export ALB_ZONE_ID='$ALB_ZONE_ID'" >> "$STATE_FILE"
```

## What is the canonical hosted-zone ID?

It identifies the AWS Route 53 zone that represents the load balancer.

Route 53 alias records need this value.

It is not the hosted-zone ID for your personal domain.

---

# 27. Create the HTTP Listener

```bash
export LISTENER_ARN=$(aws elbv2 create-listener \
  --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TARGET_GROUP_ARN" \
  --query "Listeners[0].ListenerArn" \
  --output text)

echo "export LISTENER_ARN='$LISTENER_ARN'" >> "$STATE_FILE"
```

## How it works

The listener waits on ALB port 80.

Its default action forwards requests to the target group.

A more advanced listener can use rules such as:

```text
/api/*      -> API target group
/images/*   -> image target group
Host name A -> application A
Host name B -> application B
```

## Wait for the target to become healthy

```bash
aws elbv2 wait target-in-service \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --targets "Id=$INSTANCE_ID,Port=80"
```

## Check target health

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --query "TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}" \
  --output table
```

Expected state:

```text
healthy
```

---

# 28. Test the Load Balancer

## Display the URL

```bash
echo "http://$ALB_DNS"
```

## Test response headers and body

```bash
curl -i "http://$ALB_DNS/"
```

Expected beginning:

```text
HTTP/1.0 200 OK
```

## Test only the HTTP status code

```bash
curl -s -o /dev/null -w "%{http_code}\n" "http://$ALB_DNS/"
```

Expected:

```text
200
```

## Repeat the test

```bash
for number in 1 2 3 4 5; do
  curl -s "http://$ALB_DNS/" | grep "Server hostname"
  sleep 1
done
```

With one target, the same server answers each time.

With multiple targets, this can help show load distribution.

---

# 29. How to Debug the Request Path

Debug from the outside toward the server.

## Layer 1: DNS

Question:

> Does the name resolve?

```bash
nslookup "$ALB_DNS"
```

or:

```bash
dig "$ALB_DNS"
```

## Layer 2: Load balancer state

```bash
aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].{State:State.Code,DNS:DNSName,Scheme:Scheme,VPC:VpcId,Subnets:AvailabilityZones[].SubnetId}" \
  --output table
```

The state should be `active`.

## Layer 3: Listener

```bash
aws elbv2 describe-listeners \
  --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --output table
```

Confirm HTTP port 80 exists.

## Layer 4: Target group

```bash
aws elbv2 describe-target-groups \
  --region "$REGION" \
  --target-group-arns "$TARGET_GROUP_ARN" \
  --output table
```

## Layer 5: Target health

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --output json
```

## Layer 6: Security groups

```bash
aws ec2 describe-security-groups \
  --region "$REGION" \
  --group-ids "$ALB_SG_ID" "$WEB_SG_ID" \
  --output json
```

Confirm:

- Internet to ALB on TCP 80.
- ALB security group to web security group on TCP 80.

## Layer 7: Route tables

```bash
aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output json
```

## Layer 8: EC2 status

```bash
aws ec2 describe-instance-status \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --include-all-instances \
  --output table
```

## Layer 9: Web service

Use console output or management access to check user-data and the service.

---

# 30. Common ALB Errors

## HTTP 503 Service Unavailable

Usually means there are no healthy targets.

Check:

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --output table
```

Possible causes:

- Web service is not running.
- Wrong target port.
- Wrong health-check path.
- Web security group blocks the ALB.
- Instance is still starting.
- Target is in an unavailable or disabled AZ.
- Application returns a non-matching HTTP code.

## HTTP 504 Gateway Timeout

The ALB reached toward the target but did not receive a response in time.

Possible causes:

- Application hung.
- Security rule problem.
- NACL return-traffic problem.
- Target overloaded.
- Application timeout too short or too long.
- Wrong port.

## Target says `unhealthy`

Read the reason:

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --query "TargetHealthDescriptions[].TargetHealth" \
  --output table
```

## Target says `unused`

Possible causes:

- Target group is not used by a listener rule.
- Target AZ is not enabled for the load balancer.
- Target is stopping or terminated.

---

# 31. Route 53 Public Hosted Zone Background

Route 53 DNS is optional because the ALB DNS name already works.

A public hosted zone is useful when you want:

```text
hello.example.com
```

instead of:

```text
hello-vpc-lab-alb-123456.us-east-1.elb.amazonaws.com
```

## Domain registration and hosted zones are different

A domain registration says you own or control the domain.

A hosted zone stores DNS records.

You can:

- Register the domain with Route 53 and host DNS in Route 53.
- Register the domain elsewhere and host DNS in Route 53.
- Register and host DNS somewhere else.

## Avoid duplicate hosted zones

Do not create another public hosted zone for a domain when a working zone already exists unless you understand DNS delegation.

A duplicate zone has different name servers and can create confusion.

---

# 32. Find or Create the Public Hosted Zone

Set your real domain:

```bash
export DOMAIN_NAME="example.com"
export RECORD_NAME="hello.${DOMAIN_NAME}"
```

Replace `example.com` with a domain you control.

## Look for an existing public zone

```bash
export PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$DOMAIN_NAME" \
  --query "HostedZones[?Name=='${DOMAIN_NAME}.' && Config.PrivateZone==\`false\`] | [0].Id" \
  --output text)
```

## Create it only when missing

```bash
if [[ -z "$PUBLIC_ZONE_ID" || "$PUBLIC_ZONE_ID" == "None" ]]; then
  export PUBLIC_ZONE_ID=$(aws route53 create-hosted-zone \
    --name "$DOMAIN_NAME" \
    --caller-reference "${LAB_NAME}-public-$(date +%s)" \
    --hosted-zone-config \
      "Comment=${LAB_NAME} public hosted zone,PrivateZone=false" \
    --query "HostedZone.Id" \
    --output text)

  export PUBLIC_ZONE_CREATED_BY_LAB="true"
else
  export PUBLIC_ZONE_CREATED_BY_LAB="false"
fi

export PUBLIC_ZONE_ID="${PUBLIC_ZONE_ID##*/}"

echo "Zone ID: $PUBLIC_ZONE_ID"
echo "Created by lab: $PUBLIC_ZONE_CREATED_BY_LAB"

echo "export DOMAIN_NAME='$DOMAIN_NAME'" >> "$STATE_FILE"
echo "export RECORD_NAME='$RECORD_NAME'" >> "$STATE_FILE"
echo "export PUBLIC_ZONE_ID='$PUBLIC_ZONE_ID'" >> "$STATE_FILE"
echo "export PUBLIC_ZONE_CREATED_BY_LAB='$PUBLIC_ZONE_CREATED_BY_LAB'" >> "$STATE_FILE"
```

## Why `caller-reference` must be unique

Route 53 uses it to help prevent the same create request from accidentally creating duplicates.

The current Unix timestamp makes the value unique.

## Show the assigned name servers

```bash
aws route53 get-hosted-zone \
  --id "$PUBLIC_ZONE_ID" \
  --query "DelegationSet.NameServers" \
  --output table
```

When the domain is registered elsewhere, configure these name servers at the registrar.

---

# 33. Create the Route 53 Alias Record

```bash
cat > route53-create-alias.json <<EOF
{
  "Comment": "Point ${RECORD_NAME} to the Hello Application Load Balancer",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_ZONE_ID}",
          "DNSName": "${ALB_DNS}.",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF
```

Apply it:

```bash
export DNS_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --change-batch "file://route53-create-alias.json" \
  --query "ChangeInfo.Id" \
  --output text)

aws route53 wait resource-record-sets-changed \
  --id "$DNS_CHANGE_ID"
```

## Explain the JSON

### `UPSERT`

Create the record if it does not exist.

Update it if it already exists.

### `Type: A`

This is an IPv4 address-style DNS record.

Because it is an AWS alias, you do not manually enter the ALB IP addresses.

### `AliasTarget`

Points the record to the ALB.

### `HostedZoneId`

This is the ALB's canonical hosted-zone ID.

### `DNSName`

This is the ALB DNS name.

The ending period means the DNS name is fully qualified.

### `EvaluateTargetHealth`

Lets Route 53 consider the health of the AWS alias target.

## Test DNS

```bash
dig "$RECORD_NAME"
```

Then:

```bash
curl -i "http://$RECORD_NAME/"
```

## Common DNS problems

- Registrar name servers do not match Route 53.
- A duplicate public hosted zone was created.
- The record exists in the wrong hosted zone.
- The domain name was typed incorrectly.
- DNS caching delays the visible change.
- The ALB was deleted and recreated, changing its DNS name.
- A private hosted zone with the same name changes answers inside the VPC.

---

# 34. Private Hosted Zones

A private hosted zone is used for internal DNS names.

Example:

```text
database.internal.example.com
keycloak.internal.example.com
nifi.internal.example.com
```

Create one only when needed because hosted zones have a cost.

```bash
export PRIVATE_DOMAIN="internal.${DOMAIN_NAME}"

export PRIVATE_ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$PRIVATE_DOMAIN" \
  --caller-reference "${LAB_NAME}-private-$(date +%s)" \
  --vpc "VPCRegion=${REGION},VPCId=${VPC_ID}" \
  --hosted-zone-config \
    "Comment=${LAB_NAME} private hosted zone,PrivateZone=true" \
  --query "HostedZone.Id" \
  --output text)

export PRIVATE_ZONE_ID="${PRIVATE_ZONE_ID##*/}"

echo "export PRIVATE_DOMAIN='$PRIVATE_DOMAIN'" >> "$STATE_FILE"
echo "export PRIVATE_ZONE_ID='$PRIVATE_ZONE_ID'" >> "$STATE_FILE"
```

## Pros

- Friendly internal names.
- Names are not published to the public internet.
- Useful for private applications and databases.
- Can be associated with multiple VPCs with proper authorization.

## Cons

- Adds cost.
- Can create split-horizon DNS confusion.
- VPC DNS settings must be enabled.
- Testing requires a DNS client inside an associated VPC.
- The same domain name in public and private zones can return different answers.

---

# 35. HTTPS for Production

This tutorial uses HTTP to keep the first lab simple.

Production public websites should normally use HTTPS.

A stronger design is:

```text
Internet
   |
HTTPS port 443
   |
ALB with ACM certificate
   |
HTTP or HTTPS to private targets
```

Common listener setup:

```text
Port 80  -> Redirect to HTTPS 443
Port 443 -> Forward to target group
```

## Benefits of HTTPS

- Encrypts browser traffic.
- Protects passwords and session cookies.
- Helps prevent content tampering.
- Expected by browsers and security tools.

## Required pieces

- A domain name.
- A validated AWS Certificate Manager certificate.
- An HTTPS listener.
- A security-group rule for TCP port 443.
- Optional HTTP-to-HTTPS redirect.

---

# 36. Cost Discussion

The VPC itself and many basic networking objects do not have hourly charges, but connected services can cost money.

Main possible costs include:

- EC2 instance time.
- EBS root volume storage.
- Application Load Balancer hours.
- Load Balancer Capacity Units.
- Public IPv4 addresses.
- Route 53 hosted zones.
- Route 53 DNS queries.
- Internet data transfer.
- CloudWatch logs and metrics beyond free allowances.
- NAT Gateway, when added.
- Interface VPC endpoints, when added.

## Why the ALB may cost more than the EC2 lab server

The ALB has a running-hour charge and usage-based capacity charges.

For a tiny lab with one small server, the load balancer can be a major part of the bill.

## Cheapest possible Hello test

The lowest-cost learning setup could be:

- One EC2 instance.
- One public subnet.
- One public IPv4 address.
- No ALB.
- No Route 53.

But that teaches less and exposes the server directly.

## This tutorial's balance

This tutorial spends more to teach:

- Multi-AZ public subnet layout.
- Load balancing.
- Target groups.
- Health checks.
- Security-group references.
- Private server placement.
- DNS aliases.

## Cost controls

- Set an AWS Budget.
- Tag all lab resources.
- Delete the lab the same day.
- Check Cost Explorer.
- Check public IPv4 usage.
- Avoid NAT Gateway unless required.
- Avoid duplicate hosted zones.
- Stop or terminate unused EC2 instances.
- Delete unused EBS volumes and snapshots.
- Delete unused load balancers.

---

# 37. VPC Flow Logs

VPC Flow Logs record network-traffic metadata.

They can help answer questions such as:

- Was traffic accepted or rejected?
- Which source IP sent traffic?
- Which destination port was used?
- Which network interface saw the traffic?

Flow Logs do not capture the full message body.

They can publish to:

- CloudWatch Logs.
- Amazon S3.
- Amazon Data Firehose.

## Pros

- Useful for security investigations.
- Helps find blocked traffic.
- Helps find unexpected traffic.
- Does not sit directly in the packet path.

## Cons

- Adds logging and storage costs.
- Records may not appear instantly.
- Requires IAM and log-destination setup.
- Does not replace application logs.

For a temporary lab, enable Flow Logs only when needed and delete the logging resources afterward.

---

# 38. Reachability Analyzer

VPC Reachability Analyzer checks AWS network configuration.

It does not send real test packets. It analyzes the configuration.

It can identify blockers such as:

- Security groups.
- Network ACLs.
- Route tables.
- Load-balancer settings.
- Missing network paths.

## Pros

- Useful when visual inspection is confusing.
- Shows the hop-by-hop path.
- Identifies a blocking component.

## Cons

- It checks configuration, not whether the application process is running.
- A path can be reachable while the web server is still broken.
- It may add analysis charges depending on current pricing.

Use it after checking simple items such as target health and security groups.

---

# 39. Production Improvements

## Add a second EC2 server

Place it in private subnet B.

**Benefit:** The application can survive one server failure.

## Use an Auto Scaling group

An Auto Scaling group can:

- Keep the desired number of servers running.
- Replace unhealthy servers.
- Scale based on demand.
- Spread instances across AZs.

## Use a launch template

A launch template stores:

- AMI.
- Instance type.
- Security groups.
- IAM role.
- User data.
- Metadata options.
- Storage settings.

## Add HTTPS

Use AWS Certificate Manager and an ALB HTTPS listener.

## Add Systems Manager

Use an instance profile plus NAT or VPC endpoints for private management.

## Add CloudWatch

Monitor:

- ALB 4XX and 5XX errors.
- Target response time.
- Healthy host count.
- EC2 CPU.
- Disk and memory through the CloudWatch agent.
- Application logs.

## Add AWS WAF

WAF can filter suspicious HTTP requests.

## Use Infrastructure as Code

For repeatable production deployments, use:

- Terraform.
- AWS CloudFormation.
- AWS CDK.

The AWS CLI is excellent for learning, testing, and troubleshooting. Infrastructure as Code is usually better for long-term repeatability.

---

# 40. Safe Destruction Order

AWS blocks deletion when another resource still depends on the resource.

Use this order:

```text
1. Route 53 alias record
2. Private hosted zone, when created
3. Public hosted zone, only when created by this lab
4. ALB listener
5. ALB
6. Target registration and target group
7. EC2 instance
8. Security groups
9. Route-table associations
10. Routes
11. Custom route tables
12. Subnets
13. Internet Gateway attachment
14. Internet Gateway
15. VPC
16. Local temporary files
```

---

# 41. Reload Saved Variables

Start cleanup in the directory containing the state file:

```bash
source "./hello-vpc-lab.env"
```

Check key values before deleting anything:

```bash
printf '%s\n' \
  "REGION=$REGION" \
  "VPC_ID=$VPC_ID" \
  "INSTANCE_ID=$INSTANCE_ID" \
  "ALB_ARN=$ALB_ARN"
```

Make sure these are lab resources, not production resources.

---

# 42. Delete the Route 53 Alias Record

Route 53 requires the delete request to match the current record.

```bash
if [[ -n "${PUBLIC_ZONE_ID:-}" && -n "${RECORD_NAME:-}" ]]; then
  cat > route53-delete-alias.json <<EOF
{
  "Comment": "Delete the Hello load balancer alias",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_ZONE_ID}",
          "DNSName": "${ALB_DNS}.",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

  DNS_DELETE_CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$PUBLIC_ZONE_ID" \
    --change-batch "file://route53-delete-alias.json" \
    --query "ChangeInfo.Id" \
    --output text)

  aws route53 wait resource-record-sets-changed \
    --id "$DNS_DELETE_CHANGE_ID"
fi
```

## If deletion fails

List the exact record:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json
```

Use the exact current values in the delete request.

---

# 43. Delete Hosted Zones

## Delete the private hosted zone

```bash
if [[ -n "${PRIVATE_ZONE_ID:-}" ]]; then
  aws route53 delete-hosted-zone \
    --id "$PRIVATE_ZONE_ID"
fi
```

A hosted zone cannot be deleted while it contains user-created records.

## Delete the public zone only when this lab created it

```bash
if [[ "${PUBLIC_ZONE_CREATED_BY_LAB:-false}" == "true" ]]; then
  aws route53 delete-hosted-zone \
    --id "$PUBLIC_ZONE_ID"
else
  echo "Keeping the existing public hosted zone."
fi
```

Never delete a shared or production hosted zone just to remove one lab record.

---

# 44. Delete the Listener and Load Balancer

## Listener

```bash
if [[ -n "${LISTENER_ARN:-}" ]]; then
  aws elbv2 delete-listener \
    --region "$REGION" \
    --listener-arn "$LISTENER_ARN"
fi
```

## Load balancer

```bash
aws elbv2 delete-load-balancer \
  --region "$REGION" \
  --load-balancer-arn "$ALB_ARN"

aws elbv2 wait load-balancers-deleted \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN"
```

The waiter is important because ALB network interfaces may remain for a short time.

Those interfaces can prevent subnet and security-group deletion.

---

# 45. Delete the Target Group

```bash
aws elbv2 deregister-targets \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --targets "Id=$INSTANCE_ID,Port=80" || true

aws elbv2 delete-target-group \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN"
```

`|| true` means cleanup continues if the target is already missing.

Use this carefully. It is acceptable for cleanup, but do not hide unexpected errors during resource creation.

---

# 46. Terminate the EC2 Instance

```bash
aws ec2 terminate-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"

aws ec2 wait instance-terminated \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"
```

## Stop versus terminate

### Stop

- Compute billing stops.
- EBS storage billing continues.
- Instance can start again.

### Terminate

- Instance is deleted.
- Root volume normally deletes when configured for delete on termination.
- Recovery is not normally possible.

For a temporary lab, terminate it.

## Check for remaining volumes

```bash
aws ec2 describe-volumes \
  --region "$REGION" \
  --filters "Name=tag:Project,Values=$LAB_NAME" \
  --query "Volumes[].{Id:VolumeId,State:State,SizeGiB:Size,AttachedTo:Attachments[0].InstanceId}" \
  --output table
```

Delete only volumes that you have confirmed are unused lab volumes.

---

# 47. Delete Security Groups

Delete the web group first because it references the ALB group.

```bash
aws ec2 delete-security-group \
  --region "$REGION" \
  --group-id "$WEB_SG_ID"

aws ec2 delete-security-group \
  --region "$REGION" \
  --group-id "$ALB_SG_ID"
```

## If you receive `DependencyViolation`

Look for network interfaces still using the groups:

```bash
aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=group-id,Values=$WEB_SG_ID,$ALB_SG_ID" \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Description:Description,Status:Status,Requester:RequesterId,Subnet:SubnetId}" \
  --output table
```

Wait for ALB interfaces to disappear after ALB deletion.

---

# 48. Remove Route-Table Associations

```bash
aws ec2 disassociate-route-table \
  --region "$REGION" \
  --association-id "$PUBLIC_ASSOC_A"

aws ec2 disassociate-route-table \
  --region "$REGION" \
  --association-id "$PUBLIC_ASSOC_B"

aws ec2 disassociate-route-table \
  --region "$REGION" \
  --association-id "$PRIVATE_ASSOC_A"

aws ec2 disassociate-route-table \
  --region "$REGION" \
  --association-id "$PRIVATE_ASSOC_B"
```

A subnet that loses an explicit association falls back to the VPC main route table.

This is temporary because the subnets will be deleted next.

---

# 49. Delete Routes and Custom Route Tables

Delete the public default route:

```bash
aws ec2 delete-route \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block "0.0.0.0/0"
```

Delete custom route tables:

```bash
aws ec2 delete-route-table \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID"

aws ec2 delete-route-table \
  --region "$REGION" \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID"
```

You cannot delete the VPC's main route table directly. AWS removes it when the VPC is deleted.

---

# 50. Delete the Subnets

```bash
aws ec2 delete-subnet \
  --region "$REGION" \
  --subnet-id "$PRIVATE_SUBNET_A"

aws ec2 delete-subnet \
  --region "$REGION" \
  --subnet-id "$PRIVATE_SUBNET_B"

aws ec2 delete-subnet \
  --region "$REGION" \
  --subnet-id "$PUBLIC_SUBNET_A"

aws ec2 delete-subnet \
  --region "$REGION" \
  --subnet-id "$PUBLIC_SUBNET_B"
```

## If subnet deletion fails

Find network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=subnet-id,Values=$PUBLIC_SUBNET_A,$PUBLIC_SUBNET_B,$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_B" \
  --query "NetworkInterfaces[].{Id:NetworkInterfaceId,Description:Description,Status:Status,RequesterManaged:RequesterManaged}" \
  --output table
```

Possible dependencies include:

- ALB interfaces.
- EC2 interfaces.
- NAT Gateway interfaces.
- VPC endpoints.
- Lambda VPC interfaces.
- RDS interfaces.
- EFS mount targets.

---

# 51. Detach and Delete the Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --region "$REGION" \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"

aws ec2 delete-internet-gateway \
  --region "$REGION" \
  --internet-gateway-id "$IGW_ID"
```

It must be detached before it can be deleted.

---

# 52. Delete the VPC

```bash
aws ec2 delete-vpc \
  --region "$REGION" \
  --vpc-id "$VPC_ID"
```

AWS deletes VPC-owned default objects such as:

- Main route table.
- Default security group.
- Default network ACL.

## If VPC deletion fails

List likely dependencies.

### Network interfaces

```bash
aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

### VPC endpoints

```bash
aws ec2 describe-vpc-endpoints \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

### NAT Gateways

```bash
aws ec2 describe-nat-gateways \
  --region "$REGION" \
  --filter "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

### Remaining subnets

```bash
aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

### Remaining route tables

```bash
aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

### Remaining security groups

```bash
aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

---

# 53. Remove Local Files

```bash
rm -f hello-user-data.sh
rm -f route53-create-alias.json
rm -f route53-delete-alias.json
rm -f "$STATE_FILE"
```

Do this only after AWS cleanup succeeds.

Keeping the state file until the end helps you retry failed cleanup steps.

---

# 54. Verify Cleanup

## Tagged resources

```bash
aws resourcegroupstaggingapi get-resources \
  --region "$REGION" \
  --tag-filters "Key=Project,Values=$LAB_NAME" \
  --query "ResourceTagMappingList[].ResourceARN" \
  --output table
```

Not every AWS resource type is returned by the tagging API, so also run service-specific checks.

## EC2 instances

```bash
aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=$LAB_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].{Id:InstanceId,State:State.Name}" \
  --output table
```

## Load balancers

```bash
aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, '$LAB_NAME')].{Name:LoadBalancerName,Arn:LoadBalancerArn}" \
  --output table
```

## Target groups

```bash
aws elbv2 describe-target-groups \
  --region "$REGION" \
  --query "TargetGroups[?contains(TargetGroupName, '$LAB_NAME')].{Name:TargetGroupName,Arn:TargetGroupArn}" \
  --output table
```

## Hosted zones

```bash
aws route53 list-hosted-zones \
  --query "HostedZones[].{Name:Name,Id:Id,Private:Config.PrivateZone}" \
  --output table
```

---

# 55. Troubleshooting Table

| Problem | Likely cause | First command |
|---|---|---|
| AWS CLI cannot connect | Local network, proxy, DNS, or credentials | `aws sts get-caller-identity --debug` |
| Access denied | IAM, permission boundary, SCP, or session policy | Re-run command and read the denied action |
| VPC ID empty | Query returned nothing or create failed | Run command without `--query` |
| Subnet conflict | CIDR overlap | `aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID` |
| ALB creation fails | Same AZ twice, subnet too small, missing IGW, quota | Describe subnets and IGW |
| Target unhealthy | App, port, SG, NACL, health path | `aws elbv2 describe-target-health` |
| ALB gives 503 | No healthy target | Target-health command |
| ALB gives 504 | Target timeout or blocked return traffic | Target health, SGs, NACLs |
| DNS name not found | Delegation or wrong hosted zone | `aws route53 get-hosted-zone` |
| Security group will not delete | ENI still uses it | `aws ec2 describe-network-interfaces` |
| Subnet will not delete | ENI or managed resource remains | Describe ENIs by subnet |
| VPC will not delete | Dependent resource remains | Describe ENIs, endpoints, subnets, routes |
| User data did not work | Script error or service failure | `aws ec2 get-console-output` |

---

# 56. AWS CLI Help Commands

Show service help:

```bash
aws ec2 help
```

Show operation help:

```bash
aws ec2 create-vpc help
```

Show load-balancer help:

```bash
aws elbv2 create-load-balancer help
```

Show Route 53 record help:

```bash
aws route53 change-resource-record-sets help
```

Generate a CLI skeleton:

```bash
aws ec2 run-instances --generate-cli-skeleton input
```

This prints an example JSON structure.

It can be large, but it helps show available settings.

---

# 57. Final Knowledge Check

After completing this lab, you should understand:

1. A VPC is the main private AWS network.
2. A subnet is a smaller IP range inside one Availability Zone.
3. A public subnet has a direct route to an Internet Gateway.
4. A private subnet does not have that direct route.
5. Security groups are stateful resource firewalls.
6. Network ACLs are stateless subnet firewalls.
7. An ALB needs subnets in at least two Availability Zones.
8. A listener accepts traffic and chooses an action.
9. A target group stores destinations and health-check settings.
10. A health check decides whether traffic should reach a target.
11. Route 53 hosted zones store DNS records.
12. An alias record can point a friendly domain name to an ALB.
13. User data can configure an EC2 server during startup.
14. AWS waiter commands prevent scripts from moving too quickly.
15. Deletion must happen in dependency order.
16. Tags help with ownership, cost tracking, searching, and cleanup.
17. The cheapest design is not always the safest or most educational.
18. Production normally adds HTTPS, multiple targets, Auto Scaling, monitoring, and secure management.

---

# 58. Official AWS Documentation Topics Used for This Guide

Look for these titles in the official AWS documentation:

- Getting started with Amazon VPC using the AWS CLI.
- What is Amazon VPC?
- Subnets for your VPC.
- Subnet route tables.
- Enable internet access for a VPC using an Internet Gateway.
- Security groups for your VPC.
- Network ACLs for your VPC.
- Run commands on your Linux instance at launch.
- Reference the latest AMIs using Systems Manager public parameters.
- What is an Application Load Balancer?
- Application Load Balancer target groups.
- Health checks for Application Load Balancer target groups.
- Troubleshoot your Application Load Balancers.
- Routing traffic to an ELB load balancer with Route 53.
- Working with public and private hosted zones.
- VPC Flow Logs.
- VPC Reachability Analyzer.
- AWS CLI command structure, output, filtering, quoting, and waiter commands.
