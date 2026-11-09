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
. "$(dirname "$0")/runtime-checks.sh"

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

k apply -f deploy/kubernetes/smoke-client.yaml > /dev/null
run_runtime_checks

server=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
printf '%s\n' "k3d validation passed on $ctx ($server): rollout, endpoints, identity, allowed and denied network paths"
