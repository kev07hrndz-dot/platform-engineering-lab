from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "deploy/kubernetes/base"


def read_yaml(path):
    return yaml.safe_load(path.read_text())


def test_compose_enforces_runtime_restrictions():
    api = read_yaml(ROOT / "compose.yaml")["services"]["api"]
    assert api["read_only"] is True
    assert api["cap_drop"] == ["ALL"]
    assert api["security_opt"] == ["no-new-privileges:true"]
    assert api["ports"] == ["127.0.0.1:${API_PORT:-8001}:8000"]
    assert api["pids_limit"] <= 100
    assert api["mem_limit"] == "256m"


def test_kubernetes_identity_and_filesystem_are_restricted():
    pod = read_yaml(BASE / "deployment.yaml")["spec"]["template"]["spec"]
    assert pod["automountServiceAccountToken"] is False
    context = pod["securityContext"]
    assert context["runAsNonRoot"] is True
    assert context["runAsUser"] == context["runAsGroup"] == 10001
    assert context["seccompProfile"]["type"] == "RuntimeDefault"
    container = pod["containers"][0]
    assert container["securityContext"] == {
        "allowPrivilegeEscalation": False,
        "readOnlyRootFilesystem": True,
        "capabilities": {"drop": ["ALL"]},
    }
    assert pod["volumes"][0]["emptyDir"]["sizeLimit"] == "16Mi"


def test_probes_match_api_contract_and_resource_limits_exist():
    pod = read_yaml(BASE / "deployment.yaml")["spec"]["template"]["spec"]
    container = pod["containers"][0]
    assert container["livenessProbe"]["httpGet"] == {"path": "/health", "port": "http"}
    assert container["readinessProbe"]["httpGet"] == {"path": "/ready", "port": "http"}
    assert container["startupProbe"]["httpGet"]["path"] == "/health"
    assert {"cpu", "memory"} <= container["resources"]["limits"].keys()
    service = read_yaml(BASE / "service.yaml")
    assert service["spec"]["type"] == "ClusterIP"
    assert service["spec"]["selector"] == read_yaml(BASE / "deployment.yaml")["spec"]["selector"]["matchLabels"]


def test_network_policies_default_deny_and_limit_client_access():
    policies = {
        policy["metadata"]["name"]: policy["spec"]
        for policy in yaml.safe_load_all((BASE / "networkpolicy.yaml").read_text())
    }
    assert policies["default-deny"] == {
        "podSelector": {}, "policyTypes": ["Ingress", "Egress"]
    }
    ingress = policies["allow-lab-client-to-api"]["ingress"]
    assert ingress == [{
        "from": [{"podSelector": {"matchLabels": {"platform-lab-client": "true"}}}],
        "ports": [{"protocol": "TCP", "port": 8000}],
    }]
    egress = policies["allow-lab-client-egress"]["egress"]
    assert egress == [{
        "to": [{"podSelector": {"matchLabels": {
            "app.kubernetes.io/name": "platform-engineering-lab"
        }}}],
        "ports": [{"protocol": "TCP", "port": 8000}],
    }]
    namespace = read_yaml(BASE / "namespace.yaml")
    assert namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "restricted"
