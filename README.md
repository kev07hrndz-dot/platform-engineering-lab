# Airgap Exploration

[![CI](https://github.com/km-hernandez/airgap-exploration/actions/workflows/ci.yml/badge.svg)](https://github.com/km-hernandez/airgap-exploration/actions/workflows/ci.yml)

**Exploring how software reaches disconnected (air-gapped) Kubernetes environments.** A small FastAPI service, named `platform-engineering-lab` inside the repository, is hardened, packaged with Zarf, and integrated with UDS Core, with a one-command proof at each step. Built by Kevin Hernandez while learning platform engineering and DevSecOps, with code that is easy to inspect and run.

## Review in 30 seconds

- **Application:** FastAPI with API tests, health/readiness endpoints, and OpenAPI documentation.
- **Containers:** non-root UID 10001, a read-only filesystem, dropped capabilities, and a digest-pinned Python base image.
- **CI/security:** GitHub Actions runs tests, RepoGuard, Bandit, dependency audits, container scans, and a Docker smoke test.
- **Kubernetes/IaC:** declarative Kustomize manifests with probes, resource limits, restricted security contexts, and NetworkPolicy; schema checks in CI.
- **Runtime proof:** `make k3d-validate` deploys to a local k3d cluster and fails unless the rollout, non-root identity, endpoints, and allowed/denied NetworkPolicy paths all pass.
- **Zarf delivery:** `make zarf-validate` builds a versioned Zarf package, deploys it to a fresh k3d cluster, and fails unless every pod image is served from the in-cluster Zarf registry and the same runtime checks pass.
- **UDS Core integration:** `make uds-validate` deploys the package as a UDS bundle on UDS Core. It fails unless the UDS Operator reconciles the `Package` CR, the app answers through the Istio tenant gateway, and two fresh pods are blocked: one by NetworkPolicy (no label) and one by Istio identity authorization (wrong ServiceAccount).
- **Signature verification:** `make sign-validate` signs the package and fails unless an unsigned package, a wrong key, a package modified after signing, and an unsigned deployment are all rejected. It runs in CI on every pull request.
- **Next milestone:** the first tagged release from the [release workflow](.github/workflows/release.yml), which signs the image and package keylessly.

**Scope:** this is a learning portfolio. The application, checks, container configuration, and Kubernetes manifests are implemented, and the Kubernetes runtime behavior is validated on k3d: directly and from a Zarf package in CI on every pull request, and on UDS Core locally. Artifact signing and AWS/Terraform provisioning are future work. No production, compliance, or disconnected-network deployment is claimed. Use the linked [Actions runs](https://github.com/km-hernandez/airgap-exploration/actions) to inspect the current validation results.

## Architecture

```mermaid
flowchart LR
    Change[Code change] --> CI[GitHub Actions]
    CI --> Python[pytest + RepoGuard + Bandit + pip-audit]
    CI --> Container[Image build + Trivy + Docker smoke]
    CI --> Manifests[Kustomize render + kubeconform]
    Container --> Local[Docker Compose / localhost:8001]
    Local --> API[FastAPI / port 8000]
    Manifests --> K3d[make k3d-validate / local k3d cluster]
    K3d --> K8s[Kubernetes / ClusterIP service + NetworkPolicy]
    K8s -.-> API
    Manifests --> Zarf[make zarf-validate / Zarf package]
    Container --> Zarf
    Zarf --> Registry[In-cluster Zarf registry]
    Registry --> K8s
    Zarf --> UDS[make uds-validate / UDS bundle on UDS Core]
    UDS --> Mesh[Istio ambient + UDS Operator policies]
    Mesh -.-> API
```

CI validates every change. Two jobs create a temporary k3d cluster on the runner and run `make k3d-validate` and `make zarf-validate`; the Zarf job uploads the package and its SBOMs as a workflow artifact. CI does not publish an image or deploy to a long-lived cluster, and UDS Core validation runs locally because it needs about 10 GiB of memory. The API has no database, external services at runtime, or privileged infrastructure access.

## Run locally

### Python

Requires Python 3.13. Run these commands from the repository root:

```bash
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
make check
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Open [API docs](http://127.0.0.1:8000/docs) or check the service from a second terminal:

```bash
curl --fail http://127.0.0.1:8000/health
curl --fail http://127.0.0.1:8000/ready
```

Individual checks are also available:

```bash
python -m pytest
python security/repo_guard.py .
python -m bandit -r app security
python -m pip_audit -r requirements.txt
```

### Docker

Requires a running Docker engine; on macOS, start Docker Desktop.

```bash
docker info
docker compose up --build -d
curl --fail http://127.0.0.1:8001/health
curl --fail http://127.0.0.1:8001/ready
docker compose exec -T api id
docker compose ps
```

The container listens on 8000; Compose exposes it only on `127.0.0.1:8001`. This keeps Python development on port 8000 available. See [interactive docs](http://127.0.0.1:8001/docs), follow logs with `docker compose logs -f api`, and stop it with `docker compose down`. Rebuild after changing application code or dependencies. The final image removes pip and its ensurepip bootstrap after installation, including their unused vendored libraries; dependency changes happen through an image rebuild.

```bash
make docker-smoke
```

The smoke test uses a separate Compose project and a random local port, then cleans up. It checks real HTTP responses and verifies UID 10001, dropped capabilities, no new privileges, and a read-only root filesystem inside the running container.

### Kubernetes

Requires Docker, [k3d](https://k3d.io/), and `kubectl`.

```bash
make k3d-validate   # create/reuse the cluster, deploy, and prove runtime controls
make k3d-down       # delete the local cluster
make zarf-validate  # build the Zarf package, deploy it to a fresh cluster, and run the same checks
make zarf-down      # delete the Zarf lab cluster
make uds-validate   # deploy UDS Core (first run) and the UDS bundle, then prove the integration
make uds-down       # delete the UDS cluster
make sign-validate  # sign the package and prove that untrusted packages are rejected (no cluster)
```

The validation builds the image, imports it into k3d without a registry, and checks the rollout, UID 10001 with no capabilities and a read-only root filesystem, real `/health` and `/ready` responses from an allowed client, and that an unlabeled client is blocked. k3s enforces NetworkPolicy with its embedded controller. See the [Kubernetes guide](deploy/kubernetes/README.md) for the manual steps and the last recorded result, the [Zarf guide](deploy/zarf/README.md) for the package layout, and the [UDS guide](deploy/uds/README.md) for the generated policies. Each guide lists its known gaps. `make k8s` only renders the manifests. CI checks their schemas and also runs the k3d and Zarf validations on a temporary cluster.

## API contract

| Endpoint | Purpose |
| --- | --- |
| `GET /` | Project welcome and application status |
| `GET /health` | Liveness: the application responds |
| `GET /ready` | Readiness: this stateless application can serve traffic |
| `GET /info` | Developer, project, and engineering focus |
| `GET /docs` | Interactive OpenAPI documentation |

Readiness currently has no upstream services to inspect. If a database or dependency is added, the readiness contract must change with it.

## Threats and security controls

| Threat | Implemented control | Boundary / remaining work |
| --- | --- | --- |
| Credentials committed to source | [RepoGuard](security/repo_guard.py) reports file, line, and issue without printing matched values; CI fails on findings | Heuristic detection can miss secrets or flag examples; scans the working tree, not Git history |
| Unsafe Python code or vulnerable dependencies | Bandit and pip-audit in [CI](.github/workflows/ci.yml); pinned requirements | Static checks and advisory databases are incomplete; pins still need updates |
| Excessive container privileges | [Dockerfile](Dockerfile) uses UID/GID 10001; [Compose](compose.yaml) drops capabilities, prevents privilege escalation, and uses a read-only root filesystem | Containers share the host kernel; these controls do not provide a complete isolation boundary |
| Vulnerable or misconfigured images | Digest-pinned base image; Trivy image and configuration checks | Image gate blocks HIGH/CRITICAL vulnerabilities with fixes; unfixed vulnerabilities can remain |
| Unhealthy workloads or resource exhaustion | [Kubernetes manifests](deploy/kubernetes/) define probes and resource requests/limits; rollout and readiness verified on k3d | Failure behavior under load and multi-node scheduling are not tested |
| Unnecessary cluster/network access | Restricted workload settings, disabled service account token mounting, and default-deny NetworkPolicy; allowed and denied paths verified on k3d. On UDS Core, Istio also authorizes the client's ServiceAccount identity over mTLS | NetworkPolicy paths are verified in CI; the Istio identity check is verified locally only; labels are not identities, so RBAC must protect them; end-user authentication (Keycloak SSO) is not configured |

See the [security design](docs/security.md) for assumptions and verification boundaries. The API intentionally exposes only demonstration responses. Authentication, authorization, TLS termination, observability, image signing, and a production operational model remain work to do before handling sensitive data or public traffic.

## Skills demonstrated

| Skill | Inspectable evidence |
| --- | --- |
| Python API development | [FastAPI routes](app/main.py), [API tests](tests/test_api.py) |
| Linux/container security | [Dockerfile](Dockerfile), [Compose runtime restrictions](compose.yaml) |
| Security tooling | [RepoGuard implementation](security/repo_guard.py), [scanner tests](tests/test_repo_guard.py) |
| CI/CD foundations | [GitHub Actions gates](.github/workflows/ci.yml), [repeatable local commands](Makefile); deployment automation is a next step |
| Kubernetes and declarative infrastructure | [Kustomize manifests](deploy/kubernetes/), [runtime validation script](scripts/k3d-validate.sh), and the [operating guide](deploy/kubernetes/README.md) |
| Disconnected-style software delivery | [Zarf package definition](deploy/zarf/zarf.yaml), [package validation script](scripts/zarf-validate.sh), and the [Zarf guide](deploy/zarf/README.md) with known gaps |
| Platform integration (UDS Core, Istio) | [UDS `Package` CR](deploy/uds/package.yaml), [UDS bundle](deploy/uds/uds-bundle.yaml), [integration script](scripts/uds-validate.sh), and the [UDS guide](deploy/uds/README.md) |
| Threat modeling and technical communication | Security control table above and [Kevin's Spanish learning guide](docs/learning-guide.md) |

Cloud provisioning and Terraform are roadmap items, not demonstrated implementations.

## Roadmap toward Zarf and UDS

The next steps build on the same small service instead of adding unrelated tools.

| Step | Deliverable | Evidence needed to call it complete |
| --- | --- | --- |
| 1. Prove Kubernetes runtime ✅ | `make k3d-validate` on a local k3d cluster | Done 2026-11-08: ready rollout, real endpoint responses, non-root identity, and allowed/denied network tests |
| 2. Package with Zarf ✅ | `make zarf-validate` with a versioned package carrying the images and Kubernetes resources | Done 2026-11-09: package build and inspection, deployment to a fresh cluster with images served only from the in-cluster Zarf registry, and the same runtime checks (not yet tested on a disconnected network) |
| 3. Integrate with UDS Core ✅ | `make uds-validate` with a `Package` CR and a UDS bundle | Done 2026-11-10 on UDS Core 1.14.3 (slim dev): Package `Ready`, operator-generated policies, ingress through the tenant gateway, and separate label and identity denials. Monitoring and SSO need the full Core bundle |
| 4. Add supply-chain evidence (in progress) | SBOM, signed artifacts, and verification before deployment | Done 2026-11-12: `make sign-validate` rejects unsigned, wrong-key, and tampered packages in CI, and CI stores the package with its SBOMs. Remaining: the first tagged release, which publishes the image to GHCR and signs the image and package keylessly |
| 5. Evaluate cloud IaC | A minimal Terraform AWS environment with a cost/cleanup plan | Reviewed plan, tested apply/destroy, and documented access boundaries |

[Zarf](https://docs.zarf.dev/) packages software and its dependencies for disconnected delivery. [UDS separates delivery from platform integration](https://docs.defenseunicorns.com/core/v1-13/concepts/configuration--packaging/overview/): the UDS Operator reconciles application requirements from custom resources. A [UDS bundle](https://docs.defenseunicorns.com/core/v1-13/concepts/configuration--packaging/bundles/) groups versioned Zarf packages and environment configuration. The [Zarf package](deploy/zarf/) and the [UDS `Package` CR and bundle](deploy/uds/) are implemented and validated locally.
