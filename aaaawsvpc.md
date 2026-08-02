# AWS VPC, Public/Private Subnets, Route 53, Load Balancer, and EC2 Tutorial

This lab builds a small AWS network with:

```text
                           Internet
                               |
                     Route 53 Public DNS
                    hello.yourdomain.com
                               |
                    Application Load Balancer
                     /                     \
        Public Subnet A                 Public Subnet B
             AZ 1                           AZ 2
                     \                     /
                      \                   /
                       EC2 Hello Server
                       Private Subnet A

             Private Subnet B is ready for future use
```

The EC2 server has **no public IP address**. Only the load balancer can contact it. We also avoid a NAT Gateway because NAT Gateways can make a small lab unnecessarily expensive.

An internet gateway and a route to `0.0.0.0/0` make the public subnets internet-facing. The private subnets have only the VPC's local route, so they do not have direct internet access. Every subnet must use a route table. ([AWS Documentation][1])

---

## 1. What the AWS pieces mean

| AWS resource              | Middle-school explanation                                                         |
| ------------------------- | --------------------------------------------------------------------------------- |
| VPC                       | Your private fenced-in network inside AWS.                                        |
| CIDR block                | The range of private IP addresses available inside the network.                   |
| Availability Zone         | A separate AWS data-center area inside a Region.                                  |
| Public subnet             | A network section with a route to an internet gateway.                            |
| Private subnet            | A network section without a direct internet route.                                |
| Internet gateway          | The front door connecting the VPC to the internet.                                |
| Route table               | A list of road signs telling network traffic where to go.                         |
| Security group            | A virtual firewall controlling allowed traffic.                                   |
| EC2                       | A virtual computer.                                                               |
| Target group              | The list of servers receiving traffic from a load balancer.                       |
| Application Load Balancer | The traffic director that sends HTTP requests to healthy servers.                 |
| Listener                  | The load balancer rule that listens on a port, such as HTTP port 80.              |
| Hosted zone               | The Route 53 container holding DNS records for a domain.                          |
| Alias record              | A Route 53 DNS record pointing a name to an AWS resource such as a load balancer. |

An Application Load Balancer uses listeners, target groups, and health checks to decide where requests should go. For an internet-facing Application Load Balancer, using public subnets in two Availability Zones provides the required network layout. ([AWS Documentation][2])

---

# 2. Cost warning

The inexpensive parts are the VPC, subnets, route tables, security groups, and internet gateway themselves. The primary charges in this lab come from:

* The EC2 instance and its EBS disk.
* The Application Load Balancer.
* Public IPv4 addresses used by the internet-facing load balancer.
* A Route 53 hosted zone.
* Data transfer and load-balancer usage.

In the US East (N. Virginia) pricing example, an Application Load Balancer has a base charge of `$0.0225` per hour plus LCU usage. Public IPv4 addresses are currently listed at `$0.005` per address-hour, and the first 25 Route 53 hosted zones are `$0.50` each per month. Prices vary by Region and usage. ([Amazon Web Services, Inc.][3])

Do not assume the lab is free. AWS now uses a credit-based Free Tier for many new accounts, while existing accounts can have different benefits. ([Amazon Web Services, Inc.][4])

**Best cost-saving practice:** complete the lab, test it, and run the destruction commands the same day.

---

# 3. Prerequisites

You need:

1. An AWS account.
2. AWS CLI version 2.
3. Permission to create VPC, EC2, Elastic Load Balancing, and Route 53 resources.
4. A Bash terminal, such as:

   * macOS Terminal
   * Linux
   * AWS CloudShell
   * Git Bash
5. An optional domain name for the Route 53 section.

Verify the CLI:

```bash
aws --version
```

Verify your identity:

```bash
aws sts get-caller-identity
```

You should see your AWS account number and IAM user or role.

Set your default Region:

```bash
aws configure
```

AWS will ask for:

```text
AWS Access Key ID:
AWS Secret Access Key:
Default region name: us-east-1
Default output format: json
```

Do not use root-account access keys.

