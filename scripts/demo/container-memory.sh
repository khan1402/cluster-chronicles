#!/usr/bin/env bash
# container-memory.sh - review test: a container near its memory limit (ContainerMemoryNearLimit).
#
#   bash scripts/demo/container-memory.sh        start a pod that uses 85% of its limit
#   bash scripts/demo/container-memory.sh stop   delete it
#
# The container has a 100 MiB limit and puts 85 MiB in a RAM disk, which
# counts as the container's own memory. Above 100% it would be OOM-killed;
# 85% stays below that but above the 80% alert threshold.
# Expected: Firing after about 1-2 minutes, Resolved ~1 minute after stop.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

if [[ "${1:-}" == "stop" ]]; then
  stop_pod demo-memory-limit; echo "Pod deleted."; exit 0
fi

ensure_ns
stop_pod demo-memory-limit
apply_pod "$(cat <<'EOT'
apiVersion: v1
kind: Pod
metadata:
  name: demo-memory-limit
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
          dd if=/dev/zero of=/ram/fill bs=1M count=85 2>/dev/null
          echo "Holding 85 MiB of a 100 MiB limit (85%)"
          sleep 3600
      resources:
        requests: {memory: 100Mi, cpu: 10m}
        limits: {memory: 100Mi, cpu: 100m}
      volumeMounts:
        - {name: ram, mountPath: /ram}
  volumes:
    - name: ram
      emptyDir: {medium: Memory, sizeLimit: 200Mi}
EOT
)"
kubectl wait --for=condition=Ready pod/demo-memory-limit -n "$NS" --timeout=60s >/dev/null
sleep 2
kubectl logs demo-memory-limit -n "$NS"
echo "Expected: ContainerMemoryNearLimit after ~1-2 min. Stop: bash scripts/demo/container-memory.sh stop"
where_to_look