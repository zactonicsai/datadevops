resource "aws_security_group" "runner" {
  name        = "${local.cluster_name}-test-runner"
  description = "No inbound rules; outbound access for SSM and cluster testing"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  # No ingress block means no unsolicited inbound connection is allowed.

  egress {
    description = "Allow outbound HTTPS, package downloads, and in-VPC tests"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.cluster_name}-test-runner"
    Role = "eks-test-runner"
  }
}

# The EKS primary security group normally trusts only its own members.
# This rule lets only the test-runner security group reach the API and pod IPs.
resource "aws_vpc_security_group_ingress_rule" "runner_to_eks" {
  security_group_id            = data.terraform_remote_state.eks.outputs.cluster_security_group_id
  referenced_security_group_id = aws_security_group.runner.id
  ip_protocol                  = "-1"

  description = "Allow the SSM test runner to reach the private EKS API, nodes, and VPC-CNI pod IPs"
}