---

# 4. Set the lab variables

Run the following in one terminal.

```bash
# Stop the script when a command fails.
set -euo pipefail

# Turn off the AWS CLI screen pager.
export AWS_PAGER=""

# AWS Region used by this tutorial.
export REGION="us-east-1"

# A short name added to the resources.
export LAB_NAME="hello-vpc-lab"

# Main VPC address range.
export VPC_CIDR="10.20.0.0/16"

# Public subnet address ranges.
export PUBLIC_CIDR_A="10.20.1.0/24"
export PUBLIC_CIDR_B="10.20.2.0/24"

# Private subnet address ranges.
export PRIVATE_CIDR_A="10.20.11.0/24"
export PRIVATE_CIDR_B="10.20.12.0/24"

# File where resource IDs will be saved.
export STATE_FILE="./${LAB_NAME}.env"

# Find two available Availability Zones.
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

echo "First Availability Zone:  $AZ_A"
echo "Second Availability Zone: $AZ_B"
```

Create the state file:

```bash
cat > "$STATE_FILE" <<EOF
export REGION='$REGION'
export LAB_NAME='$LAB_NAME'
export VPC_CIDR='$VPC_CIDR'
export AZ_A='$AZ_A'
export AZ_B='$AZ_B'
EOF
```

The state file is important because it stores the AWS resource IDs needed during cleanup.

---

# 5. Create the VPC

A VPC is the large network container.

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

Wait until AWS finishes creating it:

```bash
aws ec2 wait vpc-available \
  --region "$REGION" \
  --vpc-ids "$VPC_ID"
```

Enable DNS support:

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

These settings allow resources in the VPC to use AWS DNS names.

Verify:

```bash
aws ec2 describe-vpcs \
  --region "$REGION" \
  --vpc-ids "$VPC_ID" \
  --query "Vpcs[0].{VpcId:VpcId,Cidr:CidrBlock,State:State}" \
  --output table
```

---

# 6. Create two public subnets

The load balancer will use these subnets.

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

echo "Created public subnet A: $PUBLIC_SUBNET_A"
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

echo "Created public subnet B: $PUBLIC_SUBNET_B"
echo "export PUBLIC_SUBNET_B='$PUBLIC_SUBNET_B'" >> "$STATE_FILE"
```

Enable automatic public IP assignment for regular instances that might later be launched in these subnets:

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

The load balancer will be placed across these two Availability Zones.

---

# 7. Create two private subnets

The EC2 web server will run in private subnet A.

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

echo "Created private subnet A: $PRIVATE_SUBNET_A"
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

echo "Created private subnet B: $PRIVATE_SUBNET_B"
echo "export PRIVATE_SUBNET_B='$PRIVATE_SUBNET_B'" >> "$STATE_FILE"
```

Make sure private subnets do not automatically assign public IP addresses:

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

Verify all four subnets:

```bash
aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value,SubnetId:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}" \
  --output table
```

---

# 8. Create and attach the internet gateway

The internet gateway is the VPC's internet door.

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications \
    "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${LAB_NAME}-igw},{Key=Project,Value=${LAB_NAME}}]" \
  --query "InternetGateway.InternetGatewayId" \
  --output text)

echo "Created internet gateway: $IGW_ID"
echo "export IGW_ID='$IGW_ID'" >> "$STATE_FILE"
```

Attach it to the VPC:

```bash
aws ec2 attach-internet-gateway \
  --region "$REGION" \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"
```

Creating an internet gateway is not enough by itself. The public route table must also send internet traffic to it. ([AWS Documentation][1])

---

# 9. Create the public route table

Create the route table:

```bash
export PUBLIC_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=${LAB_NAME}-public-rt},{Key=Project,Value=${LAB_NAME}}]" \
  --query "RouteTable.RouteTableId" \
  --output text)

