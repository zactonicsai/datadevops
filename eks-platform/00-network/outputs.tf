# =============================================================================
# 00-network/outputs.tf
# =============================================================================
# HOW LAYERS TALK TO EACH OTHER
#
# We split this project into nine independent Terraform layers, each with its
# own state file. That raises an obvious question: if layer 01 needs the VPC ID
# that layer 00 created, how does it get it?
#
# The answer is OUTPUTS. An output is a value a layer publishes for others to
# read. It is saved into that layer's state file. Layer 01 then reads it with a
# `terraform_remote_state` data source, which is really just "open the other
# layer's state file and look up this key".
#
# You can also see outputs yourself at any time:
#   terraform output                  # everything, human readable
#   terraform output vpc_id           # one value
#   terraform output -json            # machine readable, great for scripts
#
# BEST PRACTICE: publish only what other layers genuinely need. Every output is
# a promise; renaming or removing one later breaks whoever depends on it.
# =============================================================================

output "vpc_id" {
  # `value` is the expression to publish. Here it reaches into the aws_vpc
  # resource named "main" and pulls out its generated `id` attribute.
  value       = aws_vpc.main.id
  description = "ID of the VPC, e.g. vpc-0a1b2c3d. Needed by the cluster layer."
}

output "vpc_cidr_block" {
  value       = aws_vpc.main.cidr_block
  description = "The VPC's IP range. Used when writing security group rules."
}

output "private_subnet_ids" {
  # The splat operator [*] collects the .id of every counted subnet into a list.
  value       = aws_subnet.private[*].id
  description = "IDs of the private subnets. Worker nodes are placed here."
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "IDs of the public subnets. Internet-facing load balancers go here."
}

output "availability_zones" {
  value       = local.azs
  description = "The Availability Zones actually used, e.g. [us-east-1a, us-east-1b]."
}

output "cluster_name" {
  # Published from the network layer because the SUBNET TAGS already reference
  # this name. Both layers must use the identical string or EKS's tag-based
  # subnet discovery breaks. Publishing it here makes this file the single
  # source of truth rather than repeating the string in two places.
  value       = local.cluster_name
  description = "The agreed-upon EKS cluster name, referenced by subnet tags."
}

output "nat_gateway_public_ips" {
  value       = aws_eip.nat[*].public_ip
  description = "Public IPs all outbound traffic appears to come from. Give these to any third party that needs to allow-list you."
}
