# Terraform Resource Generator

A simple Python command-line tool that asks questions and creates starter AWS Terraform resource blocks.

## Main resource types

- `ec2`
- `alb`
- `subnet`
- `ec2-alb-stack`

Additional helpers:

- `vpc`
- `security-group`
- `target-group`
- `listener`

## Why `REPLACE_ME` is used

The generator intentionally does not guess environment-specific values such as VPC IDs, AMI IDs, corporate CIDRs, Availability Zones, IAM instance profiles, or certificate ARNs.

Before applying generated Terraform:

```bash
grep -n REPLACE_ME *.tf
terraform fmt
terraform validate
terraform plan
```

## Examples

```bash
python terraform_resource_generator.py --resource ec2
python terraform_resource_generator.py --resource ec2 --output ec2.tf
python terraform_resource_generator.py --resource alb --output alb.tf
python terraform_resource_generator.py --resource subnet --output subnet.tf
python terraform_resource_generator.py --resource ec2-alb-stack --output app.tf
```

Show supported resource types:

```bash
python terraform_resource_generator.py --help
```

## Notes

This creates starter Terraform, not a complete production network. Depending on the environment, you may still need route tables, Internet/NAT gateways, private routing, IAM policies, SSM access, HTTPS/ACM, DNS, Auto Scaling, logging, monitoring, and backup configuration.
