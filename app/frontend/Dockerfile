# Start from a lightweight official Python image
FROM python:3.12-slim

# No .pyc files (the container filesystem is read-only in Kubernetes)
# and log lines go straight to stdout without buffering
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Copy dependency list first (before the code) so Docker can cache this layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Non-root user with a FIXED UID/GID (checked by the Deployment: runAsUser: 10001)
RUN groupadd --gid 10001 appuser \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin appuser

# Copy the application code (main.py, templates/, static/) - owned by root, read-only for the app
COPY . .

USER 10001

# 8080, not 80: only root may open ports below 1024. Users still use port 80 -
# the Service maps port 80 to 8080 inside the pod.
EXPOSE 8080

# Version label, passed in at build time: docker build --build-arg APP_VERSION=3f2a1bc
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

# Command that runs when the container starts
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]