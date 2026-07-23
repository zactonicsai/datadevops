# =============================================================================
# 01-cluster/main.tf   --   THE EKS CLUSTER AND ITS WORKER NODES
# =============================================================================
# BACKGROUND: WHAT IS KUBERNETES, AND WHAT IS EKS?
#
# Kubernetes is a system that runs containers for you. You tell it "I want two
# copies of this web server running at all times" and it makes that true. If a
# copy crashes, it starts another. If a whole machine dies, it moves the work
# elsewhere. You describe the DESTINATION, not the route.
#
# Every Kubernetes cluster has two halves:
#
#   THE CONTROL PLANE  - the brain. It holds the desired state, makes all the
#                        decisions, and serves the API that kubectl talks to.
#   THE WORKER NODES   - the muscle. Ordinary virtual machines that actually
#                        run your containers.
#
# EKS (Elastic Kubernetes Service) means AWS runs the control plane for you.
# You never see those machines; AWS patches them, backs them up, and keeps
# three copies across three data centers. You pay a flat ~$0.10/hour (about
# $73/month) for that. You still own and pay for the worker nodes.
#
# TRADE-OFFS OF EKS vs. THE ALTERNATIVES:
#   + vs. self-managed Kubernetes on EC2: EKS removes the hardest and most
#     dangerous operational work (etcd backups, control plane upgrades,
#     certificate rotation). Almost always worth the $73.
#   - vs. ECS (Amazon's simpler container service): ECS is easier and has no
#     control plane fee, but it is AWS-only and has a much smaller ecosystem.
#     We need Kubernetes here specifically because KEDA, Strimzi and the NiFi
#     operators are Kubernetes-native.
#   - vs. EKS Auto Mode: AWS now offers a mode where it manages worker nodes
#     too. Simpler, but it hides the node group mechanics we want to teach,
#     and it costs a management premium on top of EC2. We use a classic
#     managed node group so you can see every moving part.
# =============================================================================

locals {
  # Read values published by layer 00. If this errors with "state file not
  # found", you have not applied 00-network yet.
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  vpc_cidr           = data.terraform_remote_state.network.outputs.vpc_cidr_block
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  cluster_name       = data.terraform_remote_state.network.outputs.cluster_name
}

# -----------------------------------------------------------------------------
# THE EKS CLUSTER, VIA THE COMMUNITY MODULE
# -----------------------------------------------------------------------------
# WHAT IS A MODULE? A reusable package of Terraform code, like a library or a
# function. Instead of writing the ~80 resources an EKS cluster needs (IAM
# roles, policies, security groups, launch templates, OIDC providers), we call
# a module that already got all of that right.
#
# WHY USE THIS PARTICULAR MODULE? terraform-aws-modules/eks is the de facto
# community standard with thousands of production users. Bugs get found by
# other people before they find you. Using well-maintained modules is a best
# practice; writing raw EKS resources by hand is an easy way to ship a subtly
# broken cluster.
#
# THE COUNTERARGUMENT: modules are abstractions, and abstractions hide things.
# When something breaks you now have to debug both your code AND the module's.
# Read the module's source when confused; it is just Terraform.
module "eks" {
  source = "terraform-aws-modules/eks/aws"

  # Pinned so a new major release cannot silently restructure your cluster.
  # v21 renamed several inputs from v20 (cluster_name -> name,
  # cluster_version -> kubernetes_version), which is exactly the kind of
  # breakage that pinning protects you from.
  version = "~> 21.0"

  # ---- Basic identity ----
  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # ---- Where the cluster lives ----
  vpc_id = local.vpc_id

  # subnet_ids is where WORKER NODES are placed. Private subnets only.
  subnet_ids = local.private_subnet_ids

  # ---- API server endpoint access ----
  # The Kubernetes API server is what kubectl talks to. Two switches control
  # who can reach it:
  #
  #   endpoint_private_access = true  -> reachable from inside the VPC.
  #       Required, because worker nodes and the toolbox pod must talk to it.
  #
  #   endpoint_public_access  = true  -> also reachable from the internet.
  #       Convenient: you can run kubectl from your laptop with no VPN.
  #       We enable it so this tutorial works from anywhere.
  #
  # SECURITY NOTE: "public" does NOT mean unauthenticated. Every request is
  # still authenticated (IAM) and authorized (Kubernetes RBAC). But reducing
  # exposure is still worthwhile, which is what the CIDR list below does.
  endpoint_private_access = true
  endpoint_public_access  = true

  # Restrict WHICH source IPs may reach the public endpoint. Narrowing this to
  # your office or home IP is one of the highest-value, lowest-effort security
  # improvements available. See allowed_admin_cidrs in the tfvars file.
  endpoint_public_access_cidrs = var.allowed_admin_cidrs

