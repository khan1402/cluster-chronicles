#!/usr/bin/env bash
# create-secrets.sh - create or update the Kubernetes Secrets from a LOCAL file.
#
# Runs on the laptop (WSL), with kubectl connected to the cluster:
#   bash scripts/create-secrets.sh
#
# Reads security/secrets/secrets.env (never committed). Values are never
# printed and never passed on the command line.
#
# Rotation: change a value in secrets.env, run this script again, then restart
# the component that uses it:
#   kubectl -n cicd rollout restart statefulset/jenkins
#   kubectl -n monitoring rollout restart deployment/grafana
#   kubectl -n monitoring rollout restart statefulset/alertmanager-kps-alertmanager
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$ROOT/security/secrets/secrets.env}"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found - copy secrets.env.example first"; exit 1; }

if [[ "$(stat -c %a "$ENV_FILE")" != "600" ]]; then
  echo "WARNING: $ENV_FILE should only be readable by you: chmod 600 $ENV_FILE"
fi

# Load the values (set -a exports every variable the file defines).
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

required=(JENKINS_ADMIN_PASSWORD GITEA_USERNAME GITEA_TOKEN DOCKERHUB_USERNAME DOCKERHUB_TOKEN
          SLACK_WEBHOOK_URL GRAFANA_ADMIN_PASSWORD)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { echo "ERROR: $name is empty in $ENV_FILE"; exit 1; }
done

# Every value goes in through <(printf ...): a temporary file descriptor, so
# it never shows up on the command line or in 'ps'.
# --server-side: no copy of the values in a last-applied-configuration annotation.
apply() { kubectl apply --server-side --force-conflicts -f -; }

# --- cicd ---------------------------------------------------------------------------------
echo "==> cicd/jenkins-secrets (admin password, Gitea login, Slack webhook)"
kubectl create secret generic jenkins-secrets --namespace cicd \
  --from-file=JENKINS_ADMIN_PASSWORD=<(printf '%s' "$JENKINS_ADMIN_PASSWORD") \
  --from-file=GITEA_USERNAME=<(printf '%s' "$GITEA_USERNAME") \
  --from-file=GITEA_TOKEN=<(printf '%s' "$GITEA_TOKEN") \
  --from-file=SLACK_WEBHOOK_URL=<(printf '%s' "$SLACK_WEBHOOK_URL") \
  --dry-run=client -o yaml | apply

# Docker login file, the same format "docker login" writes.
# Kaniko reads it from /kaniko/.docker/config.json.
echo "==> cicd/dockerhub-push (Docker Hub login for Kaniko)"
AUTH="$(printf '%s:%s' "$DOCKERHUB_USERNAME" "$DOCKERHUB_TOKEN" | base64 -w0)"
kubectl create secret generic dockerhub-push --namespace cicd \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=<(printf '{"auths":{"https://index.docker.io/v1/":{"auth":"%s"}}}' "$AUTH") \
  --dry-run=client -o yaml | apply

# --- monitoring ---------------------------------------------------------------------------
# Grafana reads its admin login from this Secret (values.yaml: admin.existingSecret).
echo "==> monitoring/grafana-admin (Grafana admin login)"
kubectl create secret generic grafana-admin --namespace monitoring \
  --from-file=admin-user=<(printf '%s' "admin") \
  --from-file=admin-password=<(printf '%s' "$GRAFANA_ADMIN_PASSWORD") \
  --dry-run=client -o yaml | apply

# Alertmanager reads the webhook from a FILE:
# /etc/alertmanager/secrets/alertmanager-slack/url (values.yaml: slack_api_url_file).
echo "==> monitoring/alertmanager-slack (Slack webhook for alerts)"
kubectl create secret generic alertmanager-slack --namespace monitoring \
  --from-file=url=<(printf '%s' "$SLACK_WEBHOOK_URL") \
  --dry-run=client -o yaml | apply

echo "Done. Values are stored only in the cluster - check with:"
echo "  kubectl get secrets -n cicd"
echo "  kubectl get secrets -n monitoring"