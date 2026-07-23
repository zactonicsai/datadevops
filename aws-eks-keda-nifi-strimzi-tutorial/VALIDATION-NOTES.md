# Validation Notes

The project received these offline checks before packaging:

- Every shell script passed `bash -n` syntax checking.
- The rendered EC2 user-data template passed `bash -n`.
- The rendered NiFi configuration script passed `bash -n`.
- Every Helm and kubectl YAML file parsed successfully.
- All Terraform files passed a lexical delimiter and heredoc-balance check.
- KEDA, Metrics Server, and Strimzi value keys were compared with their pinned
  official chart values.
- Strimzi Kafka 4.3.0 and `metadataVersion: 4.3-IV0` were checked against the
  official Strimzi 1.1.0 example.

A live AWS deployment was not run because this build environment has no AWS
account credentials. Terraform CLI was also unavailable here, so run
`./scripts/validate-all.sh` on your workstation before the first apply. That
script performs `terraform fmt -check`, provider initialization, and
`terraform validate` for every numbered folder.
