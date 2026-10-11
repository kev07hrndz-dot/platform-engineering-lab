# Kubernetes lab

This Kustomize base is a small, declarative deployment scaffold: one API, one
internal Service, a restricted namespace, and explicit network rules. CI renders
and validates the manifests; it does not deploy them or prove network isolation.

## Run locally with kind

Prerequisites: Docker running, `kind`, `kubectl`, and an available local port 8001.
Run these commands from the repository root. The named cluster is a disposable
lab; check your Kubernetes context before applying resources.

```bash
docker build -t platform-engineering-lab:dev .
kind create cluster --name platform-lab
kind load docker-image platform-engineering-lab:dev --name platform-lab
kubectl config use-context kind-platform-lab
kubectl kustomize deploy/kubernetes/base
kubectl apply -k deploy/kubernetes/base
kubectl -n platform-lab rollout status deployment/platform-engineering-lab --timeout=120s
kubectl -n platform-lab port-forward service/platform-engineering-lab 8001:8000 --address=127.0.0.1
```

In another terminal:

```bash
curl --fail http://127.0.0.1:8001/health
curl --fail http://127.0.0.1:8001/ready
```

The image uses `IfNotPresent`, so kind can use the image loaded locally. After
changing the application, rebuild/load it and restart the Deployment. Use unique
image tags or immutable digests for a real release.

## Check the allowed network path

NetworkPolicy requires an enforcing CNI or network-policy controller. Choose and
configure one before claiming isolation. Port-forward uses the Kubernetes API
and is useful for local access; it does not verify pod-to-pod policy behavior.
See the [Kubernetes NetworkPolicy prerequisites](https://kubernetes.io/docs/concepts/services-networking/network-policies/#prerequisites).

The optional client pod has the exact label allowed by the policy. Both API
ingress and client egress permit TCP 8000. The API needs no outbound connections;
DNS egress stays denied. Use the Service IP so the test client needs no DNS rule.

```bash
kubectl apply -f deploy/kubernetes/smoke-client.yaml
kubectl -n platform-lab wait --for=condition=Ready pod/lab-client --timeout=90s
API_IP=$(kubectl -n platform-lab get service platform-engineering-lab -o jsonpath='{.spec.clusterIP}')
kubectl -n platform-lab exec lab-client -- curl --fail --max-time 5 "http://${API_IP}:8000/health"
```

On a policy-enforcing cluster, removing the client label should make the next
request time out. Allow time for the controller to reconcile the change.

```bash
kubectl -n platform-lab label pod lab-client platform-lab-client-
kubectl -n platform-lab exec lab-client -- curl --fail --max-time 5 "http://${API_IP}:8000/health"
kubectl -n platform-lab label pod lab-client platform-lab-client=true
kubectl -n platform-lab delete pod lab-client
```

The client image is an optional public utility image; this procedure needs
registry access unless it is loaded beforehand. This is not an air-gapped demo.
Record cluster/CNI versions, allowed and denied results before describing the
policies as runtime-verified. Cleanup: `kind delete cluster --name platform-lab`.

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
and [kind image-loading guide](https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster).
