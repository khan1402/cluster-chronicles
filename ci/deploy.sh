#!/usr/bin/env bash
# deploy.sh - roll out ONE version of the app, or print the live version.
#
#   bash ci/deploy.sh <tag>      deploy <tag>: backend first, then frontend
#   bash ci/deploy.sh current    print the tag the frontend runs now (empty if none)
#
# Runs in the build pod's "tools" container as the jenkins-deployer
# ServiceAccount (rbac.yaml: may patch Deployments in "app", nothing else).
#
# Each "set image" starts a ROLLING UPDATE (strategy in the Deployments):
# a new pod starts, must pass its readiness probe, and only then is an old
# pod removed (maxUnavailable: 0). A broken version never gets traffic.
# If a rollout doesn't finish in time, this script fails -> Jenkins rolls back.
set -euo pipefail

NS="${APP_NAMESPACE:-app}"
REGISTRY_USER="${DOCKERHUB_USER:-zeek14}"
PREFIX="${IMAGE_PREFIX:-chronicles}"
TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

if [[ "${1:-}" == "current" ]]; then
  # The image in the Deployment is the source of truth: "zeek14/chronicles-frontend:abc1234" -> abc1234
  kubectl -n "$NS" get deployment frontend \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | awk -F: '{print $NF}' || true
  exit 0
fi

TAG="${1:?usage: deploy.sh <tag> | current}"

for component in backend frontend; do
  image="${REGISTRY_USER}/${PREFIX}-${component}:${TAG}"
  echo "=== Deploy ${component}: ${image} ==="
  kubectl -n "$NS" set image "deployment/${component}" "${component}=${image}"
  # Label this version, shown by: kubectl rollout history deployment/<name> -n app
  kubectl -n "$NS" annotate "deployment/${component}" --overwrite \
    kubernetes.io/change-cause="deploy ${TAG} (Jenkins build ${BUILD_NUMBER:-manual})"
  kubectl -n "$NS" rollout status "deployment/${component}" --timeout="$TIMEOUT"
done

echo "Version ${TAG} rolled out."