PYTHON ?= python3

.PHONY: check test security k8s docker-smoke
check: test security

test:
	$(PYTHON) -m pytest -q

security:
	$(PYTHON) security/repo_guard.py .
	$(PYTHON) -m bandit -q -r app security
	$(PYTHON) -m pip_audit --strict -r requirements.txt

k8s:
	kubectl kustomize deploy/kubernetes/base

docker-smoke:
	PYTHON=$(PYTHON) sh scripts/docker-smoke.sh