echo "Created public route table: $PUBLIC_ROUTE_TABLE_ID"
echo "export PUBLIC_ROUTE_TABLE_ID='$PUBLIC_ROUTE_TABLE_ID'" >> "$STATE_FILE"
```

Add the internet route:

```bash
aws ec2 create-route \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID"
```

`0.0.0.0/0` means:

> Send traffic for any IPv4 destination that does not have a more specific route to the internet gateway.

Associate public subnet A:

```bash
export PUBLIC_ASSOC_A=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_A" \
  --query "AssociationId" \
  --output text)

echo "export PUBLIC_ASSOC_A='$PUBLIC_ASSOC_A'" >> "$STATE_FILE"
```

Associate public subnet B:

```bash
export PUBLIC_ASSOC_B=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --subnet-id "$PUBLIC_SUBNET_B" \
  --query "AssociationId" \
  --output text)

echo "export PUBLIC_ASSOC_B='$PUBLIC_ASSOC_B'" >> "$STATE_FILE"
```

---

# 10. Create the private route table

The private route table will not receive an internet route.

```bash
export PRIVATE_ROUTE_TABLE_ID=$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=${LAB_NAME}-private-rt},{Key=Project,Value=${LAB_NAME}}]" \
  --query "RouteTable.RouteTableId" \
  --output text)

echo "Created private route table: $PRIVATE_ROUTE_TABLE_ID"
echo "export PRIVATE_ROUTE_TABLE_ID='$PRIVATE_ROUTE_TABLE_ID'" >> "$STATE_FILE"
```

Associate private subnet A:

```bash
export PRIVATE_ASSOC_A=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_A" \
  --query "AssociationId" \
  --output text)

