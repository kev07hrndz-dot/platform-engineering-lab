#!/bin/sh
# Deploys the current code to a local k3d cluster and proves the runtime controls:
# rollout, real endpoint responses, non-root identity, and allowed/denied network paths.
# Every kubectl call names the k3d context, so another cluster is never touched.
set -eu

cluster="${K3D_CLUSTER:-platform-lab}"
image="platform-engineering-lab:dev"
ns="platform-lab"
ctx="k3d-$cluster"
k() { kubectl --context "$ctx" "$@"; }

cleanup() {
    k -n "$ns" delete pod lab-client --ignore-not-found --wait=false > /dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! k3d cluster list "$cluster" > /dev/null 2>&1; then
    echo "==> Creating k3d cluster '$cluster'"
    k3d cluster create "$cluster" --servers 1 --agents 0 --wait --timeout 180s
fi

echo "==> Building and importing $image (no registry involved)"
docker build -q -t "$image" . > /dev/null
k3d image import "$image" -c "$cluster" > /dev/null

echo "==> Applying manifests and waiting for rollout"
k apply -k deploy/kubernetes/base > /dev/null
k -n "$ns" rollout restart deployment/platform-engineering-lab > /dev/null
k -n "$ns" rollout status deployment/platform-engineering-lab --timeout=120s

echo "==> Checking runtime identity inside the API pod"
k -n "$ns" exec deployment/platform-engineering-lab -- python -c '
import errno, os
from pathlib import Path
assert os.getuid() == 10001, "Pod must run as UID 10001"
assert "CapEff:\t0000000000000000" in Path("/proc/self/status").read_text(), "Capabilities must be dropped"
try:
    Path("/app/write-test").write_text("test")
except OSError as error:
    assert error.errno == errno.EROFS, "Root filesystem must be read-only"
else:
    raise AssertionError("Root filesystem was writable")
print("    UID 10001, no capabilities, read-only root filesystem")
'

echo "==> Testing the allowed network path (labeled client)"
k apply -f deploy/kubernetes/smoke-client.yaml > /dev/null
k -n "$ns" wait --for=condition=Ready pod/lab-client --timeout=120s > /dev/null
api_ip=$(k -n "$ns" get service platform-engineering-lab -o jsonpath='{.spec.clusterIP}')
for route in health ready; do
    body=$(k -n "$ns" exec lab-client -- curl --fail --silent --max-time 5 "http://$api_ip:8000/$route")
    echo "    /$route -> $body"
done

echo "==> Testing the denied network path (label removed)"
k -n "$ns" label pod lab-client platform-lab-client- > /dev/null
attempt=0
while k -n "$ns" exec lab-client -- curl --fail --silent --max-time 3 "http://$api_ip:8000/health" > /dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 10 ]; then
        echo "FAIL: unlabeled client still reaches the API; NetworkPolicy is not enforced" >&2
        exit 1
    fi
    sleep 2
done
echo "    unlabeled client blocked by NetworkPolicy"

server=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
printf '%s\n' "k3d validation passed on $ctx ($server): rollout, endpoints, identity, allowed and denied network paths"
