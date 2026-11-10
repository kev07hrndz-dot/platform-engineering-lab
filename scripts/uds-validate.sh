#!/bin/sh
# Deploys the UDS flavor of the Zarf package, as a UDS bundle, onto a local
# UDS Core (slim dev) cluster and proves the platform integration:
# the UDS Operator reconciles the Package CR, generates the network policies,
# and routes https://platform-lab.uds.dev through the Istio tenant gateway.
# The same image-source and runtime checks as zarf-validate run afterwards.
set -eu

cluster="uds"                 # the uds-k3d package always names its cluster "uds"
core_version="${UDS_CORE_VERSION:-1.14.3}"
version="0.1.0"
image="platform-engineering-lab:$version"
ns="platform-lab"
registry="127.0.0.1:31999"
url="https://platform-lab.uds.dev"
uds="${UDS:-uds}"
mkdir -p build
KUBECONFIG="$(pwd)/build/kubeconfig-$cluster"
export KUBECONFIG
k() { kubectl "$@"; }
. "$(dirname "$0")/runtime-checks.sh"

cleanup() {
    k -n "$ns" delete pod lab-client probe-unlabeled probe-wrong-identity \
        --ignore-not-found --wait=false > /dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! k3d cluster list "$cluster" > /dev/null 2>&1; then
    echo "==> Deploying UDS Core $core_version (k3d-core-slim-dev); the first run takes 10-15 minutes"
    "$uds" deploy "k3d-core-slim-dev:$core_version" --confirm --log-level warn
fi
k3d kubeconfig write "$cluster" --output "$KUBECONFIG" > /dev/null

echo "==> Building $image, the uds-flavored Zarf package, and the UDS bundle"
docker build -q -t "$image" . > /dev/null
rm -f build/zarf-package-platform-engineering-lab-*-"$version"-uds.tar.zst build/uds-bundle-platform-engineering-lab-*-"$version".tar.zst
"$uds" zarf package create deploy/zarf --flavor uds --output build --confirm --log-level warn
"$uds" create deploy/uds --output build --confirm --log-level warn
bundle=$(ls build/uds-bundle-platform-engineering-lab-*-"$version".tar.zst)
echo "    $bundle ($(du -h "$bundle" | cut -f1))"

echo "==> Deploying the bundle (with the optional smoke-client component)"
cleanup
"$uds" deploy "$bundle" --confirm --log-level warn > /dev/null
k -n "$ns" rollout status deployment/platform-engineering-lab --timeout=180s

echo "==> Waiting for the UDS Operator to reconcile the Package CR"
attempt=0
until [ "$(k -n "$ns" get package platform-engineering-lab -o jsonpath='{.status.phase}')" = "Ready" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
        echo "FAIL: Package CR did not reach Ready" >&2
        k -n "$ns" get package platform-engineering-lab -o yaml >&2
        exit 1
    fi
    sleep 2
done
endpoints=$(k -n "$ns" get package platform-engineering-lab -o jsonpath='{.status.endpoints}')
policies=$(k -n "$ns" get package platform-engineering-lab -o jsonpath='{.status.networkPolicyCount}')
echo "    Package Ready, endpoints $endpoints, $policies generated NetworkPolicies"
for name in default-deny allow-lab-client-to-api allow-lab-client-egress; do
    if k -n "$ns" get networkpolicy "$name" > /dev/null 2>&1; then
        echo "FAIL: hand-written NetworkPolicy $name should not exist in the UDS flavor" >&2
        exit 1
    fi
done

check_registry_images
check_identity
check_allowed_path

# Ambient mode reuses ztunnel's HBONE connections, so relabeling a pod that is
# already connected does not cut it off. Fresh pods test each layer separately.
echo "==> Testing the denied paths with fresh pods"
start_probe_pod probe-unlabeled lab-client ""
expect_blocked probe-unlabeled "right identity, no label: blocked by NetworkPolicy"
start_probe_pod probe-wrong-identity default true
expect_blocked probe-wrong-identity "right label, default ServiceAccount: blocked by Istio AuthorizationPolicy"

echo "==> Testing ingress through the Istio tenant gateway"
attempt=0
until body=$(curl --fail --silent --max-time 5 "$url/health"); do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 15 ]; then
        echo "FAIL: $url/health is not reachable through the tenant gateway" >&2
        exit 1
    fi
    sleep 2
done
echo "    $url/health -> $body"

server=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
printf '%s\n' "UDS validation passed on k3d-$cluster ($server, UDS Core $core_version): Package Ready, generated policies, packaged images, identity, allowed path, label and identity denials, tenant-gateway ingress"
