# Outputs are how the NEXT layer finds what this layer built.
output "vpc_id"             { value = aws_vpc.this.id }
output "vpc_cidr"           { value = aws_vpc.this.cidr_block }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
# Nodes go in private subnets if there is a NAT to give them internet,
# otherwise in public subnets (where they get their own public IP).
output "node_subnet_ids" {
  value = var.use_nat ? aws_subnet.private[*].id : aws_subnet.public[*].id
}
