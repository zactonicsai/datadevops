# 02 - EKS

This folder creates IAM roles, a KMS key, the EKS control plane, one managed
node group, OIDC integration, and core EKS add-ons.

The public API endpoint is limited to CIDRs supplied through
`public_access_cidrs`. The private endpoint lets the in-VPC test runner connect.
