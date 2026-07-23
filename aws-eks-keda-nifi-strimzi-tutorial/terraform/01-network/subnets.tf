resource "aws_subnet" "public" {
  count = length(local.availability_zones)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.availability_zones[count.index]
  cidr_block               = local.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                      = "${local.cluster_name}-public-${count.index + 1}"
    "kubernetes.io/role/elb"                  = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count = length(local.availability_zones)

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.availability_zones[count.index]
  cidr_block               = local.private_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                                           = "${local.cluster_name}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb"              = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}
