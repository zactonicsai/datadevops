data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    path = "../01-network/terraform.tfstate"
  }
}

data "terraform_remote_state" "eks" {
  backend = "local"

  config = {
    path = "../02-eks/terraform.tfstate"
  }
}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
