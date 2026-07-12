module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "eks-kafka-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.16.0/20", "10.0.32.0/20", "10.0.48.0/20"]

  # Small dedicated subnets for Strimzi Kafka brokers (/27 allows 32 IPs per AZ)
  intra_subnets = ["10.0.4.0/27", "10.0.4.32/27", "10.0.4.64/27"]

  enable_nat_gateway = true
  single_nat_gateway = false # Set to true for non-prod environments to save costs
  enable_vpn_gateway = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = "eks-kafka-cluster"
  }

  intra_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "component"                       = "kafka-storage"
  }
}