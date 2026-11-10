PYTHON ?= python3

K3D_CLUSTER ?= platform-lab
ZARF_CLUSTER ?= zarf-lab

.PHONY: check test security k8s docker-smoke k3d-validate k3d-down zarf-validate zarf-down uds-validate uds-down
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

k3d-validate:
	K3D_CLUSTER=$(K3D_CLUSTER) sh scripts/k3d-validate.sh

k3d-down:
	k3d cluster delete $(K3D_CLUSTER)

zarf-validate:
	ZARF_CLUSTER=$(ZARF_CLUSTER) sh scripts/zarf-validate.sh

zarf-down:
	k3d cluster delete $(ZARF_CLUSTER)

uds-validate:
	sh scripts/uds-validate.sh

uds-down:
	k3d cluster delete uds
