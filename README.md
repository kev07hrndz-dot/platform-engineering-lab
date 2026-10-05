code .
# Platform Engineering Lab

A hands-on DevSecOps and cloud-native platform engineering project.

## Goal

Build and secure a production-style application platform using:

- Python
- Docker
- Kubernetes
- AWS
- Terraform
- GitHub Actions
- CI/CD
- DevSecOps
- Helm
- Prometheus
- Grafana
- Defense Unicorns UDS
- Zarf

## Current Status

🚧 Project in progress

## Run with Docker

Start Docker Desktop, then run from the project folder:

```bash
docker compose up --build -d
```

- API: http://127.0.0.1:8001/
- Health: http://127.0.0.1:8001/health
- Interactive docs: http://127.0.0.1:8001/docs

Docker uses port 8001 on your computer and port 8000 inside the container.
This allows the local development server on port 8000 to keep running.
The container runs as a non-root user and checks `/health` automatically.

View logs and status:

```bash
docker compose logs -f api
docker compose ps
```

Stop and remove the project container:

```bash
docker compose down
```

After changing code or dependencies, run `docker compose up --build -d` again.
The image includes the app and installed dependencies; it does not use your local `.venv`.
