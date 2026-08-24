###############################################################################
# Provider configuration
# default_tags applies the standard tag set to every taggable resource, so
# individual resources only add what is specific to them.
###############################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

provider "random" {}
