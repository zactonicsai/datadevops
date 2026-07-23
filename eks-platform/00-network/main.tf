# =============================================================================
# 00-network/main.tf   --   THE NETWORK LAYER
# =============================================================================
# BACKGROUND: WHAT IS A VPC AND WHY DO WE NEED ONE FIRST?
#
# A VPC (Virtual Private Cloud) is your own private slice of Amazon's network.
# Think of AWS as a gigantic apartment building. A VPC is your apartment: it has
# its own rooms, its own front door, and your neighbours cannot walk in.
#
# Inside the apartment we build rooms called SUBNETS:
#
#   PUBLIC subnets  - have a route to the Internet Gateway, so things here can
#                     be reached FROM the internet. Load balancers live here.
#                     Think: the front porch.
#
#   PRIVATE subnets - have NO route in from the internet. Things here can start
#                     outgoing connections (through a NAT gateway) but nobody
#                     outside can start a connection to them.
#                     Think: the bedrooms. All our worker nodes live here.
#
# WHY PUT WORKER NODES IN PRIVATE SUBNETS?
# This is defense in depth. If an attacker finds a bug in one of our web
# servers, they still cannot open an SSH connection to the node from their
# laptop, because there is no network path. Public subnets exist only to hold
# the load balancer that forwards traffic inward.
#
# ORDER MATTERS: nothing else can be built until the network exists. That is
# why this is layer 00.
# =============================================================================

# -----------------------------------------------------------------------------
# DATA SOURCE: look up which Availability Zones this region actually has.
# -----------------------------------------------------------------------------
# A "data" block READS existing information instead of creating something. This
# is a best practice over hard-coding ["us-east-1a", "us-east-1b"], because:
#   - different regions have different numbers of AZs
#   - AWS sometimes restricts specific AZs for specific accounts
data "aws_availability_zones" "available" {
  # Only return zones that are fully usable right now.
  state = "available"

  filter {
    name = "opt-in-status"
    # Some zones (AWS Local Zones, Wavelength) require you to opt in first, and
    # they do not support EKS. "opt-in-not-required" gives us only the standard
    # zones we actually want.
    values = ["opt-in-not-required"]
  }
}

