# Zarf package

[`zarf.yaml`](zarf.yaml) packages the API image, the Kubernetes resources, and an
optional test client into one versioned archive. [Zarf](https://docs.zarf.dev/)
pushes the packaged images into a registry inside the cluster and rewrites pod
image references to it, so the deployment does not pull from the host or a
public registry.

## Validate on k3d (one command)

Prerequisites: Docker running, [`k3d`](https://k3d.io/), `kubectl`, and the
[`zarf`](https://docs.zarf.dev/getting-started/install/) CLI. Run from the
repository root:

```bash
make zarf-validate
```

[`scripts/zarf-validate.sh`](../../scripts/zarf-validate.sh) does the following:

1. Creates a fresh `zarf-lab` k3d cluster with its own kubeconfig in `build/`;
   your default kubeconfig and current context are left unchanged.
2. Builds `platform-engineering-lab:0.1.0`, lints the definition, and creates
   `build/zarf-package-platform-engineering-lab-<arch>-0.1.0-standalone.tar.zst`.
3. On first use, downloads the official init package for the installed Zarf
   version into `~/.zarf-cache` and runs `zarf init` (in-cluster registry and
   mutating agent).
4. Deploys the package with the optional `smoke-client` component.
5. Fails unless every pod image in `platform-lab` points at the Zarf registry,
   then runs the same runtime checks as `make k3d-validate`
   ([`scripts/runtime-checks.sh`](../../scripts/runtime-checks.sh)).

The API image is never imported into this cluster with `k3d image import`, so
the successful rollout shows that it came from the package. Delete the lab with
`make zarf-down`.

Last local result (2026-11-10, Zarf v0.89.0, k3d v5.9.0, Kubernetes v1.35.5+k3s1):

```text
build/zarf-package-platform-engineering-lab-arm64-0.1.0-standalone.tar.zst (57M)
127.0.0.1:31999/curlimages/curl:8.21.0-zarf-2584732664
127.0.0.1:31999/library/platform-engineering-lab:0.1.0-zarf-3554502284
UID 10001, no capabilities, read-only root filesystem
/health -> {"status":"healthy"}
/ready -> {"status":"ready"}
unlabeled client blocked by NetworkPolicy
Zarf validation passed on k3d-zarf-lab (v1.35.5+k3s1): packaged images from the in-cluster registry, rollout, endpoints, identity, allowed and denied network paths
```

## Package layout

| Component | Required | Contents |
| --- | --- | --- |
| `platform-engineering-lab` | Yes | API image and the [Kustomize overlay](overlay/kustomization.yaml), which pins tag `0.1.0` on the shared [base](../kubernetes/base/) |
| `smoke-client` | No | `curl` image and the [labeled test pod with its own ServiceAccount](../kubernetes/smoke-client.yaml) |

The required component has two **flavors**, chosen at build time with
`zarf package create --flavor`:

- `standalone` (used by `make zarf-validate`): the hand-written default-deny
  NetworkPolicies. Works on any cluster with a policy controller.
- `uds` (used by `make uds-validate`): no hand-written policies; the
  [UDS `Package` CR](../uds/package.yaml) declares the network intent and the
  UDS Operator generates the policies.

- `release` (used by the [release workflow](../../.github/workflows/release.yml)):
  the image published to GHCR, pinned by digest.
  [`scripts/release-overlay.sh`](../../scripts/release-overlay.sh) writes the
  overlay, and the image reference is passed with `--set APP_IMAGE=...`.

Zarf adds the flavor to the file name, for example `...-0.1.0-uds.tar.zst`.

Optional components keep test tooling out of a normal deployment:
`zarf package deploy <package> --confirm` installs only the API, and
`--components=smoke-client` adds the test client.

## Inspect the package

```bash
zarf package inspect definition build/zarf-package-platform-engineering-lab-*-0.1.0-standalone.tar.zst
zarf package inspect images build/zarf-package-platform-engineering-lab-*-0.1.0-standalone.tar.zst
zarf package inspect sbom build/zarf-package-platform-engineering-lab-*-0.1.0-standalone.tar.zst --output build/sbom
```

Zarf generates an SBOM for every packaged image during `zarf package create`.

## Signing and verification

```bash
make sign-validate
```

[`scripts/sign-validate.sh`](../../scripts/sign-validate.sh) needs no cluster.
It signs the package with a throwaway key pair and fails unless every case
behaves as expected:

| Case | Expected |
| --- | --- |
| Signed package, matching public key | Accepted |
| Unsigned package | Rejected: `not signed` |
| Signed package, different public key | Rejected: `invalid signature` |
| Package modified after signing (`zarf.yaml` edited and repacked) | Rejected: `invalid signature` |
| `zarf package deploy --verify=always` of the unsigned package | Rejected before deployment |

Each rejection must also show the expected reason, so an unrelated error
cannot pass as a rejection. The throwaway keys are deleted at the end;
[`scripts/gen-test-key.py`](../../scripts/gen-test-key.py) creates them with
`zarf tools gen-key`.

Releases do not use a stored key. The
[release workflow](../../.github/workflows/release.yml) runs on a `vX.Y.Z` tag
and signs **keylessly**: Sigstore issues a short-lived certificate for the
workflow's GitHub OIDC identity, and the signature is recorded in the Rekor
transparency log. The workflow pushes the image to GHCR, signs it by digest
with cosign, builds the `release` flavor, signs and verifies the package,
checks that another workflow's identity is rejected, and attaches the package,
SBOMs, and checksums to a GitHub release.

## Known gaps

- **Not tested on a disconnected network.** The deploy step used only the
  package and the in-cluster registry. Creating the package and the first
  `zarf init` download still need internet access.
- **No release yet.** The release workflow has not run, so no signed image
  or package is published. The packages built by `make zarf-validate` and
  `make uds-validate` are unsigned test builds.
- **curl is tag-pinned.** UDS CLI v0.41.0 cannot bundle a multi-platform
  image index, so the curl image uses its tag. See the
  [UDS guide](../uds/README.md#known-gaps).
- **App image is digest-pinned only in the `release` flavor.** The
  `standalone` and `uds` flavors use a locally built image, so `zarf dev lint`
  warns about the missing digest and registry.
- **Single architecture.** The package is built for the host architecture
  (arm64 here). Use `zarf package create -a amd64` with an amd64 image for
  other clusters.
- **Not published.** CI builds the package, deploys it to a temporary k3d
  cluster, and uploads it with its SBOMs as a workflow artifact, but nothing
  is pushed to a registry or attached to a release yet.
