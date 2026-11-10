# Shared runtime checks, sourced by the k3d, Zarf, and UDS validation scripts.
# Callers define k() (kubectl bound to one cluster) and ns, and deploy the
# labeled lab-client pod before calling run_runtime_checks.

# Fails unless every container image in the namespace was rewritten to the
# in-cluster Zarf registry (callers set registry).
check_registry_images() {
    echo "==> Checking that every workload image comes from the Zarf registry"
    images=$(k -n "$ns" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}')
    printf '%s\n' "$images" | while read -r ref; do
        case "$ref" in
            "$registry"/*) echo "    $ref" ;;
            *) echo "FAIL: $ref was not rewritten to the Zarf registry" >&2; exit 1 ;;
        esac
    done
}

check_identity() {
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
}

api_ip() {
    k -n "$ns" get service platform-engineering-lab -o jsonpath='{.spec.clusterIP}'
}

check_allowed_path() {
    echo "==> Testing the allowed network path (labeled client)"
    k -n "$ns" wait --for=condition=Ready pod/lab-client --timeout=120s > /dev/null
    ip=$(api_ip)
    for route in health ready; do
        body=$(k -n "$ns" exec lab-client -- curl --fail --silent --max-time 5 "http://$ip:8000/$route")
        echo "    /$route -> $body"
    done
}

# expect_blocked POD MESSAGE: fails unless requests from POD stop reaching the API.
expect_blocked() {
    ip=$(api_ip)
    attempt=0
    while k -n "$ns" exec "$1" -- curl --fail --silent --max-time 3 "http://$ip:8000/health" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 10 ]; then
            echo "FAIL: $1 still reaches the API" >&2
            exit 1
        fi
        sleep 2
    done
    echo "    $2"
}

check_denied_label_removed() {
    echo "==> Testing the denied network path (label removed)"
    k -n "$ns" label pod lab-client platform-lab-client- > /dev/null
    expect_blocked lab-client "unlabeled client blocked by NetworkPolicy"
}

# start_probe_pod NAME SERVICE_ACCOUNT LABEL_VALUE: a fresh curl pod with the
# same hardened spec as lab-client; an empty LABEL_VALUE omits the client label.
start_probe_pod() {
    label=""
    if [ -n "$3" ]; then
        label="platform-lab-client: \"$3\""
    fi
    k apply -f - > /dev/null <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $ns
  labels: {$label}
spec:
  serviceAccountName: $2
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: docker.io/curlimages/curl:8.21.0
      imagePullPolicy: IfNotPresent
      command: [sleep, "600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests: {cpu: 10m, memory: 16Mi}
        limits: {cpu: 100m, memory: 32Mi}
MANIFEST
    k -n "$ns" wait --for=condition=Ready "pod/$1" --timeout=120s > /dev/null
}

run_runtime_checks() {
    check_identity
    check_allowed_path
    check_denied_label_removed
}
