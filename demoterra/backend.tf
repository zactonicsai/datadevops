###############################################################################
# Remote state backend (partial configuration).
#
# Never hardcode the bucket/key here - pass them at init time so the same code
# can be used for every environment:
#
#   terraform init \
#     -backend-config="bucket=my-tfstate-bucket" \
#     -backend-config="key=keycloak/dev/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=terraform-locks" \
#     -backend-config="encrypt=true"
#
# Or use: terraform init -backend-config=environments/dev.backend.hcl
#
# Comment this block out entirely to run with local state.
###############################################################################

terraform {
  backend "s3" {}
}
