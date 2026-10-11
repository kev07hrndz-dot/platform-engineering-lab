# Security scope and controls

This is a learning portfolio: a stateless FastAPI service with hardened runtime
settings and reviewable delivery checks. It contains no sensitive business data
and exposes informational and health endpoints. It is not a production system,
a compliance certification, or evidence of deployment to a defense environment.

## Threat model

Assets: repository integrity, build dependencies, container runtime, cluster
workloads, and any future credentials. Entry points: source changes, package and
base-image downloads, HTTP requests, and deployment configuration. Trust
boundaries: contributor to CI, build inputs to image, container to host, and pod
to other pods. The operator and Kubernetes control plane are trusted in this lab.

| Concern | Implemented control | Evidence and remaining limit |
| --- | --- | --- |
| Credentials committed to Git | RepoGuard checks supported repository text files and reports locations without printing matched values | Scanner tests and CI output; heuristic patterns can miss secrets and do not replace secret rotation or historical Git scanning |
| Unsafe Python changes | API tests and Bandit static analysis | CI fails on findings; static analysis does not demonstrate resistance to all attacks |
| Vulnerable dependencies | Pinned Python dependencies, pip-audit, and Trivy image scanning | Findings depend on advisory databases and scan freshness; a passing scan is not proof of zero vulnerabilities |
| Container compromise | Non-root UID/GID 10001; Compose/Kubernetes read-only root, dropped capabilities, no privilege escalation, and a bounded writable `/tmp` | Runtime configuration and container smoke check; application flaws and kernel vulnerabilities remain possible |
| Cluster credential misuse | Service-account token automount disabled | Deployment manifest; this service does not need Kubernetes API access |
| Lateral movement/exfiltration | Default-deny network policies with one same-namespace labeled client exception | Requires an enforcing CNI/controller and live allowed/denied tests; manifests alone do not enforce traffic |
| Workload instability | Health/readiness probes and Kubernetes resource budgets | Manifest validation; load testing, availability targets, and capacity tuning remain future work |
| Unreviewed delivery | GitHub Actions runs tests, RepoGuard, Bandit, dependency audit, manifest validation, Docker build/smoke, and image scan | Inspect the workflow/run logs; repository branch protection is a separate administrator setting |

## Verify the boundaries

The image uses a digest-pinned Debian Trixie Python base. It removes build-only
pip and its ensurepip bootstrap after installing application dependencies. This
also removes pip's vendored libraries from runtime; no CVE ignore list is used.
Trivy reports all known HIGH/CRITICAL image findings and blocks those with an
available fix. Unfixed findings remain visible in CI logs and still require
review; a passing gate does not mean the image has zero vulnerabilities.

Use the commands in the [main README](../README.md) for local checks and the
[Kubernetes guide](../deploy/kubernetes/README.md) for an optional cluster smoke.
The CI container smoke exercises a constrained Docker runtime. Manifest render
and schema checks verify configuration structure, not cluster admission,
NetworkPolicy enforcement, high availability, or cloud provisioning.

RepoGuard is deliberately small enough to understand and extend. Review each
finding, remove accidental secrets, rotate any exposed credential, and rerun the
checks. Never suppress a real secret simply to get a green build. Read the
[scanner documentation](../security/README.md) for scope and exit codes.

## Deliberate gaps

- No authentication, authorization, TLS termination, or SSO. Keep this demo
  local/internal; add these controls before exposing real application data.
- No database, secret manager, image signing, SBOM attestation, or release
  provenance policy. Dependency installation and scanner databases require
  network access today.
- No live cloud provisioning, Terraform state, production cluster, ingress,
  or disaster-recovery design. Kubernetes YAML demonstrates declarative workload
  configuration, not a completed cloud platform.
- UDS/Zarf packaging and disconnected delivery are roadmap work. Their presence
  in the README does not imply integration, certification, or an air-gapped test.

Network selectors are not identity or authorization. An operator must control
namespace access and label edits; the policies permit node-originated traffic
under Kubernetes semantics. See the official
[NetworkPolicy model](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
and [security-context guidance](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/).
