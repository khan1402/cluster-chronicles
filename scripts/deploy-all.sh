#!/usr/bin/env bash
# deploy-all.sh - install or update EVERYTHING in the cluster with one command.
#
# Runs on the laptop (WSL), from anywhere in the repo, with kubectl connected
# to the cluster:
#   bash scripts/deploy-all.sh
#
# The cluster itself (Minikube, ingress and metrics-server addons) comes from
# scripts/setup-cluster.sh, run once on the VM. This script deploys everything
# that runs INSIDE the cluster, in dependency order:
#
#    1. namespaces (with Pod Security levels)
#    2. storage (StorageClass + PersistentVolumes)
#    3. secrets (from security/secrets/secrets.env, never committed)
#    4. app (backend, frontend, HPA)
#    5. Jenkins (RBAC, config as code, StatefulSet)
#    6. monitoring (Helm chart, ServiceMonitors, alert rules, dashboards)
#    7. logging (Elasticsearch, setup Job, exporter, Fluent Bit, Kibana, dashboards)
#    8. ingress (all web addresses)
#    9. network policies (last, once everything is running)
#
# Safe to run again at any time (idempotent): "kubectl apply" and
# "helm upgrade --install" only change what differs. Two special cases:
#   - Jobs can't be changed once created, so they are deleted and re-created.
#   - The app image tag is set by Jenkins (kubectl set image). Re-applying
#     deployment.yaml would roll the app back to the tag written in the file,
#     so the LIVE image is kept.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# kube-prometheus-stack chart version. Empty = keep the version already
# installed (or the latest one on a fresh cluster).
KPS_CHART_VERSION=""

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m    ok:\033[0m %s\n' "$1"; }

# --- 0. Pre-checks ----------------------------------------------------------------------
step "0/9 Pre-checks"
for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool is not installed"; exit 1; }
done
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: kubectl can't reach the cluster"; exit 1; }
kubectl get namespace ingress-nginx >/dev/null 2>&1 \
  || { echo "ERROR: ingress addon missing - run scripts/setup-cluster.sh on the VM first"; exit 1; }
ok "kubectl, helm and the cluster are ready"

# --- 1. Namespaces ----------------------------------------------------------------------
step "1/9 Namespaces"
kubectl apply -f manifests/namespaces/namespaces.yaml

# --- 2. Storage -------------------------------------------------------------------------
step "2/9 Storage"
kubectl apply -f manifests/storage/storageclass.yaml
kubectl apply -f manifests/storage/persistent-volumes.yaml

# --- 3. Secrets -------------------------------------------------------------------------
step "3/9 Secrets"
if [[ -f security/secrets/secrets.env ]]; then
  bash scripts/create-secrets.sh
else
  # No local file: fine only if the Secrets already exist in the cluster.
  for s in cicd/jenkins-secrets cicd/dockerhub-push monitoring/grafana-admin monitoring/alertmanager-slack; do
    kubectl get secret "${s#*/}" -n "${s%/*}" >/dev/null 2>&1 \
      || { echo "ERROR: Secret $s missing and security/secrets/secrets.env not found"; exit 1; }
  done
  ok "secrets.env not found, but all 4 Secrets already exist - kept as they are"
fi

# --- 4. App -----------------------------------------------------------------------------
step "4/9 App (backend + frontend)"
# apply_keep_image <name>: apply manifests/<name>/deployment.yaml but keep the
# image tag that is running now (Jenkins owns the tag, not this file).
apply_keep_image() {
  local name="$1" file="manifests/$1/deployment.yaml" live
  live="$(kubectl get deployment "$name" -n app \
          -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ -n "$live" ]]; then
    sed -E "s#^([[:space:]]*image:[[:space:]]*).*chronicles-${name}.*#\1${live}#" "$file" | kubectl apply -f -
    ok "$name keeps its live image $live"
  else
    kubectl apply -f "$file"
  fi
}
kubectl apply -f manifests/backend/service.yaml
apply_keep_image backend
kubectl apply -f manifests/frontend/configmap.yaml
kubectl apply -f manifests/frontend/service.yaml
apply_keep_image frontend
kubectl apply -f manifests/frontend/hpa.yaml

# --- 5. Jenkins -------------------------------------------------------------------------
step "5/9 Jenkins"
kubectl apply -f manifests/cicd/serviceaccount.yaml
kubectl apply -f manifests/cicd/rbac.yaml
kubectl apply -f manifests/cicd/pvc.yaml
kubectl apply -f manifests/cicd/service.yaml
kubectl apply -f manifests/cicd/jenkins-casc.yaml
kubectl apply -f manifests/cicd/statefulset.yaml

# --- 6. Monitoring ----------------------------------------------------------------------
step "6/9 Monitoring (kube-prometheus-stack)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
if [[ -z "$KPS_CHART_VERSION" ]]; then
  KPS_CHART_VERSION="$(helm list -n monitoring -f '^kps$' -o json \
    | grep -o '"chart":"kube-prometheus-stack-[^"]*"' | sed 's/.*stack-//; s/"//' || true)"
fi
version_flag=()
[[ -n "$KPS_CHART_VERSION" ]] && version_flag=(--version "$KPS_CHART_VERSION")
echo "    chart version: ${KPS_CHART_VERSION:-latest}"
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --namespace monitoring -f manifests/monitoring/values.yaml "${version_flag[@]}" \
  --wait --timeout 10m
kubectl apply -f manifests/monitoring/servicemonitors.yaml
kubectl apply -f manifests/monitoring/alert-rules.yaml
kubectl apply -f manifests/monitoring/dashboards/

# --- 7. Logging -------------------------------------------------------------------------
step "7/9 Logging (EFK)"
kubectl apply -f manifests/logging/elasticsearch.yaml
echo "    waiting for Elasticsearch (2 nodes, up to 10 min)..."
kubectl rollout status statefulset/elasticsearch -n logging --timeout=10m

kubectl delete job elasticsearch-setup -n logging --ignore-not-found
kubectl apply -f manifests/logging/elasticsearch-ilm-job.yaml
kubectl wait --for=condition=complete job/elasticsearch-setup -n logging --timeout=5m
ok "ILM policy and index template are in place"

kubectl apply -f manifests/logging/elasticsearch-exporter.yaml
kubectl apply -f manifests/logging/fluent-bit.yaml
kubectl apply -f manifests/logging/kibana.yaml
echo "    waiting for Kibana (up to 10 min)..."
kubectl rollout status deployment/kibana -n logging --timeout=10m

kubectl apply -f manifests/logging/kibana-dashboards/dashboards-configmap.yaml
kubectl delete job kibana-dashboards-import -n logging --ignore-not-found
kubectl apply -f manifests/logging/kibana-dashboards/import-job.yaml
kubectl wait --for=condition=complete job/kibana-dashboards-import -n logging --timeout=5m
ok "Kibana dashboards imported"

# --- 8. Ingress -------------------------------------------------------------------------
step "8/9 Ingress"
kubectl apply -f manifests/ingress/ingress.yaml

# --- 9. Network policies ----------------------------------------------------------------
step "9/9 Network policies"
kubectl apply -f security/network-policies/

# --- Wait until everything is up ------------------------------------------------------
step "Waiting for all workloads"
kubectl rollout status deployment/backend  -n app --timeout=5m
kubectl rollout status deployment/frontend -n app --timeout=5m
kubectl rollout status daemonset/fluent-bit -n logging --timeout=5m
kubectl rollout status deployment/elasticsearch-exporter -n logging --timeout=5m
echo "    waiting for Jenkins (plugins download on first start, up to 15 min)..."
kubectl rollout status statefulset/jenkins -n cicd --timeout=15m

cat <<'URLS'

All deployed. Web addresses:
  App           http://192.168.0.122/
  Jenkins       http://jenkins.192.168.0.122.nip.io/
  Grafana       http://grafana.192.168.0.122.nip.io/
  Prometheus    http://prometheus.192.168.0.122.nip.io/
  Alertmanager  http://alertmanager.192.168.0.122.nip.io/
  Kibana        http://kibana.192.168.0.122.nip.io/

Next: bash scripts/validate.sh
URLS