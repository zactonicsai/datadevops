#!/usr/bin/env bash
# Apply (or destroy) the stacks in order. Each stack has its own state file, backend.hcl and terraform.tfvars.
#   ./run.sh apply            # all, in order
#   ./run.sh apply 04         # one stack
#   ./run.sh destroy          # all, reverse order
#   ./run.sh plan 06
set -euo pipefail
cd "$(dirname "$0")"
ACTION=${1:-plan}; ONLY=${2:-}
STACKS=(01-network 02-eks-cluster 03-eks-nodegroups 04-keycloak-ec2 05-kafka 06-kafka-ui)
[[ "$ACTION" == "destroy" ]] && STACKS=($(printf '%s\n' "${STACKS[@]}" | tac))
for s in "${STACKS[@]}"; do
  [[ -n "$ONLY" && "$s" != "$ONLY"* ]] && continue
  echo "=============== $s : $ACTION ==============="
  ( cd "$s"
    [[ -f backend.hcl ]] || { echo "missing $s/backend.hcl (copy backend.hcl.example)"; exit 1; }
    [[ -f terraform.tfvars ]] || { echo "missing $s/terraform.tfvars (copy terraform.tfvars.example)"; exit 1; }
    terraform init -input=false -backend-config=backend.hcl >/dev/null
    case "$ACTION" in
      plan)    terraform plan -input=false ;;
      apply)   terraform apply -input=false -auto-approve ;;
      destroy) terraform destroy -input=false -auto-approve ;;
      *) echo "unknown action $ACTION"; exit 1 ;;
    esac )
done
