from fastapi import FastAPI

app = FastAPI(
    title="Platform Engineering Lab API",
    description="Cloud-native API built as part of a DevSecOps platform engineering lab.",
    version="1.0.0",
)


@app.get("/")
def root():
    return {
        "message": "Platform Engineering Lab API",
        "status": "running"
    }


@app.get("/health")
def health():
    return {
        "status": "healthy"
    }


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
