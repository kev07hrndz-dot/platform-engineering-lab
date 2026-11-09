# Shared runtime checks, sourced by k3d-validate.sh and zarf-validate.sh.
# Callers define k() (kubectl bound to one context) and ns, and deploy the
# labeled lab-client pod before calling run_runtime_checks.

run_runtime_checks() {
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
}
