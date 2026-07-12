module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "eks-kafka-cluster"
  cluster_version = "1.30"

  cluster_endpoint_public_access = true

  vpc_id                   = module.vpc.vpc_id
  # Control plane points to standard private subnets
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    # General application workloads
    system_apps = {
      min_size       = 2
      max_size       = 5
      desired_size   = 2
      instance_types = ["m6i.large"]
      subnet_ids     = module.vpc.private_subnets
    }

    # Dedicated Node Group for Strimzi Kafka
    kafka_brokers = {
      min_size       = 3
      max_size       = 6
      desired_size   = 3
      instance_types = ["r6i.xlarge"] # Memory-optimized instances for Kafka
      
      # Explicitly pin Kafka nodes to the small /27 subnets
      subnet_ids     = module.vpc.intra_subnets

      labels = {
        role = "kafka-broker"
      }

      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "kafka"
          effect = "NO_SCHEDULE"
        }
      }

      # Ensure nodes have appropriate block storage for local caching/commit logs if needed
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            delete_on_termination = true
          }
        }
      }
    }
  }

  tags = {
    Environment = "production"
    Terraform   = "true"
  }
}