  # ---- Control plane logging ----
  # Ships control plane logs to CloudWatch Logs. Each type answers a different
  # question:
  #   api               - what requests hit the API server
  #   audit             - WHO did WHAT and WHEN. Essential for security
  #                       forensics; usually the first thing an auditor asks for
  #   authenticator     - IAM-to-Kubernetes identity mapping (debugging "you
  #                       are not authorized" errors)
  #   controllerManager - the reconciliation loops
  #   scheduler         - why a pod was or was not placed on a node
  #
  # COST WARNING: audit logs on a busy cluster can generate many GB per day at
  # roughly $0.50/GB ingested. For a demo this is pennies. In production, keep
  # audit on but set a retention period.
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # ---- Access management ----
  # Modern EKS uses "access entries" (an EKS API) rather than the old
  # aws-auth ConfigMap. This flag creates an access entry granting cluster
  # administrator rights to whichever IAM identity runs `terraform apply`.
  #
  # WITHOUT THIS you will build a perfectly healthy cluster and then be
  # completely locked out of it, which is a memorably frustrating experience.
  enable_cluster_creator_admin_permissions = true

  # ---- Secrets encryption at rest ----
  # Kubernetes Secrets are stored in etcd. By default EKS encrypts etcd with an
  # AWS-managed key. Setting create_kms_key makes a dedicated customer-managed
  # KMS key so YOU control the key policy and can audit its use.
  # Cost: about $1/month for the key. Worth it.
  create_kms_key = true
  encryption_config = {
    resources = ["secrets"]
  }

