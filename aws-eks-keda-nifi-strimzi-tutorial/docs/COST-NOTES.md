# Cost Notes

This lab uses billable AWS services:

- Amazon EKS control plane
- Four EC2 worker nodes by default
- One EC2 test runner
- One NAT Gateway and its data processing
- Public IPv4 addresses
- gp3 EBS volumes for Kafka and NiFi
- CloudWatch control-plane logs
- Data transfer

The exact amount changes by region and over time. Use the AWS Pricing Calculator
before building. For a cheaper short lab, reduce application sizes carefully,
but Kafka and NiFi need enough memory to start reliably.

## Cost-saving choices already included

- One NAT Gateway instead of one per Availability Zone
- A small SSM-only test runner
- ClusterIP services instead of public load balancers
- Small tutorial EBS volumes
- A combined Kafka controller/broker node pool

## Production trade-off

One NAT Gateway is cheaper but creates an Availability Zone dependency. A
production design normally uses one NAT Gateway per Availability Zone or uses
reviewed VPC endpoints and controlled egress.
