# Vendored charts (no network needed at `terraform apply`)

| Chart | Version | App version | Source |
|-------|---------|-------------|--------|
| aws-load-balancer-controller | 1.11.0 | v2.11.0 | github.com/aws/eks-charts v0.0.190 (stable/) |
| strimzi-kafka-operator | 0.45.0 | 0.45.0 | github.com/strimzi/strimzi-kafka-operator release 0.45.0 |
| kafka-ui | 1.6.5 | v1.5.0 | github.com/kafbat/helm-charts (charts/kafka-ui) |

Manifests: keycloak-operator 26.3.0 (github.com/keycloak/keycloak-k8s-resources tag 26.3.0)
IAM policy: aws-load-balancer-controller v2.11.0 docs/install/iam_policy.json

Refresh with `scripts/vendor.sh`.