# -----------------------------------------------------------------------------
# LOCALS: values we compute once and reuse.
# -----------------------------------------------------------------------------
# A "local" is like a variable in a normal programming language: a named
# expression. Unlike an input variable, it cannot be overridden from tfvars.
# Use locals for anything DERIVED from inputs.
locals {
  # The full name prefix, e.g. "eksdemo". Used everywhere for consistency.
  name_prefix = var.project_name

  # The EKS cluster's name. Both this layer and the cluster layer must agree on
  # it, because subnet tags below reference it BEFORE the cluster exists.
  cluster_name = "${var.project_name}-cluster"

  # Take only as many AZs as the user asked for.
  # slice(list, from, to) grabs elements from index `from` up to (not
  # including) index `to`. So slice(["a","b","c","d","e","f"], 0, 3) is
  # ["a","b","c"].
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  # ---------------------------------------------------------------------------
  # CARVING THE VPC INTO SUBNET RANGES  (the trickiest math in this project)
  # ---------------------------------------------------------------------------
  # cidrsubnet(prefix, newbits, netnum) slices a big range into smaller ones.
  #   prefix  = the range to cut up, e.g. "10.42.0.0/16"
  #   newbits = how many bits to ADD to the prefix length.
  #             /16 + 4 newbits = /20 subnets. Each /20 holds 4,094 usable IPs.
  #   netnum  = which slice you want, counting from 0.
  #
  # Worked example with vpc_cidr = 10.42.0.0/16 and 3 AZs:
  #
  #   PRIVATE (netnum 0,1,2):
  #     cidrsubnet("10.42.0.0/16", 4, 0) = 10.42.0.0/20    <- AZ a
  #     cidrsubnet("10.42.0.0/16", 4, 1) = 10.42.16.0/20   <- AZ b
  #     cidrsubnet("10.42.0.0/16", 4, 2) = 10.42.32.0/20   <- AZ c
  #
  #   PUBLIC (netnum 8,9,10 -- we deliberately skip ahead to leave a gap):
  #     cidrsubnet("10.42.0.0/16", 4, 8)  = 10.42.128.0/20 <- AZ a
  #     cidrsubnet("10.42.0.0/16", 4, 9)  = 10.42.144.0/20 <- AZ b
  #     cidrsubnet("10.42.0.0/16", 4, 10) = 10.42.160.0/20 <- AZ c
  #
  # WHY THE GAP BETWEEN 2 AND 8? Slices 3-7 are left unused on purpose. If you
  # later want a 4th AZ, or a separate database tier, the space is already
  # reserved and you will not have to renumber (which means rebuilding) the
  # existing subnets. Planning for growth is a best practice.
  #
  # WHY ARE PRIVATE SUBNETS SO BIG? Because in EKS every POD gets a real VPC IP
  # address from the node's subnet (the AWS VPC CNI plugin). A cluster with
  # hundreds of pods burns through IPs fast. Undersized private subnets are the
  # single most common cause of "my pod is stuck in ContainerCreating" on EKS.
  private_subnet_cidrs = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnet_cidrs  = [for i in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

# -----------------------------------------------------------------------------
# THE VPC ITSELF
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # enable_dns_hostnames + enable_dns_support are BOTH REQUIRED by EKS.
  # They make AWS run a DNS resolver inside the VPC and give instances internal
  # DNS names. Kubernetes service discovery is built on DNS, so without these
  # your cluster will come up but nothing will be able to find anything.
  # This is a classic "cluster is broken and I don't know why" trap.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# -----------------------------------------------------------------------------
# INTERNET GATEWAY: the VPC's front door to the public internet.
# -----------------------------------------------------------------------------
# One per VPC. Attaching it does not by itself expose anything; traffic only
# flows if a route table points at it (see the public route table below).
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# -----------------------------------------------------------------------------
# PUBLIC SUBNETS: one per Availability Zone.
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  # count creates N copies of this resource. Each copy gets an index available
  # as count.index (0, 1, 2 ...). The copies are addressed as
  # aws_subnet.public[0], aws_subnet.public[1], and so on.
  #
  # (Terraform also has for_each, which is usually preferred because it keys
  # resources by name rather than position. We use count here because our
  # inputs are naturally ordered lists and the count is stable.)
  count = var.availability_zone_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Anything launched here automatically gets a public IP. Needed so the load
  # balancer AWS creates for us is reachable.
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${local.azs[count.index]}"

    # ---- MAGIC KUBERNETES TAGS: do not remove these ----
    # EKS does not read your Terraform. It discovers subnets by scanning for
    # tags. Get these wrong and load balancers silently fail to provision,
    # with an error buried in the AWS controller's logs.
    #
    # "kubernetes.io/role/elb" = "1" tells the load balancer controller:
    #     "put INTERNET-FACING load balancers in this subnet".
    "kubernetes.io/role/elb" = "1"

    # This tag marks the subnet as belonging to our cluster. "shared" means
    # other clusters may also use it; the alternative value "owned" means this
    # cluster exclusively owns it and may delete it.
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# -----------------------------------------------------------------------------
# PRIVATE SUBNETS: one per Availability Zone. Worker nodes live here.
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = var.availability_zone_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Deliberately NOT set to true. That is the whole point of a private subnet.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${local.azs[count.index]}"

    # "internal-elb" = "1" is the private-subnet counterpart of the tag above:
    #     "put INTERNAL (VPC-only) load balancers in this subnet".
    "kubernetes.io/role/internal-elb" = "1"

    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# -----------------------------------------------------------------------------
# ELASTIC IPs for the NAT gateway(s).
# -----------------------------------------------------------------------------
# An Elastic IP is a fixed public IPv4 address you own. A NAT gateway needs one
# so that outbound traffic from private subnets has a consistent source address
# (useful if a third party needs to allow-list you).
resource "aws_eip" "nat" {
  # THE CONDITIONAL COUNT PATTERN:
  #   condition ? value_if_true : value_if_false
  # If single_nat_gateway is true we make 1 EIP; otherwise one per AZ.
  # Setting count = 0 is how you conditionally create NOTHING in Terraform.
  count = var.single_nat_gateway ? 1 : var.availability_zone_count

  # Tells AWS this address is for use inside a VPC.
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index}"
  }

  # depends_on forces ordering. Terraform normally figures out order by itself
  # from references, but there is no reference from an EIP to the gateway, and
  # AWS will reject the allocation if the IGW is not attached yet. This is one
  # of the few legitimate uses of an explicit dependency.
  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# NAT GATEWAY(S): let private nodes reach OUT to the internet, one way only.
# -----------------------------------------------------------------------------
# Our worker nodes must download container images from public registries such
# as quay.io and docker.io. NAT (Network Address Translation) makes that
# possible while keeping the nodes unreachable from outside.
#
# COST WARNING, because this surprises people: a NAT gateway costs roughly
# $0.045 per hour (about $32/month) PLUS about $0.045 per GB of data processed.
# It is usually the largest line item in a small demo cluster. It is also the
# single easiest thing to forget to delete.
resource "aws_nat_gateway" "main" {
  count = var.single_nat_gateway ? 1 : var.availability_zone_count

  allocation_id = aws_eip.nat[count.index].id

  # A NAT gateway must sit in a PUBLIC subnet (it needs the internet gateway),
  # even though it serves private subnets. This trips people up constantly.
  subnet_id = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# PUBLIC ROUTE TABLE
# -----------------------------------------------------------------------------
# A route table is a list of signposts: "traffic for THIS destination goes
# THAT way". One public table is enough because every public subnet wants the
# identical rule.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    # 0.0.0.0/0 means "any destination not matched by a more specific route",
    # i.e. the whole internet. This is the default route.
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

# Attach the public route table to each public subnet. A subnet with no
# explicit association silently falls back to the VPC's main route table, which
# has no internet route -- another quiet failure mode.
resource "aws_route_table_association" "public" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# PRIVATE ROUTE TABLES: one per AZ.
# -----------------------------------------------------------------------------
# Why one per AZ instead of one shared table? Because when single_nat_gateway
# is false, each AZ must point at ITS OWN NAT gateway. Sending AZ-b traffic to
# a NAT gateway in AZ-a still works, but costs cross-AZ data transfer fees and
# breaks if AZ-a fails -- exactly the outage you paid extra to avoid.
resource "aws_route_table" "private" {
  count = var.availability_zone_count

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"

    # Pick the right NAT gateway: index 0 when sharing one, else index per AZ.
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count = var.availability_zone_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# VPC ENDPOINT FOR S3  (a free performance and cost optimisation)
# -----------------------------------------------------------------------------
# Container images stored in Amazon ECR are actually kept in S3. Without an
# endpoint, every image layer your nodes pull travels out through the NAT
# gateway and you pay per-GB processing on all of it.
#
# A GATEWAY endpoint adds a route so S3 traffic goes over Amazon's internal
# network instead. Gateway endpoints for S3 and DynamoDB are FREE. There is no
# good reason not to add one.
#
# (The other kind, an INTERFACE endpoint, puts a network card in your subnet
# and costs about $7/month each. Those can eliminate the NAT gateway entirely
# for a private cluster, but you need roughly six of them for EKS.)
resource "aws_vpc_endpoint" "s3" {
  vpc_id = aws_vpc.main.id

  # The service name format is com.amazonaws.<region>.<service>.
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # Wire the endpoint into every private route table so nodes actually use it.
  # [*] is the "splat" operator: it pulls one attribute out of every element of
  # a counted resource, turning it into a plain list of IDs.
  route_table_ids = aws_route_table.private[*].id

  tags = {
    Name = "${local.name_prefix}-s3-endpoint"
  }
}