  # ---- Cluster add-ons ----
  # Add-ons are AWS-managed installations of components every cluster needs.
  # Letting AWS manage them means you get security patches without doing
  # anything, which is strictly better than installing them yourself.
  addons = {
    # CoreDNS: the cluster's internal DNS server. This is what makes
    # "http://hello-web" resolve to a service inside the cluster. Without it,
    # essentially nothing works.
    coredns = {}

    # kube-proxy: programs each node's network rules so traffic sent to a
    # Service IP actually reaches one of the backing pods.
    kube-proxy = {}

    # vpc-cni: the network plugin that gives every pod a real VPC IP address.
    #
    # before_compute = true is IMPORTANT. It installs the CNI BEFORE any
    # worker node joins. Nodes that boot without a working CNI come up
    # NotReady and you get a confusing chicken-and-egg failure.
    vpc-cni = {
      before_compute = true
    }

    # eks-pod-identity-agent: the modern way to give a pod an IAM role.
    # Also needed early, hence before_compute.
    eks-pod-identity-agent = {
      before_compute = true
    }

    # aws-ebs-csi-driver: lets Kubernetes create real EBS volumes when a pod
    # asks for persistent storage. Kafka and NiFi both demand persistent
    # volumes, so WITHOUT THIS their pods hang forever in Pending with the
    # message "pod has unbound immediate PersistentVolumeClaims".
    #
    # It needs AWS permissions to create volumes, granted here via a Pod
    # Identity association (see the IAM role further down).
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  # ---- Managed node groups: the actual worker machines ----
  # "Managed" means AWS handles the autoscaling group, the AMI updates, and
  # graceful draining during upgrades. The alternative, self-managed nodes,
  # gives more control but hands you all that work.
  eks_managed_node_groups = {

    # The map key "general" becomes part of the node group's name.
    general = {

      # AL2023 = Amazon Linux 2023, the current default and recommended AMI
      # family for EKS. (Amazon Linux 2 is end of life; do not start new
      # clusters on it.)
      ami_type = "AL2023_x86_64_STANDARD"

      # A LIST of acceptable instance types. If AWS cannot supply m6i.large in
      # a zone right now, it falls back to the next entry instead of failing.
      # Always pass a list here; single-type node groups fail more often.
      instance_types = var.node_instance_types

      # Autoscaling bounds. Note these are the bounds of the NODE group.
      # KEDA (layer 03) scales PODS. The two are different levels:
      #   KEDA / HPA          -> more pods
      #   Cluster autoscaler  -> more nodes to fit those pods
      # We are not installing a cluster autoscaler in this tutorial, so the
      # node count stays at desired_size. Pod-level scaling still works fine
      # because we sized the nodes with headroom.
      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      # ON_DEMAND = normal pricing, the machine is yours until you stop it.
      # The alternative, "SPOT", is 60-90% cheaper but AWS can reclaim the
      # machine with 2 minutes' notice. Spot is excellent for stateless web
      # servers and terrible for Kafka brokers holding data. Since one node
      # group here hosts both, we choose reliability.
      capacity_type = "ON_DEMAND"

      # Root disk size in GiB.
      disk_size = var.node_disk_size_gb

      # ---- Node labels ----
      # Labels are key/value tags on the Kubernetes Node object. Pods can use
      # nodeSelector or affinity to say "only schedule me on nodes labelled
      # like this". We add a workload label so you can experiment with
      # placement later.
      labels = {
        "workload-type" = "general"
      }

      # ---- IMDSv2 enforcement: an important security control ----
      # Every EC2 instance can query a special address (169.254.169.254) for
      # metadata, including its IAM credentials. In IMDSv1 a single GET
      # request returns those credentials. That means a server-side request
      # forgery bug in any pod could steal the NODE'S IAM role.
      #
      # IMDSv2 requires a PUT to obtain a session token first, which SSRF
      # attacks generally cannot perform.
      metadata_options = {
        http_endpoint = "enabled"

        # "required" = IMDSv2 only, IMDSv1 refused. This is the setting that
        # actually closes the hole.
        http_tokens = "required"

        # A hop limit of 1 means the metadata response cannot cross a network
        # hop. Since containers sit one hop away from the host network
        # namespace, this stops most pods from reaching metadata at all --
        # which is exactly what we want, because pods should get credentials
        # from Pod Identity, not by impersonating their node.
        http_put_response_hop_limit = 1
      }

      # Enables detailed 1-minute CloudWatch metrics rather than the default
      # 5-minute ones. Costs a little; makes debugging a scaling event far
      # easier because you can actually see the spike.
      enable_monitoring = true

      # ---- Rolling update behaviour ----
      # When the AMI changes, replace at most one node at a time. Slower, but
      # it guarantees capacity never dips by more than a single node.
      update_config = {
        max_unavailable = 1
      }
    }
  }

  # ---- Extra security group rules for the worker nodes ----
  # By default the module allows nodes to talk to the control plane and to
  # each other on the ports Kubernetes needs. We add one explicit rule.
  node_security_group_additional_rules = {
    # Allow every node to talk to every other node on every port.
    #
    # WHY THIS IS NEEDED: pods land on whichever node has room. A NiFi pod on
    # node 1 must reach a Kafka broker on node 3; our toolbox pod must reach
    # everything. Without node-to-node openness you get bewildering
    # intermittent failures that depend on where the scheduler happened to put
    # things.
    #
    # SECURITY TRADE-OFF, stated honestly: this is permissive. The nodes are
    # in private subnets and unreachable from the internet, so the blast
    # radius is contained, and it matches how most EKS clusters are actually
    # run. The rigorous alternative is to enforce pod-to-pod policy INSIDE
    # Kubernetes with NetworkPolicy resources (the VPC CNI supports them), which
    # is far more precise than security groups can be at this layer.
    ingress_self_all = {
      description = "Allow all traffic between worker nodes"
      protocol    = "-1" # "-1" means every protocol
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true # "self" = source is this same security group
    }
  }

  tags = var.tags
}

# =============================================================================
# IAM ROLE FOR THE EBS CSI DRIVER
# =============================================================================
# BACKGROUND: HOW DOES A POD GET AWS PERMISSIONS?
#
# The EBS CSI driver is a pod. When Kafka asks for a 20 GiB volume, that pod
# must call the AWS API to create one. So it needs AWS credentials.
#
# THE WRONG WAYS TO DO THIS:
#   - Bake access keys into the image. They leak and never rotate.
#   - Put keys in a Kubernetes Secret. Better, but still long-lived and
#     visible to anyone who can read secrets in that namespace.
#   - Grant the permission to the NODE's role. Simple, but then EVERY pod on
#     that node inherits it, including a compromised one.
#
# THE RIGHT WAY: EKS Pod Identity. You associate an IAM role with a specific
# Kubernetes ServiceAccount. AWS injects short-lived, auto-rotating credentials
# into only the pods using that ServiceAccount. Nothing long-lived exists
# anywhere.
#
# (You may see "IRSA" in older tutorials. It achieves the same thing through
# OIDC federation. Pod Identity is newer, simpler to configure, and does not
# require an OIDC provider per cluster. Prefer Pod Identity for new work.)
# =============================================================================

# The trust policy: WHO is allowed to assume this role.
data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect = "Allow"

    # The EKS Pod Identity service is the only thing permitted to assume it.
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",

      # TagSession is REQUIRED for Pod Identity specifically. It lets EKS
      # attach the cluster/namespace/service-account names to the session so
      # they appear in CloudTrail. Omitting it produces an assume-role failure
      # that is genuinely hard to diagnose.
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
  description        = "Lets the EBS CSI driver create and attach EBS volumes for PersistentVolumeClaims"

  tags = var.tags
}

# Attach AWS's ready-made policy for this driver. Using the AWS-managed policy
# means AWS updates the permissions when the driver gains features, so you do
# not have to track that yourself.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
