output "vpc_id" {
  description = "ID of the tutorial VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs used by the NAT Gateway and test runner."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by EKS and its worker nodes."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability Zones used by the VPC."
  value       = local.availability_zones
}
