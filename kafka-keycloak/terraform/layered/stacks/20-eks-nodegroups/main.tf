locals {
  tags = { Project = var.project, Environment = var.environment, Stack = "20-eks-nodegroups", ManagedBy = "terraform" }
}

data "terraform_remote_state" "network" {
  count   = var.private_subnet_ids == null || var.vpc_id == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/00-network.tfstate", region = local.state_region }
}

data "terraform_remote_state" "cluster" {
  count   = var.cluster_name == null || var.oidc_provider_arn == null ? 1 : 0
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "${var.state_key_prefix}/10-eks-cluster.tfstate", region = local.state_region }
}

locals {
  cluster_name       = coalesce(var.cluster_name, try(data.terraform_remote_state.cluster[0].outputs.cluster_name, null))
  oidc_provider_arn  = coalesce(var.oidc_provider_arn, try(data.terraform_remote_state.cluster[0].outputs.oidc_provider_arn, null))
  private_subnet_ids = coalesce(var.private_subnet_ids, try(data.terraform_remote_state.network[0].outputs.private_subnet_ids, null))
  vpc_id             = coalesce(var.vpc_id, try(data.terraform_remote_state.network[0].outputs.vpc_id, null))
}

# ---------- node IAM role ----------
module "node_role" {
  source            = "../../modules/iam-role"
  create            = var.existing_node_role_arn == null
  existing_role_arn = var.existing_node_role_arn
  name              = "${local.cluster_name}-node"
  trusted_services  = ["ec2.amazonaws.com"]
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
  tags = local.tags
}

# ---------- node launch template (reused by every node group) ----------
module "node_lt" {
  source           = "../../modules/launch-template"
  create           = var.existing_launch_template_id == null
  existing_id      = var.existing_launch_template_id
  name             = "${local.cluster_name}-node"
  for_eks          = true
  key_name         = var.node_key_name
  root_volume_size = var.node_root_volume_size
  tags             = local.tags
}

# ---------- node groups ----------
module "node_group" {
  source                  = "../../modules/eks-node-group"
  for_each                = var.node_groups
  cluster_name            = local.cluster_name
  name                    = each.key
  node_role_arn           = module.node_role.arn
  subnet_ids              = local.private_subnet_ids
  instance_types          = each.value.instance_types
  capacity_type           = each.value.capacity_type
  desired_size            = each.value.desired
  min_size                = each.value.min
  max_size                = each.value.max
  launch_template_id      = module.node_lt.id
  launch_template_version = "$Latest"
  labels                  = each.value.labels
  taints                  = each.value.taints
  tags                    = local.tags
}

# ---------- EBS CSI add-on (gp3 for stateful apps) ----------
module "ebs_csi_role" {
  count               = var.install_ebs_csi ? 1 : 0
  source              = "../../modules/iam-role"
  name                = "${local.cluster_name}-ebs-csi"
  oidc_provider_arn   = local.oidc_provider_arn
  oidc_subjects       = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
  managed_policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
  tags                = local.tags
}

module "ebs_csi" {
  count                    = var.install_ebs_csi ? 1 : 0
  source                   = "../../modules/eks-addon"
  cluster_name             = local.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_role[0].arn
  depends_on               = [module.node_group]
}

resource "kubernetes_storage_class_v1" "gp3" {
  count = var.install_ebs_csi ? 1 : 0
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }
  depends_on             = [module.ebs_csi]
}

# ---------- AWS Load Balancer Controller (local chart) ----------
module "lbc_role" {
  count               = var.install_lb_controller ? 1 : 0
  source              = "../../modules/iam-role"
  name                = "${local.cluster_name}-aws-load-balancer-controller"
  oidc_provider_arn   = local.oidc_provider_arn
  oidc_subjects       = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
  inline_policy_files = { controller = "${path.module}/../../shared/iam/aws-load-balancer-controller-policy.json" }
  tags                = local.tags
}

resource "kubernetes_service_account_v1" "lbc" {
  count = var.install_lb_controller ? 1 : 0
  metadata {
    name        = "aws-load-balancer-controller"
    namespace   = "kube-system"
    annotations = { "eks.amazonaws.com/role-arn" = module.lbc_role[0].arn }
  }
}

module "lbc" {
  count      = var.install_lb_controller ? 1 : 0
  source     = "../../modules/helm-app"
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  chart_path = "${path.module}/../../shared/charts/aws-load-balancer-controller"
  values = [yamlencode({
    clusterName                 = local.cluster_name
    region                      = var.region
    vpcId                       = local.vpc_id
    serviceAccount              = { create = false, name = "aws-load-balancer-controller" }
    enableServiceMutatorWebhook = false
  })]
  depends_on = [module.node_group, kubernetes_service_account_v1.lbc]
}

# ---------- application namespaces ----------
module "namespace" {
  source         = "../../modules/k8s-namespace"
  for_each       = var.namespaces
  name           = each.key
  labels         = each.value.labels
  resource_quota = each.value.resource_quota
  depends_on     = [module.node_group]
}