echo "export PRIVATE_ASSOC_A='$PRIVATE_ASSOC_A'" >> "$STATE_FILE"
```

Associate private subnet B:

```bash
export PRIVATE_ASSOC_B=$(aws ec2 associate-route-table \
  --region "$REGION" \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID" \
  --subnet-id "$PRIVATE_SUBNET_B" \
  --query "AssociationId" \
  --output text)

echo "export PRIVATE_ASSOC_B='$PRIVATE_ASSOC_B'" >> "$STATE_FILE"
```

AWS automatically adds a `local` route for the VPC CIDR. That local route lets the load balancer communicate with the private EC2 server. We intentionally do not add `0.0.0.0/0` to this route table.

Verify the route tables:

```bash
aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "RouteTables[].{Name:Tags[?Key=='Name']|[0].Value,RouteTableId:RouteTableId,Routes:Routes[].{Destination:DestinationCidrBlock,Gateway:GatewayId}}" \
  --output json
```

---

# 11. Create the security groups

We need two firewalls:

```text
ALB security group
    Allows HTTP port 80 from the internet

Web-server security group
    Allows HTTP port 80 only from the ALB security group
```

## Load balancer security group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "${LAB_NAME}-alb-sg" \
  --description "Allow public HTTP traffic to the hello load balancer" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" \
  --output text)

echo "Created ALB security group: $ALB_SG_ID"
echo "export ALB_SG_ID='$ALB_SG_ID'" >> "$STATE_FILE"
```

Tag it:

```bash
aws ec2 create-tags \
  --region "$REGION" \
  --resources "$ALB_SG_ID" \
  --tags \
    "Key=Name,Value=${LAB_NAME}-alb-sg" \
    "Key=Project,Value=${LAB_NAME}"
```

Allow public HTTP:

```bash
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0"
```

## Web-server security group

```bash
export WEB_SG_ID=$(aws ec2 create-security-group \
  --region "$REGION" \
  --group-name "${LAB_NAME}-web-sg" \
  --description "Allow HTTP only from the hello load balancer" \
  --vpc-id "$VPC_ID" \
  --query "GroupId" \
  --output text)

echo "Created web security group: $WEB_SG_ID"
echo "export WEB_SG_ID='$WEB_SG_ID'" >> "$STATE_FILE"
```

Tag it:

```bash
aws ec2 create-tags \
  --region "$REGION" \
  --resources "$WEB_SG_ID" \
  --tags \
    "Key=Name,Value=${LAB_NAME}-web-sg" \
    "Key=Project,Value=${LAB_NAME}"
```

Allow the load balancer to contact the server:

```bash
aws ec2 authorize-security-group-ingress \
  --region "$REGION" \
  --group-id "$WEB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --source-group "$ALB_SG_ID"
```

This rule does not allow the entire internet to contact EC2. It allows only resources using the load balancer security group. Security groups work like virtual firewalls. ([AWS Documentation][5])

We do not open SSH port 22.

---

# 12. Create the Hello HTTP startup script

Amazon Linux 2023 provides `/usr/bin/python3`. We will use its small built-in HTTP server. This avoids downloading Apache from the internet and lets the instance remain fully private without a NAT Gateway. ([AWS Documentation][6])

Create the EC2 user-data file:

```bash
cat > hello-user-data.sh <<'USERDATA'
#!/bin/bash

# Stop if a command fails and print commands to the startup log.
set -euxo pipefail

# Create a folder for the website.
mkdir -p /opt/hello-web

# Get the server's hostname.
SERVER_HOSTNAME="$(hostname)"

# Create the Hello web page.
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

    <p>The Application Load Balancer successfully reached the EC2 server.</p>

    <p>
      Server hostname:
      <code>${SERVER_HOSTNAME}</code>
    </p>

    <p>
      This server is running in a private subnet and does not have a public
      IP address.
    </p>
  </main>
</body>
</html>
HTML

# Create a systemd service so the server starts every time EC2 boots.
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

# Tell Linux about the new service.
systemctl daemon-reload

# Start the service now and during future boots.
systemctl enable --now hello-web.service
USERDATA
```

Make the local file executable:

```bash
chmod +x hello-user-data.sh
```

---

# 13. Find the latest Amazon Linux 2023 AMI

Do not hard-code an old AMI ID. AWS publishes current Amazon Linux AMI IDs through Systems Manager public parameters. ([AWS Documentation][7])

```bash
export AMI_ID=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query "Parameter.Value" \
  --output text)

echo "Latest Amazon Linux 2023 AMI: $AMI_ID"
echo "export AMI_ID='$AMI_ID'" >> "$STATE_FILE"
```

---

# 14. Launch the private EC2 server

This instance:

* Runs in private subnet A.
* Has no public IP.
* Has no SSH rule.
* Accepts HTTP only from the load balancer.
* Uses IMDSv2 for stronger metadata security.

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

echo "Created EC2 instance: $INSTANCE_ID"
echo "export INSTANCE_ID='$INSTANCE_ID'" >> "$STATE_FILE"
```

Wait for the instance:

```bash
aws ec2 wait instance-running \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"

aws ec2 wait instance-status-ok \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"
```

Get its private IP:

```bash
export INSTANCE_PRIVATE_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

echo "EC2 private IP: $INSTANCE_PRIVATE_IP"
echo "export INSTANCE_PRIVATE_IP='$INSTANCE_PRIVATE_IP'" >> "$STATE_FILE"
```

Verify that it has no public IP:

```bash
aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].{Instance:InstanceId,State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,Subnet:SubnetId}" \
  --output table
```

The `PublicIP` value should be blank or `None`.

---

# 15. Create the target group

The target group is the load balancer's list of destination servers.

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

echo "Created target group: $TARGET_GROUP_ARN"
echo "export TARGET_GROUP_ARN='$TARGET_GROUP_ARN'" >> "$STATE_FILE"
```

Register the EC2 server:

```bash
aws elbv2 register-targets \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --targets "Id=$INSTANCE_ID,Port=80"
```

AWS health checks periodically request `/`. The target becomes healthy when it answers with HTTP status `200`. ([AWS Documentation][8])

---

# 16. Create the Application Load Balancer

The load balancer is internet-facing and uses both public subnets.

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

