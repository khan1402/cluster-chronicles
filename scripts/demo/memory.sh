#!/usr/bin/env bash
# memory.sh - review test: node memory above 90% for 5 minutes (NodeHighMemory).
#
#   bash scripts/demo/memory.sh        fill RAM until about 93% is used
#   bash scripts/demo/memory.sh stop   free it again
#
# The pod writes zeros into a RAM disk (emptyDir with medium: Memory). The size
# is calculated from the node's own numbers, so it works on any VM size and
# always leaves about 7% free (well above the kubelet's eviction limit).
# Expected: Firing after 5 min (1 min in demo mode), Resolved ~2 min after stop.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

if [[ "${1:-}" == "stop" ]]; then
  stop_pod demo-memory; echo "Memory freed."; exit 0
fi

ensure_ns
stop_pod demo-memory
apply_pod "$(cat <<'EOT'
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
          fill_mb=$(( (avail - total * 7 / 100) / 1024 ))
          echo "Node RAM: $((total / 1024)) MB total, $((avail / 1024)) MB available"
          if [ "$fill_mb" -gt 0 ]; then
            echo "Filling $fill_mb MB..."
            dd if=/dev/zero of=/ram/fill bs=1M count="$fill_mb" 2>/dev/null
            echo "Filled. Now about 93% of the node's RAM is used."
          else
            echo "Already above 93% - nothing to fill."
          fi
          sleep 3600
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
echo "Expected: NodeHighMemory after 5 min (1 min in demo mode). Free it: bash scripts/demo/memory.sh stop"
where_to_look