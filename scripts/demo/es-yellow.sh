#!/usr/bin/env bash
# es-yellow.sh - review test: Elasticsearch turns yellow (ElasticsearchClusterNotGreen).
#
#   bash scripts/demo/es-yellow.sh           scale Elasticsearch to 1 node -> YELLOW
#   bash scripts/demo/es-yellow.sh restore   back to 2 nodes -> GREEN
#
# Every index has one replica, kept on the other node. With one node the
# replicas have nowhere to live: all data is still there, but only once -
# that is exactly what yellow means. No data is lost.
# Expected: Firing after about 2 minutes, Resolved a few minutes after restore.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

health() {
  kubectl exec -n logging elasticsearch-0 -c elasticsearch -- \
    curl -s localhost:9200/_cluster/health | grep -o '"status":"[a-z]*"\|"number_of_nodes":[0-9]*' | tr '\n' ' '
  echo
}

if [[ "${1:-}" == "restore" ]]; then
  kubectl scale statefulset elasticsearch -n logging --replicas=2
  echo "Waiting for elasticsearch-1 (about 2-3 minutes)..."
  kubectl rollout status statefulset/elasticsearch -n logging --timeout=5m
  health
  echo "Replicas are copied back in a minute or two; then the status is green."
  exit 0
fi

kubectl scale statefulset elasticsearch -n logging --replicas=1
echo "Waiting for elasticsearch-1 to stop..."
kubectl wait --for=delete pod/elasticsearch-1 -n logging --timeout=90s >/dev/null 2>&1 || true
sleep 5
health
echo "Expected: ElasticsearchClusterNotGreen after ~2 min. Restore: bash scripts/demo/es-yellow.sh restore"
where_to_look