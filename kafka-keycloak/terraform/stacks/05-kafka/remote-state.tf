data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.state_prefix}/02-eks-cluster.tfstate"
    region = var.state_region
  }
}
data "terraform_remote_state" "nodegroups" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.state_prefix}/03-eks-nodegroups.tfstate"
    region = var.state_region
  }
}
