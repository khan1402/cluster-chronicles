#!/usr/bin/env bash
# cpu.sh - review test: node CPU above 80% for 5 minutes (NodeHighCPU).
#
#   bash scripts/demo/cpu.sh [seconds]   start (default 420 s = 7 minutes)
#   bash scripts/demo/cpu.sh stop        stop early
#
# One pod keeps EVERY core of the node busy. It has no CPU request, so it gets
# the lowest priority: the real pods still get CPU first when they need it.
# Expected: alert Pending at once, Firing after 5 min (1 min in demo mode),
# Resolved about 2 minutes after the load stops.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

ARG="${1:-420}"
if [[ "$ARG" == "stop" ]]; then
  stop_pod demo-cpu; echo "CPU load stopped."; exit 0
fi
[[ "$ARG" =~ ^[0-9]+$ ]] || { echo "usage: bash scripts/demo/cpu.sh [seconds|stop]" >&2; exit 1; }

ensure_ns
stop_pod demo-cpu
apply_pod "$(sed "s/__SECONDS__/$ARG/g" <<'EOT'
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
          echo "Burning all $(nproc) cores for __SECONDS__ s"
          for i in $(seq "$(nproc)"); do timeout __SECONDS__ sh -c 'while :; do :; done' & done
          wait
          echo "Done"
EOT
)"
kubectl wait --for=condition=Ready pod/demo-cpu -n "$NS" --timeout=60s >/dev/null
kubectl logs demo-cpu -n "$NS"
echo "Expected: NodeHighCPU after 5 min (1 min in demo mode). Stop early: bash scripts/demo/cpu.sh stop"
where_to_look