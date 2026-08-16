output "cluster_role_arn" { value = aws_iam_role.cluster.arn }
output "node_role_arn"    { value = aws_iam_role.node.arn }
output "node_sg_id"       { value = aws_security_group.node.id }
output "alb_sg_id"        { value = aws_security_group.alb.id }
