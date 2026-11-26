#!/usr/bin/env bash
# fluentbit-errors.sh - review test: Fluent Bit can't deliver logs (FluentBitOutputErrors).
#
#   bash scripts/demo/fluentbit-errors.sh           cut Fluent Bit off from Elasticsearch
#   bash scripts/demo/fluentbit-errors.sh restore   reconnect it
#
# Uses the network policies: Fluent Bit is removed from the list of pods that
# may talk to Elasticsearch, and restarted so it has to open new connections.
# Every delivery now times out and is retried. Logs keep piling up on the node
# and are sent after "restore" (lines older than 5 failed retries are dropped).
# Expected: Firing after about 3-4 minutes, Resolved ~5 minutes after restore.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

if [[ "${1:-}" == "restore" ]]; then
  kubectl apply -f security/network-policies/logging.yaml >/dev/null
  echo "Network policy restored: Fluent Bit may reach Elasticsearch again."
  kubectl rollout restart daemonset/fluent-bit -n logging >/dev/null
  kubectl rollout status daemonset/fluent-bit -n logging --timeout=2m
  exit 0
fi

kubectl patch networkpolicy elasticsearch-clients -n logging --type=json \
  -p '[{"op":"replace","path":"/spec/podSelector/matchExpressions/0/values","value":["kibana","elasticsearch-exporter","elasticsearch-setup"]}]' >/dev/null
echo "Network policy changed: Fluent Bit may NOT reach Elasticsearch any more."
kubectl rollout restart daemonset/fluent-bit -n logging >/dev/null
kubectl rollout status daemonset/fluent-bit -n logging --timeout=2m
echo "See the failures:  kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=5"
echo "Expected: FluentBitOutputErrors after ~3-4 min. Restore: bash scripts/demo/fluentbit-errors.sh restore"
where_to_look