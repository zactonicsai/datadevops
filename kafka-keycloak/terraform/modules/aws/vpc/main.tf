data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc" "existing" {
  count = var.create ? 0 : 1
  id    = var.existing_vpc_id
}

locals {
  azs           = var.azs != null ? var.azs : slice(data.aws_availability_zones.available.names, 0, var.az_count)
  n             = length(local.azs)
  public_cidrs  = var.public_subnet_cidrs != null ? var.public_subnet_cidrs : [for i in range(local.n) : cidrsubnet(var.cidr, 4, i)]
  private_cidrs = var.private_subnet_cidrs != null ? var.private_subnet_cidrs : [for i in range(local.n) : cidrsubnet(var.cidr, 4, i + 8)]
  nat_count     = var.create && var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : local.n) : 0
}

resource "aws_vpc" "this" {
  count                = var.create ? 1 : 0
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  count  = var.create ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  count                   = var.create ? local.n : 0
  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, var.public_subnet_tags, { Name = "${var.name}-public-${local.azs[count.index]}", Tier = "public" })
}

resource "aws_subnet" "private" {
  count             = var.create ? local.n : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = merge(var.tags, var.private_subnet_tags, { Name = "${var.name}-private-${local.azs[count.index]}", Tier = "private" })
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count         = local.nat_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count  = var.create ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route_table" "private" {
  count  = var.create ? (var.single_nat_gateway || !var.enable_nat_gateway ? 1 : local.n) : 0
  vpc_id = aws_vpc.this[0].id
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
    }
  }
  tags = merge(var.tags, { Name = "${var.name}-private-${count.index}" })
}

resource "aws_route_table_association" "public" {
  count          = var.create ? local.n : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  count          = var.create ? local.n : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat_gateway || !var.enable_nat_gateway ? 0 : count.index].id
}
