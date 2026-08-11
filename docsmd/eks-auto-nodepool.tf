###############################################################################
# Add a custom node pool to an existing EKS Auto Mode cluster.
#
# In Auto Mode a "node group" is expressed as two Kubernetes objects:
#   NodeClass (eks.amazonaws.com/v1) -> HOW nodes are built (IAM role, subnets,
#                                       security groups, disks, networking)
#   NodePool  (karpenter.sh/v1)      -> WHAT nodes are allowed (instance types,
#                                       capacity type, limits, taints, labels)
#
# This file also creates the node IAM role and the EKS access entry that custom
# NodeClasses require (the built-in general-purpose/system pools use a role EKS
# manages for you; custom ones do not).
###############################################################################

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.36"
    }
  }
}

###############################################################################
# Variables
###############################################################################

variable "region" {
  description = "AWS region of the cluster."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the existing EKS Auto Mode cluster."
  type        = string
}

variable "node_pool_name" {
  description = "Name used for the NodeClass, the NodePool, and the node IAM role."
  type        = string
  default     = "app-workers"
}

variable "subnet_selector_tags" {
  description = "Tags used to discover the subnets nodes launch into. Leave empty to fall back to karpenter.sh/discovery = <cluster_name>."
  type        = map(string)
  default     = {}
}

variable "instance_categories" {
  description = "Instance categories allowed in this pool (c, m, r, g, ...)."
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "architecture" {
  description = "CPU architecture: amd64 or arm64."
  type        = string
  default     = "amd64"
}

variable "capacity_types" {
  description = "on-demand and/or spot."
  type        = list(string)
  default     = ["on-demand"]
}

variable "cpu_limit" {
  description = "Maximum total vCPU this pool may provision."
  type        = string
  default     = "1000"
}

variable "disk_size" {
  description = "Root/ephemeral volume size for each node."
  type        = string
  default     = "80Gi"
}

variable "taints" {
  description = "Optional taints so only tolerating pods land on this pool."
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string # NoSchedule | PreferNoSchedule | NoExecute
  }))
  default = []
}

variable "tags" {
  description = "Tags applied to EC2 instances and volumes created by this pool."
  type        = map(string)
  default     = {}
}

locals {
  subnet_tags = length(var.subnet_selector_tags) > 0 ? var.subnet_selector_tags : {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

###############################################################################
# Providers
###############################################################################

provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

###############################################################################
# Node IAM role + EKS access entry
###############################################################################

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-${var.node_pool_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# Auto Mode nodes authenticate to the cluster through an EC2-type access entry.
resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2"

  depends_on = [aws_iam_role_policy_attachment.node]
}

###############################################################################
# NodeClass - how the instances are built
###############################################################################

resource "kubernetes_manifest" "node_class" {
  manifest = {
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "NodeClass"

    metadata = {
      name = var.node_pool_name
    }

    spec = {
      # Role NAME, not ARN.
      role = aws_iam_role.node.name

      subnetSelectorTerms = [
        {
          tags = local.subnet_tags
        }
      ]

      securityGroupSelectorTerms = [
        {
          id = data.aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
        }
      ]

      ephemeralStorage = {
        size       = var.disk_size
        iops       = 3000
        throughput = 125
      }

      snatPolicy             = "Random"
      networkPolicy          = "DefaultAllow"
      networkPolicyEventLogs = "Disabled"

      tags = merge(
        {
          "Name"       = "${var.cluster_name}-${var.node_pool_name}"
          "NodePool"   = var.node_pool_name
          "ManagedBy"  = "terraform"
        },
        var.tags,
      )
    }
  }

  depends_on = [aws_eks_access_entry.node]
}

###############################################################################
# NodePool - what the scheduler is allowed to provision
###############################################################################

resource "kubernetes_manifest" "node_pool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"

    metadata = {
      name = var.node_pool_name
    }

    spec = {
      template = {
        metadata = {
          labels = {
            "nodepool" = var.node_pool_name
          }
        }

        spec = {
          nodeClassRef = {
            group = "eks.amazonaws.com"
            kind  = "NodeClass"
            name  = var.node_pool_name
          }

          requirements = [
            {
              key      = "eks.amazonaws.com/instance-category"
              operator = "In"
              values   = var.instance_categories
            },
            {
              key      = "eks.amazonaws.com/instance-generation"
              operator = "Gt"
              values   = ["4"]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = [var.architecture]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = var.capacity_types
            },
          ]

          taints = [
            for t in var.taints : {
              key    = t.key
              effect = t.effect
              value  = t.value
            }
          ]

          # Hard ceiling on how long a node may take to drain.
          terminationGracePeriod = "24h0m0s"

          # Recycle nodes on a schedule to keep AMIs patched.
          expireAfter = "336h"
        }
      }

      limits = {
        cpu = var.cpu_limit
      }

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"

        budgets = [
          {
            nodes = "10%"
          }
        ]
      }

      # Higher weight wins over the built-in general-purpose pool (weight 1).
      weight = 10
    }
  }

  depends_on = [kubernetes_manifest.node_class]
}

###############################################################################
# Outputs
###############################################################################

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_pool_name" {
  value = var.node_pool_name
}

output "scheduling_hint" {
  description = "Add this nodeSelector to a pod spec to target the pool."
  value       = "nodeSelector: { nodepool: ${var.node_pool_name} }"
}
