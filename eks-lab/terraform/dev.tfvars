# =============================================================================
# dev.tfvars — EVERY difference between environments lives in this one file.
#
# To make a "stage" or "prod" environment you copy this file, change the
# values, and point Terraform at it with -var-file=prod.tfvars.
# The .tf code itself NEVER changes. That is the whole idea.
# =============================================================================

lab_name = "ekslab"
region   = "us-east-1"

# ---------- network ----------
vpc_cidr             = "10.42.0.0/16"
azs                  = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs  = ["10.42.0.0/20",  "10.42.16.0/20"]
private_subnet_cidrs = ["10.42.32.0/20", "10.42.48.0/20"]

# false = no NAT gateway, nodes go in public subnets. Saves ~$33/month.
# true  = best practice: nodes hidden in private subnets behind one NAT.
use_nat = true

# ---------- cluster ----------
kubernetes_version     = "1.34"
endpoint_public_access = true          # set false for anything real
# Lock the public endpoint to your own address:
#   public_access_cidrs = ["203.0.113.4/32"]
public_access_cidrs    = ["0.0.0.0/0"]

# ---------- nodes ----------
node_instance_types = ["t3.large"]
node_capacity_type  = "SPOT"           # ON_DEMAND for prod
node_min            = 2
node_desired        = 2
node_max            = 3
node_disk_gb        = 40

# ---------- apps ----------
namespace       = "lab"
kafka_topic     = "messages"
image_keycloak  = "quay.io/keycloak/keycloak:26.7.1"
image_kafka     = "apache/kafka:3.9.0"
image_nifi      = "apache/nifi:2.11.0"
image_python    = "python:3.12-slim"
enable_monitoring = true

tags = {
  Lab         = "ekslab"
  Environment = "dev"
  ManagedBy   = "terraform"
}
