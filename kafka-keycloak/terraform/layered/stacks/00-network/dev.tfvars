region      = "us-east-1"
project     = "kafka-keycloak"
environment = "dev"

create_vpc         = true
vpc_cidr           = "10.42.0.0/16"
az_count           = 3
single_nat_gateway = true
eks_cluster_names  = ["kafka-keycloak-dev"]

# To reuse an existing VPC instead:
# create_vpc                  = false
# existing_vpc_id             = "vpc-0123456789abcdef0"
# existing_public_subnet_ids  = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
# existing_private_subnet_ids = ["subnet-ddd", "subnet-eee", "subnet-fff"]
