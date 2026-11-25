#!/usr/bin/env bash
# memory.sh - review test: node memory above 90% (NodeHighMemory).
#
#   bash scripts/demo/memory.sh [seconds]   hold for N seconds (default 240; 420 without demo mode)
#   bash scripts/demo/memory.sh stop        free it now
#
# The pod writes zeros into a RAM disk (emptyDir with medium: Memory) until
# about 91% of the node's RAM is used - just over the 90% threshold. The size
# comes from the node's own numbers, so it works on any VM size.
#
# Safety, learned the hard way (at 93% used together with the CPU demo, the
# node ran out of room for the API server):
#   - aims at 91%, not more, and must be run ALONE (not with cpu.sh)
#   - frees the memory BY ITSELF after the given time, even if kubectl can
#     no longer reach the cluster
#   - a memory limit stops the pod from ever taking more than planned
# Expected: Firing after 1 min in demo mode (5 min without), Resolved ~2 min
# after the memory is freed.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

ARG="${1:-240}"
if [[ "$ARG" == "stop" ]]; then
  stop_pod demo-memory; echo "Memory freed."; exit 0
fi
[[ "$ARG" =~ ^[0-9]+$ ]] || { echo "usage: bash scripts/demo/memory.sh [seconds|stop]" >&2; exit 1; }

if [[ "$(kubectl get pod demo-cpu -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; then
  echo "The CPU demo is still running - stop it first: bash scripts/demo/cpu.sh stop" >&2
  exit 1
fi

# Hard ceiling for the pod, from the node's total RAM (Kubernetes reports it in Ki).
TOTAL_KB="$(kubectl get node "$NODE" -o jsonpath='{.status.capacity.memory}' | sed 's/Ki$//')"
LIMIT_MI=$(( TOTAL_KB * 92 / 100 / 1024 ))   # hard ceiling: never more than 92% of the node

ensure_ns
stop_pod demo-memory
apply_pod "$(sed "s/__SECONDS__/$ARG/g; s/__LIMIT__/${LIMIT_MI}Mi/g" <<'EOT'
apiVersion: v1
kind: Pod
metadata:
  name: demo-memory
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: cluster-chronicles
spec:
  restartPolicy: Never
  containers:
    - name: fill
      image: busybox:1.36
      command: [sh, -c]
      args:
        - |
          total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
          avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
          fill_mb=$(( (avail - total * 9 / 100) / 1024 ))
          echo "Node RAM: $((total / 1024)) MB total, $((avail / 1024)) MB available"
          if [ "$fill_mb" -gt 0 ]; then
            echo "Filling $fill_mb MB (target: about 91% used), holding for __SECONDS__ s"
            dd if=/dev/zero of=/ram/fill bs=1M count="$fill_mb" 2>/dev/null
          else
            echo "Already above 91% - nothing to fill."
          fi
          sleep __SECONDS__
          rm -f /ram/fill
          echo "Memory freed by itself."
      resources:
        requests: {cpu: 50m, memory: 16Mi}
        limits: {memory: __LIMIT__}
      volumeMounts:
        - {name: ram, mountPath: /ram}
  volumes:
    - name: ram
      emptyDir: {medium: Memory}
EOT
)"
kubectl wait --for=condition=Ready pod/demo-memory -n "$NS" --timeout=60s >/dev/null
sleep 3
kubectl logs demo-memory -n "$NS"
echo "Expected: NodeHighMemory after 1 min in demo mode (5 min without). Frees itself after $ARG s."
where_to_look