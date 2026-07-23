# =============================================================================
# 01-cluster/storageclass.tf   --   HOW PODS GET DISKS
# =============================================================================
# BACKGROUND: PERSISTENT STORAGE IN KUBERNETES
#
# Containers are disposable. Anything written inside one vanishes when it
# restarts. That is fine for a web server, and fatal for Kafka.
#
# Kubernetes solves this with three linked ideas:
#
#   StorageClass         - a MENU. "Here are the kinds of disk you may order."
#   PersistentVolumeClaim- an ORDER. "I want 20 GiB of the 'gp3' kind."
#   PersistentVolume     - the DELIVERED DISK, a real EBS volume in AWS.
#
# When a PVC appears, the EBS CSI driver reads the StorageClass, calls AWS to
# create a matching volume, and attaches it to whichever node runs the pod.
#
# WHY WE OVERRIDE THE DEFAULT: EKS ships a StorageClass called "gp2" and marks
# it default. gp2 is the previous generation: slower, more expensive, and its
# performance is tied to volume size (a small gp2 volume is a slow one). gp3
# is better in every respect. Making gp3 the default means Kafka and NiFi get
# good disks without either chart having to know anything about AWS.
# =============================================================================

# -----------------------------------------------------------------------------
# We need the KUBERNETES provider here, not just the AWS provider, because a
# StorageClass is a Kubernetes object, not an AWS one.
# -----------------------------------------------------------------------------
# The provider must authenticate to the cluster we just built. The exec block
# below is the recommended pattern: instead of storing a token (which expires
# after 15 minutes and would rot inside the state file), Terraform SHELLS OUT
# to the AWS CLI and gets a fresh token on every single run.
#
# PREREQUISITE: this means the AWS CLI v2 must be installed and on your PATH.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region,
    ]
  }
}

# -----------------------------------------------------------------------------
# Turn OFF the "default" flag on the built-in gp2 class.
# -----------------------------------------------------------------------------
# Kubernetes permits only ONE default StorageClass. If two claim the title,
# PVCs that do not name a class are rejected outright. So before we promote
# gp3 we must demote gp2.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  # force = true tells Terraform to take ownership of this field even though
  # another controller (the EKS add-on machinery) set it first. Without this
  # you get a field-manager conflict error.
  force = true

  # The cluster and its add-ons must exist before we can patch their objects.
  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Create gp3 and make it the new default.
# -----------------------------------------------------------------------------
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      # THIS is the annotation that makes a class the default. Any PVC that
      # omits storageClassName now gets gp3.
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  # Which CSI driver handles this class.
  storage_provisioner = "ebs.csi.aws.com"

  parameters = {
    type = "gp3"

    # Encrypt the volume at rest. There is NO performance penalty and NO extra
    # charge for EBS encryption, so there is no reason ever to leave it off.
    # Many compliance regimes (PCI, HIPAA, SOC 2) require it outright.
    encrypted = "true"

    # The filesystem to lay down on the raw block device. ext4 is the
    # conservative, universally supported choice. (xfs is faster for very
    # large files; not worth the variation here.)
    "csi.storage.k8s.io/fstype" = "ext4"
  }

  # ---- Volume binding mode: subtle but very important ----
  # "WaitForFirstConsumer" delays creating the EBS volume until Kubernetes has
  # decided which NODE the pod will run on.
  #
  # WHY IT MATTERS: an EBS volume lives in exactly one Availability Zone and
  # can only attach to instances in that same zone. With the alternative
  # setting ("Immediate"), the volume might be created in us-east-1a while the
  # scheduler later decides to place the pod in us-east-1c. The pod then hangs
  # forever, unschedulable, with an error about volume node affinity conflict.
  #
  # This is one of the most common multi-AZ Kubernetes storage bugs, and this
  # single line prevents it.
  volume_binding_mode = "WaitForFirstConsumer"

  # Allow a PVC to be enlarged later without recreating the pod. You cannot
  # turn this on retroactively for existing volumes, so always set it up front.
  allow_volume_expansion = true

  # "Delete" = when the PVC is deleted, destroy the EBS volume too.
  #
  # TRADE-OFF: this is right for a demo (no forgotten volumes quietly billing
  # you) but dangerous for production databases, where a fat-fingered
  # `kubectl delete pvc` becomes permanent data loss. For real Kafka, use
  # "Retain" so the volume survives and must be cleaned up deliberately.
  reclaim_policy = "Delete"

  depends_on = [
    module.eks,
    kubernetes_annotations.gp2_not_default,
  ]
}