echo "Created load balancer: $ALB_ARN"
echo "export ALB_ARN='$ALB_ARN'" >> "$STATE_FILE"
```

Wait until it is available:

```bash
aws elbv2 wait load-balancer-available \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN"
```

Get its DNS name and Route 53 zone ID:

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

echo "Load balancer DNS: $ALB_DNS"
echo "Load balancer Route 53 zone ID: $ALB_ZONE_ID"

echo "export ALB_DNS='$ALB_DNS'" >> "$STATE_FILE"
echo "export ALB_ZONE_ID='$ALB_ZONE_ID'" >> "$STATE_FILE"
```

---

# 17. Create the HTTP listener

The listener receives HTTP requests on port 80 and forwards them to the target group.

```bash
export LISTENER_ARN=$(aws elbv2 create-listener \
  --region "$REGION" \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TARGET_GROUP_ARN" \
  --query "Listeners[0].ListenerArn" \
  --output text)

echo "Created listener: $LISTENER_ARN"
echo "export LISTENER_ARN='$LISTENER_ARN'" >> "$STATE_FILE"
```

The listener connects the load balancer to the target group. ([AWS Documentation][9])

Wait for the target to become healthy:

```bash
aws elbv2 wait target-in-service \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --targets "Id=$INSTANCE_ID,Port=80"
```

Check health:

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --query "TargetHealthDescriptions[].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}" \
  --output table
```

You want to see:

```text
State
-------
healthy
```

---

# 18. Test the website

Display the address:

```bash
echo "http://$ALB_DNS"
```

Test it with `curl`:

```bash
curl -i "http://$ALB_DNS/"
```

You should receive:

```text
HTTP/1.0 200 OK
```

Open this address in a browser:

```text
http://your-load-balancer-name.us-east-1.elb.amazonaws.com
```

The page should say:

```text
Hello from AWS!
```

---

# 19. Add a Route 53 public hosted zone

This section is optional.

The load balancer DNS name already works. Route 53 gives you a friendlier address such as:

```text
hello.example.com
```

A public hosted zone does **not** automatically purchase a domain. You must own the domain or have permission to manage its DNS. When a public zone is created, Route 53 provides name servers. If the domain is registered elsewhere, those name servers must be entered at the domain registrar. ([AWS Documentation][10])

Set your real domain:

```bash
export DOMAIN_NAME="example.com"
export RECORD_NAME="hello.${DOMAIN_NAME}"
```

Replace `example.com` with a domain you own.

Look for an existing public hosted zone:

```bash
export PUBLIC_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "$DOMAIN_NAME" \
  --query "HostedZones[?Name=='${DOMAIN_NAME}.' && Config.PrivateZone==\`false\`] | [0].Id" \
  --output text)
```

Create the zone only when one was not found:

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

# Remove /hostedzone/ from the returned ID if present.
export PUBLIC_ZONE_ID="${PUBLIC_ZONE_ID##*/}"

echo "Public hosted zone: $PUBLIC_ZONE_ID"
echo "Created by this lab: $PUBLIC_ZONE_CREATED_BY_LAB"

echo "export DOMAIN_NAME='$DOMAIN_NAME'" >> "$STATE_FILE"
echo "export RECORD_NAME='$RECORD_NAME'" >> "$STATE_FILE"
echo "export PUBLIC_ZONE_ID='$PUBLIC_ZONE_ID'" >> "$STATE_FILE"
echo "export PUBLIC_ZONE_CREATED_BY_LAB='$PUBLIC_ZONE_CREATED_BY_LAB'" >> "$STATE_FILE"
```

Display the Route 53 name servers:

```bash
aws route53 get-hosted-zone \
  --id "$PUBLIC_ZONE_ID" \
  --query "DelegationSet.NameServers" \
  --output table
```

When the lab created a new zone, compare these servers with the name servers configured at your registrar.

---

# 20. Create the Route 53 alias record

An alias record points your friendly name to the load balancer. Route 53 can use the load balancer's health when answering DNS requests. ([AWS Documentation][11])

Create the change file:

```bash
cat > route53-create-alias.json <<EOF
{
  "Comment": "Point ${RECORD_NAME} to the hello Application Load Balancer",
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

Create or update the record:

```bash
export DNS_CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --change-batch "file://route53-create-alias.json" \
  --query "ChangeInfo.Id" \
  --output text)

