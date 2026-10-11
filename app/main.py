from fastapi import FastAPI

app = FastAPI(
    title="Platform Engineering Lab API",
    description="Cloud-native API built as part of a DevSecOps platform engineering lab.",
    version="1.0.0",
)


@app.get("/", summary="Service identity")
def root():
    return {
        "message": "Platform Engineering Lab API",
        "status": "running"
    }


@app.get("/health", summary="Liveness: process can serve requests")
def health():
    return {
        "status": "healthy"
    }


@app.get("/ready", summary="Readiness: ready to receive traffic")
def ready():
    # This stateless demo has no database or external service to check.
    return {"status": "ready"}


@app.get("/info")
def info():
    return {
        "developer": "Kevin Hernandez",
        "project": "Platform Engineering Lab",
        "focus": [
            "DevSecOps",
            "Cloud",
            "Kubernetes",
            "Platform Engineering"
        ]
    }
