#!/usr/bin/env bash
# cleanup.sh - undo every demo at once.
#
#   bash scripts/demo/cleanup.sh
#
# Removes the disk file, restores Elasticsearch to 2 nodes and the Fluent Bit
# network policy, turns demo mode off and deletes the whole "demo" namespace
# (CPU, memory, crash, pending, load and API server pods). Safe to run any time.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

echo "== Disk file"
node_run demo-disk-cleanup 'rm -f /var/demo-disk-fill.img; df -h / | tail -1'

echo "== Elasticsearch back to 2 nodes"
kubectl scale statefulset elasticsearch -n logging --replicas=2

echo "== Network policies as in Git"
kubectl apply -f security/network-policies/logging.yaml >/dev/null

echo "== Demo mode off"
kubectl apply -f manifests/monitoring/alert-rules.yaml

echo "== Delete the demo namespace (all demo pods)"
kubectl delete namespace "$NS" --ignore-not-found --wait=false

echo "Done. Alerts resolve over the next few minutes (PodFrequentRestarts: up to 15)."