echo "DNS change: $DNS_CHANGE_ID"
```

Wait until Route 53 reports that the change is synchronized:

```bash
aws route53 wait resource-record-sets-changed \
  --id "$DNS_CHANGE_ID"
```

Test it:

```bash
curl -i "http://$RECORD_NAME/"
```

DNS will not work publicly until the domain's registered name-server settings point to this hosted zone.

---

# 21. Optional private hosted zone

A private hosted zone is visible only inside associated VPCs. It is useful for internal names such as:

```text
database.internal.example.com
kafka.internal.example.com
keycloak.internal.example.com
```

It is not needed for the public Hello website. Skip this section to avoid another hosted-zone charge.

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

echo "Created private hosted zone: $PRIVATE_ZONE_ID"

echo "export PRIVATE_DOMAIN='$PRIVATE_DOMAIN'" >> "$STATE_FILE"
echo "export PRIVATE_ZONE_ID='$PRIVATE_ZONE_ID'" >> "$STATE_FILE"
```

A private hosted zone answers DNS queries only from its associated VPCs. Public internet users cannot resolve its internal records. ([AWS Documentation][12])

---

# 22. Useful verification commands

## Show the VPC

```bash
aws ec2 describe-vpcs \
  --region "$REGION" \
  --vpc-ids "$VPC_ID" \
  --output table
```

## Show the subnets

```bash
aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value,ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}" \
  --output table
```

## Show security-group rules

```bash
aws ec2 describe-security-groups \
  --region "$REGION" \
  --group-ids "$ALB_SG_ID" "$WEB_SG_ID" \
  --output json
```

## Show EC2 information

```bash
aws ec2 describe-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].{Name:Tags[?Key=='Name']|[0].Value,State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,Subnet:SubnetId}" \
  --output table
```

## Show load-balancer information

```bash
aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,DNS:DNSName,Scheme:Scheme,VPC:VpcId}" \
  --output table
```

## Show target health

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --output table
```

## Show Route 53 records

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --output table
```

---

# 23. Destroy everything

AWS resources must be deleted in the correct order. For example, a security group cannot be deleted while an EC2 instance or load balancer network interface is still using it. AWS also requires dependent VPC resources to be removed before the VPC can be deleted. ([AWS Documentation][13])

Open the directory containing your state file:

```bash
source "./hello-vpc-lab.env"
```

## Step 23.1: Delete the public DNS alias

Run this only when the Route 53 alias was created.

```bash
if [[ -n "${PUBLIC_ZONE_ID:-}" && -n "${RECORD_NAME:-}" ]]; then

  cat > route53-delete-alias.json <<EOF
{
  "Comment": "Delete the hello load balancer alias",
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

  echo "Deleted Route 53 alias record."
fi
```

Route 53 requires all the same record values when deleting a record. ([AWS Documentation][11])

## Step 23.2: Delete the private hosted zone

```bash
if [[ -n "${PRIVATE_ZONE_ID:-}" ]]; then
  aws route53 delete-hosted-zone \
    --id "$PRIVATE_ZONE_ID"

  echo "Deleted private hosted zone."
fi
```

## Step 23.3: Delete a public hosted zone created by this lab

Do not delete an existing production hosted zone.

```bash
if [[ "${PUBLIC_ZONE_CREATED_BY_LAB:-false}" == "true" ]]; then
  aws route53 delete-hosted-zone \
    --id "$PUBLIC_ZONE_ID"

  echo "Deleted public hosted zone."
else
  echo "The public hosted zone existed before the lab, so it was kept."
fi
```

Deleting a hosted zone cannot be undone. Recreating one can give it different name servers. ([AWS Documentation][14])

## Step 23.4: Delete the listener

```bash
if [[ -n "${LISTENER_ARN:-}" ]]; then
  aws elbv2 delete-listener \
    --region "$REGION" \
    --listener-arn "$LISTENER_ARN"

  echo "Deleted load-balancer listener."
fi
```

