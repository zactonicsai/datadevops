SHELL := /usr/bin/env bash

.PHONY: check validate plan apply test load-test destroy

check:
	./scripts/check-prerequisites.sh

validate:
	./scripts/validate-all.sh

plan:
	./scripts/plan-all.sh

apply:
	./scripts/apply-all.sh

test:
	./scripts/run-tests-local.sh

load-test:
	./scripts/load-test.sh

destroy:
	./scripts/destroy-all.sh
