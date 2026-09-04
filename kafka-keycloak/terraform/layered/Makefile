# Usage:
#   make init  STACK=00-network ENV=dev
#   make plan  STACK=10-eks-cluster ENV=dev
#   make apply STACK=20-eks-nodegroups ENV=dev
#   make all   ENV=dev            # applies every stack in order
#   make destroy-all ENV=dev      # reverse order
ENV   ?= dev
STACKS = 00-network 10-eks-cluster 20-eks-nodegroups 30-keycloak-ec2 40-kafka 50-kafka-ui
TF     = terraform -chdir=stacks/$(STACK)

init:
	$(TF) init -reconfigure -backend-config=backend.$(ENV).hcl
plan: init
	$(TF) plan -var-file=$(ENV).tfvars
apply: init
	$(TF) apply -var-file=$(ENV).tfvars
destroy: init
	$(TF) destroy -var-file=$(ENV).tfvars
validate: init
	$(TF) validate
fmt:
	terraform fmt -recursive .

all:
	@for s in $(STACKS); do $(MAKE) apply STACK=$$s ENV=$(ENV) || exit 1; done
destroy-all:
	@for s in $(shell echo $(STACKS) | tr ' ' '\n' | tac); do $(MAKE) destroy STACK=$$s ENV=$(ENV) || exit 1; done

# One-time: create the state bucket + lock table
bootstrap-state:
	aws s3api create-bucket --bucket $(BUCKET) --region $(REGION) $(if $(filter us-east-1,$(REGION)),,--create-bucket-configuration LocationConstraint=$(REGION))
	aws s3api put-bucket-versioning --bucket $(BUCKET) --versioning-configuration Status=Enabled
	aws dynamodb create-table --table-name terraform-locks --attribute-definitions AttributeName=LockID,AttributeType=S \
	  --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST --region $(REGION)