## Step 23.5: Delete the load balancer

```bash
aws elbv2 delete-load-balancer \
  --region "$REGION" \
  --load-balancer-arn "$ALB_ARN"
```

Wait until its network interfaces are removed:

```bash
aws elbv2 wait load-balancers-deleted \
  --region "$REGION" \
  --load-balancer-arns "$ALB_ARN"

echo "Deleted load balancer."
```

## Step 23.6: Deregister EC2 and delete the target group

```bash
aws elbv2 deregister-targets \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --targets "Id=$INSTANCE_ID,Port=80" || true

aws elbv2 delete-target-group \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN"

echo "Deleted target group."
```

## Step 23.7: Terminate the EC2 instance

```bash
aws ec2 terminate-instances \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"
```

Wait until termination completes:

```bash
aws ec2 wait instance-terminated \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID"

echo "Terminated EC2 instance."
```

The root EBS volume was tagged when the instance was created and uses the AMI's normal delete-on-termination behavior.

## Step 23.8: Delete the security groups

Delete the web security group first because it references the load balancer security group.

```bash
aws ec2 delete-security-group \
  --region "$REGION" \
  --group-id "$WEB_SG_ID"

aws ec2 delete-security-group \
  --region "$REGION" \
  --group-id "$ALB_SG_ID"

echo "Deleted security groups."
```

If AWS reports `DependencyViolation`, check for remaining network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "NetworkInterfaces[].{ID:NetworkInterfaceId,Description:Description,Status:Status,Owner:RequesterId}" \
  --output table
```

## Step 23.9: Disassociate the route tables

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

## Step 23.10: Delete the route tables

Remove the public internet route:

```bash
aws ec2 delete-route \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID" \
  --destination-cidr-block "0.0.0.0/0"
```

Delete both custom route tables:

```bash
aws ec2 delete-route-table \
  --region "$REGION" \
  --route-table-id "$PUBLIC_ROUTE_TABLE_ID"

aws ec2 delete-route-table \
  --region "$REGION" \
  --route-table-id "$PRIVATE_ROUTE_TABLE_ID"

echo "Deleted route tables."
```

## Step 23.11: Delete the subnets

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

echo "Deleted subnets."
```

## Step 23.12: Detach and delete the internet gateway

Detach it:

```bash
aws ec2 detach-internet-gateway \
  --region "$REGION" \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID"
```

Delete it:

```bash
aws ec2 delete-internet-gateway \
  --region "$REGION" \
  --internet-gateway-id "$IGW_ID"

echo "Deleted internet gateway."
```

## Step 23.13: Delete the VPC

```bash
aws ec2 delete-vpc \
  --region "$REGION" \
  --vpc-id "$VPC_ID"

echo "Deleted VPC."
```

## Step 23.14: Remove local temporary files

```bash
rm -f hello-user-data.sh
rm -f route53-create-alias.json
rm -f route53-delete-alias.json
rm -f "$STATE_FILE"

echo "Local lab files removed."
```

---

# 24. Check that everything was deleted

Search for resources with the project tag:

```bash
aws resourcegroupstaggingapi get-resources \
  --region "$REGION" \
  --tag-filters "Key=Project,Values=$LAB_NAME" \
  --query "ResourceTagMappingList[].ResourceARN" \
  --output table
```

Check for remaining EC2 instances:

```bash
aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Project,Values=$LAB_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name}" \
  --output table
```

Check for remaining load balancers:

```bash
aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, '$LAB_NAME')].{Name:LoadBalancerName,ARN:LoadBalancerArn}" \
  --output table
```

---

# 25. Common problems

## Target remains unhealthy

Check its health details:

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --output json
```

Common causes:

* The web service did not start.
* Port 80 is not allowed from the ALB security group.
* The EC2 instance is in the wrong VPC.
* The health-check path is incorrect.
* The instance is still starting.

Check the EC2 startup console:

```bash
aws ec2 get-console-output \
  --region "$REGION" \
  --instance-id "$INSTANCE_ID" \
  --latest \
  --output text
