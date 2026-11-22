# Start from a lightweight Python image
FROM python:3.12-slim

# No .pyc files (the container filesystem is read-only in Kubernetes)
# and log lines go straight to stdout without buffering
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Copy dependency list first (before the code) so Docker can cache this layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Non-root user with a FIXED UID/GID. The Deployment checks this number
# (runAsUser: 10001), and the "app" namespace refuses containers that run as root.
RUN groupadd --gid 10001 appuser \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin appuser

# The code stays owned by root: the app can read it, but not change it
COPY . .

USER 10001

# Document which port this container listens on
EXPOSE 3000

# Version label, passed in at build time: docker build --build-arg APP_VERSION=3f2a1bc
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

# Command that runs when the container starts
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3000"]