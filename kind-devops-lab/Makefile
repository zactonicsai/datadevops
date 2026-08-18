SHELL := /bin/bash
.DEFAULT_GOAL := help

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: cluster images deploy seed urls ## build the whole lab from nothing

cluster: ## step 1: registry + kind cluster
	./scripts/01-cluster.sh

images: ## step 2: build & push the Java and C++ agent images
	./scripts/02-images.sh

deploy: ## step 3: install Gitea + Jenkins into the cluster
	./scripts/03-deploy.sh

seed: ## step 4: create repos and push the sample apps
	./scripts/04-seed-gitea.sh

urls: ## print the addresses
	@echo "Jenkins : http://localhost:8080  (admin / admin123)"
	@echo "Gitea   : http://localhost:3000  (jenkins / jenkins123)"
	@echo "Registry: http://localhost:5001/v2/_catalog"

toolbox: ## open a shell that already has kind, kubectl and helm
	docker compose --profile tools run --rm toolbox

logs: ## follow the Jenkins controller log
	kubectl -n devops logs -f statefulset/jenkins -c jenkins

down: ## delete the cluster and the registry
	./scripts/teardown.sh

.PHONY: help up cluster images deploy seed urls toolbox logs down
