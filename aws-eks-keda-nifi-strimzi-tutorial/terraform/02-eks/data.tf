data "terraform_remote_state" "network" {
  backend = "local"

  config = {
    path = "../01-network/terraform.tfstate"
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}
