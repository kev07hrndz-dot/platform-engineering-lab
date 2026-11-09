#!/bin/sh
# Builds the Zarf package and deploys it to a fresh k3d cluster, then proves that
# every workload image is served from the in-cluster Zarf registry (not the host or
# a public registry) and that the same runtime controls hold as in k3d-validate.
# Zarf and kubectl both use a dedicated kubeconfig, so another cluster is never touched.
set -eu

cluster="${ZARF_CLUSTER:-zarf-lab}"
version="0.1.0"
image="platform-engineering-lab:$version"
ns="platform-lab"
registry="127.0.0.1:31999"
zarf="${ZARF:-zarf}"
mkdir -p build
KUBECONFIG="$(pwd)/build/kubeconfig-$cluster"
export KUBECONFIG
k() { kubectl "$@"; }
. "$(dirname "$0")/runtime-checks.sh"

cleanup() {
    k -n "$ns" delete pod lab-client --ignore-not-found --wait=false > /dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! k3d cluster list "$cluster" > /dev/null 2>&1; then
    echo "==> Creating k3d cluster '$cluster' (default kubeconfig left unchanged)"
    k3d cluster create "$cluster" --servers 1 --agents 0 --wait --timeout 180s \
        --kubeconfig-update-default=false --kubeconfig-switch-context=false
fi
k3d kubeconfig write "$cluster" --output "$KUBECONFIG" > /dev/null

echo "==> Building $image and the Zarf package"
docker build -q -t "$image" . > /dev/null
"$zarf" dev lint deploy/zarf --log-level warn > /dev/null
rm -f build/zarf-package-platform-engineering-lab-*-"$version".tar.zst
"$zarf" package create deploy/zarf --output build --confirm --log-level warn
package=$(ls build/zarf-package-platform-engineering-lab-*-"$version".tar.zst)
echo "    $package ($(du -h "$package" | cut -f1))"
"$zarf" package inspect images "$package" | sed 's/^/    /'

if ! k -n zarf get deployment zarf-docker-registry > /dev/null 2>&1; then
    cache="$HOME/.zarf-cache"
    if ! ls "$cache"/zarf-init-*.tar.zst > /dev/null 2>&1; then
        echo "==> Downloading the official Zarf init package for this Zarf version"
        mkdir -p "$cache"
        "$zarf" tools download-init --output-directory "$cache" --log-level warn
    fi
    echo "==> Initializing Zarf (registry and mutating agent) in '$cluster'"
    "$zarf" init --confirm --log-level warn
fi

echo "==> Deploying the package with the optional smoke-client component"
cleanup
"$zarf" package deploy "$package" --components=smoke-client --confirm --log-level warn > /dev/null
k -n "$ns" rollout status deployment/platform-engineering-lab --timeout=120s

echo "==> Checking that every workload image comes from the Zarf registry"
images=$(k -n "$ns" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}')
printf '%s\n' "$images" | while read -r ref; do
    case "$ref" in
        "$registry"/*) echo "    $ref" ;;
        *) echo "FAIL: $ref was not rewritten to the Zarf registry" >&2; exit 1 ;;
    esac
done

run_runtime_checks

server=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
printf '%s\n' "Zarf validation passed on k3d-$cluster ($server): packaged images from the in-cluster registry, rollout, endpoints, identity, allowed and denied network paths"
