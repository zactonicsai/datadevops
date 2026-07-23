# One Elastic IP is attached to the tutorial NAT Gateway.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.cluster_name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.this]
}

# One NAT Gateway is cheaper for a tutorial. Production commonly uses one per AZ.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.cluster_name}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}
