#!/usr/bin/env bash
# cpu.sh - review test: node CPU above 80% (NodeHighCPU).
#
#   bash scripts/demo/cpu.sh [seconds]   start (default 240 s; use 420 without demo mode)
#   bash scripts/demo/cpu.sh stop        stop early
#
# One pod keeps the node's cores busy, but a CPU LIMIT of 88% of the node
# caps it: the rest (2 of 16 cores here) always stays free for the API
# server, Prometheus and the app. Together with the normal load the node
# sits at about 90% - just over the 80% threshold, never at 100%.
# It stops by itself after the given time, even if nobody runs "stop".
# Expected: Firing after 1 min in demo mode (5 min without), Resolved ~2 min
# after the load ends.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

ARG="${1:-240}"
if [[ "$ARG" == "stop" ]]; then
  stop_pod demo-cpu; echo "CPU load stopped."; exit 0
fi
[[ "$ARG" =~ ^[0-9]+$ ]] || { echo "usage: bash scripts/demo/cpu.sh [seconds|stop]" >&2; exit 1; }

CORES="$(kubectl get node "$NODE" -o jsonpath='{.status.capacity.cpu}')"
LIMIT_M=$(( CORES * 880 ))          # 88% of the node, in millicores

ensure_ns
stop_pod demo-cpu
apply_pod "$(sed "s/__SECONDS__/$ARG/g; s/__LIMIT__/${LIMIT_M}m/g" <<'EOT'
apiVersion: v1
kind: Pod
metadata:
  name: demo-cpu
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: cluster-chronicles
spec:
  restartPolicy: Never
  containers:
    - name: burn
      image: busybox:1.36
      command: [sh, -c]
      args:
        - |
          echo "Burning $(nproc) loops for __SECONDS__ s, capped at __LIMIT__ CPU"
          for i in $(seq "$(nproc)"); do timeout __SECONDS__ sh -c 'while :; do :; done' & done
          wait
          echo "Done"
      resources:
        requests: {cpu: 100m, memory: 16Mi}
        limits: {cpu: __LIMIT__, memory: 64Mi}
EOT
)"
kubectl wait --for=condition=Ready pod/demo-cpu -n "$NS" --timeout=60s >/dev/null
kubectl logs demo-cpu -n "$NS"
echo "Expected: NodeHighCPU after 1 min in demo mode (5 min without). Stops by itself after $ARG s."
where_to_look