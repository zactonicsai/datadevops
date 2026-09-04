variable "cluster" {
  type = object({
    create                = optional(bool, true)
    existing_cluster_name = optional(string)
    name                  = string
    kubernetes_version    = optional(string, "1.31")
    endpoint_public_access = optional(bool, true)
    public_access_cidrs   = optional(list(string), ["0.0.0.0/0"])
    subnet_ids            = optional(list(string)) # null = private+public from network stack
    enabled_log_types     = optional(list(string), ["api", "audit", "authenticator"])
  })
}
variable "cluster_role" {
  description = "Create the control-plane role or use an existing one"
  type = object({
    create             = optional(bool, true)
    existing_role_name = optional(string)
  })
  default = {}
}
variable "addons" {
  description = "EKS add-ons to install with the cluster (add-on name => version). EBS CSI is handled here with its IRSA role."
  type        = map(string)
  default = {
    vpc-cni            = null
    coredns            = null
    kube-proxy         = null
    aws-ebs-csi-driver = null
  }
}
