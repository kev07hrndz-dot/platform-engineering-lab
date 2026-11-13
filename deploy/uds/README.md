# UDS Core integration

[UDS Core](https://docs.defenseunicorns.com/core/) runs platform services
(Istio service mesh, the UDS Operator, and admission policies) on Kubernetes.
An application states what it needs in a UDS `Package` custom resource, and the
UDS Operator generates the matching network and mesh configuration.

| File | Purpose |
| --- | --- |
| [`package.yaml`](package.yaml) | `Package` CR: ambient mesh mode, a route on the tenant gateway, and the lab-client allow rules |
| [`overlay/kustomization.yaml`](overlay/kustomization.yaml) | Reuses the Zarf overlay and removes the hand-written NetworkPolicies, which the operator now generates |
| [`uds-bundle.yaml`](uds-bundle.yaml) | UDS bundle with the `uds` flavor of the [Zarf package](../zarf/zarf.yaml) and the optional `smoke-client` component |

## Validate on k3d (one command)

Prerequisites: Docker with at least 10 GiB of memory for UDS Core,
[`k3d`](https://k3d.io/), `kubectl`, and the
[`uds`](https://github.com/defenseunicorns/uds-cli/releases) CLI. Port 443 on
the host must be free. Run from the repository root:

```bash
make uds-validate
```

[`scripts/uds-validate.sh`](../../scripts/uds-validate.sh) does the following:

1. On first use, runs `uds deploy k3d-core-slim-dev:1.14.3`. This creates the
   `uds` k3d cluster with Zarf, Istio, and the UDS Operator. It takes about
   6 minutes with a fast connection.
2. Builds the `uds` flavor of the Zarf package and the UDS bundle, then deploys
   the bundle.
3. Waits for the `Package` CR to reach `Ready` and checks that the hand-written
   NetworkPolicies are gone.
4. Runs the shared image-source, identity, and allowed-path checks
   ([`scripts/runtime-checks.sh`](../../scripts/runtime-checks.sh)).
5. Starts two fresh pods that must be blocked, each by a different layer (see
   below).
6. Requests `https://platform-lab.uds.dev/health` from the host through the
   Istio tenant gateway. `*.uds.dev` resolves to `127.0.0.1`.

Delete the cluster with `make uds-down`.

Last local result (2026-11-10, UDS CLI v0.41.0, UDS Core 1.14.3, Kubernetes v1.36.4+k3s1):

```text
Package Ready, endpoints ["platform-lab.uds.dev"], 6 generated NetworkPolicies
127.0.0.1:31999/curlimages/curl:8.21.0-zarf-2584732664
127.0.0.1:31999/library/platform-engineering-lab:0.1.0-zarf-3554502284
UID 10001, no capabilities, read-only root filesystem
/health -> {"status":"healthy"}
/ready -> {"status":"ready"}
right identity, no label: blocked by NetworkPolicy
right label, default ServiceAccount: blocked by Istio AuthorizationPolicy
https://platform-lab.uds.dev/health -> {"status":"healthy"}
UDS validation passed on k3d-uds (v1.36.4+k3s1, UDS Core 1.14.3)
```

## What the operator generated

From one `Package` CR, the UDS Operator created:

- **6 NetworkPolicies:** namespace default-deny, DNS egress, ambient health
  probes, tenant-gateway ingress on port 8000, and the client ingress and
  egress rules. Each allow rule also opens 15008, the HBONE port that ambient
  mode uses.
- **2 Istio AuthorizationPolicies** (ALLOW): one for the tenant gateway's
  identity and one for `cluster.local/ns/platform-lab/sa/lab-client`.
- **A route** from `platform-lab.uds.dev` on the tenant gateway to the Service.

## Two layers, tested separately

| Layer | Selects by | Test pod | Result |
| --- | --- | --- | --- |
| NetworkPolicy (kernel, L3/L4) | Pod labels | `lab-client` ServiceAccount, **no label** | Blocked |
| Istio AuthorizationPolicy (ztunnel, mTLS) | Workload identity (ServiceAccount) | Label present, **`default` ServiceAccount** | Blocked: `Connection reset by peer` |

The first version authorized only the label. Istio cannot match labels, so the
generated AuthorizationPolicy allowed the whole namespace, and only the
NetworkPolicy enforced the label. The test that removes the label from a
connected client then failed: in ambient mode, ztunnel reuses its established
HBONE connection, and NetworkPolicy only filters new connections. Adding
`remoteServiceAccount: lab-client` makes the mesh authorize the cryptographic
identity. The test now uses fresh pods, so each layer is checked on its own.
This is why the base guide says labels are not identities.

## Known gaps

- **Slim dev bundle.** `k3d-core-slim-dev` includes Istio and the UDS Operator
  but not Keycloak, Prometheus, or logging, so the `Package` CR has no `sso` or
  `monitor` entries. The API also has no `/metrics` endpoint yet.
- **curl image is tag-pinned, not digest-pinned.** UDS CLI v0.41.0 panics while
  bundling a Zarf package that contains a multi-platform image index (the
  digest of curl's manifest list). The tag stores only the package's platform
  and also cuts the package from 97 MB to 57 MB. Digest pinning returns with
  the signing work in roadmap step 4.
- **Local only** (CI runners do not have the memory for UDS Core),
  **unsigned, and not tested on a disconnected network**, as with
  the [Zarf package](../zarf/README.md#known-gaps). Creating the UDS Core
  cluster pulls packages from `ghcr.io`.
