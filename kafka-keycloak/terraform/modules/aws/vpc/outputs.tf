output "vpc_id" { value = var.create ? aws_vpc.this[0].id : var.existing_vpc_id }
output "vpc_cidr" { value = var.create ? aws_vpc.this[0].cidr_block : data.aws_vpc.existing[0].cidr_block }
output "public_subnet_ids" { value = var.create ? aws_subnet.public[*].id : var.existing_public_subnet_ids }
output "private_subnet_ids" { value = var.create ? aws_subnet.private[*].id : var.existing_private_subnet_ids }
output "azs" { value = local.azs }
