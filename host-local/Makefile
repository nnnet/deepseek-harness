.DEFAULT_GOAL := help

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
COMPOSE := docker compose --project-directory $(REPO_ROOT) -f $(REPO_ROOT)/host-local/docker/compose.yaml
TASK := $(REPO_ROOT)/host-local/docker/run-task.sh

.PHONY: help docker-config docker-build docker-prepare bdd spec-coverage spec-validate docker-redundancy docker-up docker-smoke docker-deploy docker-status docker-logs docker-down

help:
	@echo "make -f host-local/Makefile docker-deploy  build, prepare, test and start DSH"
	@echo "make -f host-local/Makefile docker-status  show the container"
	@echo "make -f host-local/Makefile docker-logs    follow DSH logs"
	@echo "make -f host-local/Makefile docker-down    stop the container"

docker-build:
	$(TASK) docker-build $(COMPOSE) build --pull

docker-config:
	$(TASK) docker-config $(COMPOSE) config --quiet

docker-prepare:
	$(TASK) docker-prepare $(COMPOSE) run --rm --no-deps dsh bash host-local/docker/prepare.sh

bdd:
	$(TASK) bdd $(COMPOSE) run --rm --no-deps dsh /opt/dsh-bdd/bin/pytest -q -c bdd/pytest.ini bdd

spec-coverage:
	$(TASK) spec-coverage agent-ops spec-coverage .

spec-validate:
	$(TASK) spec-validate openspec validate --all --strict

docker-redundancy:
	$(TASK) docker-redundancy bash host-local/docker/redundancy-gate.sh

docker-up:
	$(TASK) docker-up $(COMPOSE) up -d --no-build

docker-smoke:
	$(TASK) docker-smoke bash host-local/docker/smoke.sh

docker-deploy: docker-config docker-build docker-prepare bdd spec-coverage spec-validate docker-redundancy docker-up docker-smoke

docker-status:
	$(COMPOSE) ps

docker-logs:
	$(COMPOSE) logs --tail 200 -f dsh

docker-down:
	$(TASK) docker-down $(COMPOSE) down
