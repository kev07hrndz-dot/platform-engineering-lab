#!/bin/sh
# A separate Compose project and random localhost port protect an existing dev server.
set -eu
project="platform-lab-smoke-$$"
export API_PORT=0
cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        docker compose -p "$project" logs api
    fi
    docker compose -p "$project" down --remove-orphans
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker compose -p "$project" up --build --wait --wait-timeout 90
address=$(docker compose -p "$project" port api 8000)
for route in health ready info openapi.json docs; do
    curl --fail --silent --show-error "http://$address/$route" > /dev/null
done
curl --fail --silent --show-error "http://$address/health" |
    "${PYTHON:-python3}" -c 'import json,sys; assert json.load(sys.stdin) == {"status": "healthy"}'
curl --fail --silent --show-error "http://$address/ready" |
    "${PYTHON:-python3}" -c 'import json,sys; assert json.load(sys.stdin) == {"status": "ready"}'
docker compose -p "$project" exec -T api python -c '
import errno, importlib.util, os
from pathlib import Path
assert os.getuid() == 10001, "Container must run as UID 10001"
status = Path("/proc/self/status").read_text()
assert "CapEff:\t0000000000000000" in status, "Capabilities must be dropped"
assert "NoNewPrivs:\t1" in status, "No new privileges must be enabled"
assert importlib.util.find_spec("pip") is None, "Build-time pip must be removed"
assert importlib.util.find_spec("ensurepip") is None, "Bundled installer must be removed"
try:
    Path("/app/write-test").write_text("test")
except OSError as error:
    assert error.errno == errno.EROFS, "Root filesystem must be read-only"
else:
    raise AssertionError("Root filesystem was writable")
print("Runtime controls verified: UID 10001, no capabilities, no new privileges, read-only root")
'
printf '%s\n' 'Docker smoke passed: /health, /ready, /info, /openapi.json, /docs'
