data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "runner" {
  name               = "${local.cluster_name}-test-runner-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "eks_describe" {
  statement {
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:eks:${var.aws_region}:*:cluster/${local.cluster_name}",
    ]
  }
}

resource "aws_iam_role_policy" "eks_describe" {
  name   = "describe-eks-cluster"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.eks_describe.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${local.cluster_name}-test-runner-profile"
  role = aws_iam_role.runner.name
}
