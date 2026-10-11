from fastapi.testclient import TestClient

from app.main import app


client = TestClient(app)


def test_service_and_health_contracts():
    for path, expected in (
        ("/", {"message": "Platform Engineering Lab API", "status": "running"}),
        ("/health", {"status": "healthy"}),
        ("/ready", {"status": "ready"}),
    ):
        response = client.get(path)
        assert response.status_code == 200
        assert response.json() == expected


def test_info_preserves_project_identity():
    response = client.get("/info")
    assert response.status_code == 200
    assert response.json()["developer"] == "Kevin Hernandez"
    assert "DevSecOps" in response.json()["focus"]


def test_openapi_exposes_operational_endpoints():
    response = client.get("/openapi.json")
    assert response.status_code == 200
    paths = response.json()["paths"]
    assert all(path in paths for path in ("/", "/health", "/ready", "/info"))
    docs = client.get("/docs")
    assert docs.status_code == 200
    assert "swagger-ui" in docs.text


def test_unknown_routes_fail_without_debug_traceback():
    response = client.get("/missing")
    assert response.status_code == 404
    assert response.json() == {"detail": "Not Found"}
