#!/usr/bin/env bash
# Build a self-contained tarball (Terraform code + vendored charts/manifests + optional provider mirror).
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="kafka-keycloak-eks-terraform-$(date +%Y%m%d).tar.gz"
tar czf "$OUT" --exclude='.terraform' --exclude='*.tfstate*' --exclude='terraform.tfvars' eks
echo "Wrote $OUT"; tar tzf "$OUT" | grep -v '/$' | wc -l; echo "files"
