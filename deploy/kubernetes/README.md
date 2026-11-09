# Kubernetes lab

This Kustomize base is a small, declarative deployment scaffold: one API, one
internal Service, a restricted namespace, and explicit network rules. CI renders
and validates the manifests. The runtime behavior (rollout, identity, and
NetworkPolicy enforcement) is verified locally on k3d with one command.

## Validate on k3d (one command)

Prerequisites: Docker running, [`k3d`](https://k3d.io/), and `kubectl`.
Run from the repository root:

```bash
make k3d-validate
```

[`scripts/k3d-validate.sh`](../../scripts/k3d-validate.sh) creates the
`platform-lab` cluster if needed, builds the image, imports it into the cluster
(no registry), applies the manifests, and then fails unless all of these pass:

1. The Deployment rolls out and the readiness probe succeeds.
2. Inside the pod: UID 10001, no effective capabilities, read-only root filesystem.
3. A client pod with the allowed label gets real `/health` and `/ready` responses.
4. After that label is removed, the same client is blocked by NetworkPolicy.

Every `kubectl` call uses `--context k3d-platform-lab`, so the script never
touches another cluster. Delete the lab with `make k3d-down`.

Last local result (2026-11-08, k3d v5.9.0, Kubernetes v1.35.5+k3s1):

```text
UID 10001, no capabilities, read-only root filesystem
/health -> {"status":"healthy"}
/ready -> {"status":"ready"}
unlabeled client blocked by NetworkPolicy
k3d validation passed on k3d-platform-lab (v1.35.5+k3s1): rollout, endpoints, identity, allowed and denied network paths
```

### Why k3d

k3d runs [k3s](https://docs.k3s.io/) inside Docker. k3s ships an embedded
network-policy controller, so NetworkPolicy is enforced without installing a
separate CNI. The earlier kind-based guide never confirmed a policy controller,
so isolation was not proven there. k3d is also the local cluster used by
UDS development workflows, which is the next roadmap step.

## Run the steps manually

```bash
k3d cluster create platform-lab --servers 1 --agents 0 --wait
docker build -t platform-engineering-lab:dev .
k3d image import platform-engineering-lab:dev -c platform-lab
kubectl config use-context k3d-platform-lab
kubectl apply -k deploy/kubernetes/base
kubectl -n platform-lab rollout status deployment/platform-engineering-lab --timeout=120s
kubectl -n platform-lab port-forward service/platform-engineering-lab 8002:8000 --address=127.0.0.1
```

In another terminal (port 8002 avoids the Docker Compose container on 8001):

```bash
curl --fail http://127.0.0.1:8002/health
curl --fail http://127.0.0.1:8002/ready
```

The image uses `IfNotPresent`, so the cluster uses the imported image. After
changing the application, rebuild, re-import, and restart the Deployment. Use
unique image tags or immutable digests for a real release.

## Check the network paths manually

Port-forward uses the Kubernetes API and is useful for local access; it does not
verify pod-to-pod policy behavior. See the
[Kubernetes NetworkPolicy prerequisites](https://kubernetes.io/docs/concepts/services-networking/network-policies/#prerequisites).

The optional client pod has the exact label allowed by the policy. Both API
ingress and client egress permit TCP 8000. The API needs no outbound connections;
DNS egress stays denied. Use the Service IP so the test client needs no DNS rule.

```bash
kubectl apply -f deploy/kubernetes/smoke-client.yaml
kubectl -n platform-lab wait --for=condition=Ready pod/lab-client --timeout=90s
API_IP=$(kubectl -n platform-lab get service platform-engineering-lab -o jsonpath='{.spec.clusterIP}')
kubectl -n platform-lab exec lab-client -- curl --fail --max-time 5 "http://${API_IP}:8000/health"
```

Removing the client label makes the next request time out. Allow a few seconds
for the policy controller to reconcile the change.

```bash
kubectl -n platform-lab label pod lab-client platform-lab-client-
kubectl -n platform-lab exec lab-client -- curl --fail --max-time 5 "http://${API_IP}:8000/health"
kubectl -n platform-lab delete pod lab-client
```

The client image (`curlimages/curl`) is pulled from a public registry, so this
check needs internet access. The [Zarf package](../zarf/README.md) carries this
image too, so `make zarf-validate` serves it from the in-cluster registry instead.

## What the manifests express

- UID/GID 10001, no privilege escalation, all capabilities dropped,
  `RuntimeDefault` seccomp, and a read-only root filesystem.
- No service-account token mount. The API does not need Kubernetes API credentials.
- Startup/liveness `/health` and readiness `/ready` probes, CPU/memory/storage
  budgets, and a 16 MiB memory-backed writable `/tmp`.
- An internal ClusterIP Service; no public ingress or load balancer.
- Default-deny ingress/egress, with a labeled same-namespace client exception.

Labels express a network selection rule, not an authenticated user identity.
Namespace access/RBAC must prevent untrusted users from changing these labels.
The memory-backed `/tmp` counts toward the container memory limit. No RBAC role
is created because the workload does not call the Kubernetes API.
The `restricted:latest` namespace setting follows the cluster's current Pod
Security Standard; review it when upgrading Kubernetes. Consult the official
[Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
and [k3d image import](https://k3d.io/stable/usage/commands/k3d_image_import/).