```

## Load balancer returns HTTP 503

A `503 Service Unavailable` response normally means the load balancer does not have a healthy target.

Run:

```bash
aws elbv2 describe-target-health \
  --region "$REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --output table
```

## Domain name does not resolve

Check the hosted-zone records:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id "$PUBLIC_ZONE_ID" \
  --output table
```

Check the Route 53 name servers:

```bash
aws route53 get-hosted-zone \
  --id "$PUBLIC_ZONE_ID" \
  --query "DelegationSet.NameServers" \
  --output table
```

The registrar must use those same name servers.

## VPC will not delete

Find remaining network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

Also check for remaining resources:

```bash
aws ec2 describe-nat-gateways \
  --region "$REGION" \
  --filter "Name=vpc-id,Values=$VPC_ID" \
  --output table

aws ec2 describe-vpc-endpoints \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output table
```

---

# 26. What should change for production

This tutorial is good for learning, but a production application should normally add:

1. A second EC2 server in private subnet B.
2. An Auto Scaling group.
3. An HTTPS listener on port 443.
4. An AWS Certificate Manager certificate.
5. An HTTP-to-HTTPS redirect.
6. Systems Manager access through private VPC endpoints.
7. CloudWatch logs and alarms.
8. VPC Flow Logs.
9. AWS WAF when the application is public.
10. Infrastructure as code using Terraform or CloudFormation.

For this cost-conscious lab, one private EC2 target, two public ALB subnets, no NAT Gateway, and immediate cleanup provide a simple way to learn the complete request path:

```text
Domain name
   → Route 53
      → Application Load Balancer
         → Target group
            → Private EC2 Hello server
```

[1]: https://docs.aws.amazon.com/vpc/latest/userguide/working-with-igw.html?utm_source=chatgpt.com "Add internet access to a subnet - Amazon Virtual Private Cloud"
[2]: https://docs.aws.amazon.com/cli/latest/reference/elbv2/?utm_source=chatgpt.com "elbv2 — AWS CLI 2.35.15 Command Reference"
[3]: https://aws.amazon.com/elasticloadbalancing/pricing/?utm_source=chatgpt.com "Elastic Load Balancing pricing"
[4]: https://aws.amazon.com/free/free-tier-faqs/?utm_source=chatgpt.com "AWS Free Tier FAQs"
[5]: https://docs.aws.amazon.com/cli/latest/reference/ec2/create-security-group.html?utm_source=chatgpt.com "create-security-group — AWS CLI 2.35.23 Command Reference"
[6]: https://docs.aws.amazon.com/linux/al2023/ug/python.html?utm_source=chatgpt.com "Python in AL2023 - Amazon Linux 2023"
[7]: https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-public-parameters.html?utm_source=chatgpt.com "Working with public parameters in Parameter Store"
[8]: https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-target-group.html?utm_source=chatgpt.com "create-target-group — AWS CLI 2.35.15 Command Reference"
[9]: https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-listener.html?utm_source=chatgpt.com "create-listener — AWS CLI 2.36.8 Command Reference"
[10]: https://docs.aws.amazon.com/cli/latest/reference/route53/create-hosted-zone.html?utm_source=chatgpt.com "create-hosted-zone — AWS CLI 2.35.24 Command Reference"
[11]: https://docs.aws.amazon.com/cli/latest/reference/route53/change-resource-record-sets.html?utm_source=chatgpt.com "change-resource-record-sets"
[12]: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-creating.html?utm_source=chatgpt.com "Creating a private hosted zone - Amazon Route 53"
[13]: https://docs.aws.amazon.com/cli/latest/reference/ec2/delete-vpc.html?utm_source=chatgpt.com "delete-vpc — AWS CLI 2.35.19 Command Reference"
[14]: https://docs.aws.amazon.com/cli/latest/reference/route53/delete-hosted-zone.html?utm_source=chatgpt.com "delete-hosted-zone — AWS CLI 2.35.16 Command Reference"
