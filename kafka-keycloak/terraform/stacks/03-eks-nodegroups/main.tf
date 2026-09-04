locals {
  net = data.terraform_remote_state.network.outputs
}

# ---- node IAM role (core module) ----
module "node_role" {
  source             = "../../modules/aws/iam-role"
  create             = var.node_role.create
  existing_role_name = var.node_role.existing_role_name
  name               = "${local.cluster.cluster_name}-eks-node"
  trusted_services   = ["ec2.amazonaws.com"]
  managed_policy_arns = concat([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ], var.node_role.extra_policy_arns)
  tags = local.tags
}

# ---- optional launch template (core module) ----
module "node_launch_template" {
  count              = var.launch_template.enabled ? 1 : 0
  source             = "../../modules/aws/launch-template"
  create             = var.launch_template.existing_id == null
  existing_id        = var.launch_template.existing_id
  name               = "${local.cluster.cluster_name}-nodes"
  ami_id             = null
  ami_ssm_parameter  = null # EKS picks the optimized AMI when image_id is empty
  key_name           = var.launch_template.key_name
  security_group_ids = concat([local.cluster.cluster_security_group_id], var.launch_template.extra_sg_ids)
  root_volume        = var.launch_template.root_volume
  require_imdsv2     = true
  tags               = local.tags
}

# ---- node groups (core module, one per map entry) ----
module "node_groups" {
  for_each       = var.node_groups
  source         = "../../modules/aws/eks-node-group"
  cluster_name   = local.cluster.cluster_name
  name           = each.key
  node_role_arn  = module.node_role.role_arn
  subnet_ids     = each.value.subnet_ids != null ? each.value.subnet_ids : local.net.private_subnet_ids
  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  ami_type       = each.value.ami_type
  disk_size      = each.value.disk_size
  scaling        = each.value.scaling
  labels         = each.value.labels
  taints         = each.value.taints
  launch_template = var.launch_template.enabled ? {
    id      = module.node_launch_template[0].id
    version = tostring(module.node_launch_template[0].latest_version)
  } : null
  tags = local.tags
}

# ---- namespaces ----
resource "kubernetes_namespace_v1" "this" {
  for_each = var.namespaces
  metadata {
    name   = each.key
    labels = each.value
  }
  depends_on = [module.node_groups]
}

# ---- default gp3 StorageClass ----
resource "kubernetes_storage_class_v1" "gp3" {
  count = var.default_storage_class ? 1 : 0
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }
  depends_on             = [module.node_groups]
}

# ---- AWS Load Balancer Controller: IRSA role (core module) + local chart ----
module "lbc_role" {
  count  = var.install_lb_controller ? 1 : 0
  source = "../../modules/aws/iam-role"
  name   = "${local.cluster.cluster_name}-aws-load-balancer-controller"
  oidc = {
    provider_arn     = local.cluster.oidc_provider_arn
    issuer_host      = local.cluster.oidc_issuer_host
    service_accounts = ["kube-system:aws-load-balancer-controller"]
  }
  policy_files = { lbc = "${path.module}/../../vendor/iam/aws-load-balancer-controller-policy.json" }
  tags         = local.tags
}

resource "kubernetes_service_account_v1" "lbc" {
  count = var.install_lb_controller ? 1 : 0
  metadata {
    name        = "aws-load-balancer-controller"
    namespace   = "kube-system"
    annotations = { "eks.amazonaws.com/role-arn" = module.lbc_role[0].role_arn }
  }
  depends_on = [module.node_groups]
}

resource "helm_release" "lbc" {
  count     = var.install_lb_controller ? 1 : 0
  name      = "aws-load-balancer-controller"
  namespace = "kube-system"
  chart     = "${path.module}/../../vendor/charts/aws-load-balancer-controller"
  wait      = true
  timeout   = 600
  values = [yamlencode({
    clusterName                 = local.cluster.cluster_name
    region                      = var.region
    vpcId                       = local.net.vpc_id
    serviceAccount              = { create = false, name = kubernetes_service_account_v1.lbc[0].metadata[0].name }
    enableServiceMutatorWebhook = false
  })]
}
