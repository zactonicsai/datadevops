data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.state_prefix}/01-network.tfstate"
    region = var.state_region
  }
}
data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.state_prefix}/02-eks-cluster.tfstate"
    region = var.state_region
  }
}
