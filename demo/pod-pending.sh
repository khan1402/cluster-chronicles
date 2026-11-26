#!/usr/bin/env bash
# pod-pending.sh - review test: a pod stuck in Pending (PodPendingTooLong).
#
#   bash scripts/demo/pod-pending.sh        create a pod that asks for 100 CPUs
#   bash scripts/demo/pod-pending.sh stop   delete it
#
# No node has 100 CPUs, so the scheduler can never place the pod.
# Expected: Firing after 5 min (1 min in demo mode), Resolved ~1 min after stop.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

if [[ "${1:-}" == "stop" ]]; then
  stop_pod demo-pending; echo "Pending pod deleted."; exit 0
fi

ensure_ns
stop_pod demo-pending
apply_pod "$(cat <<'EOT'
apiVersion: v1
kind: Pod
metadata:
  name: demo-pending
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: cluster-chronicles
spec:
  containers:
    - name: wait
      image: busybox:1.36
      command: [sleep, "3600"]
      resources:
        requests: {cpu: "100"}
EOT
)"
sleep 3
kubectl get pod demo-pending -n "$NS"
kubectl get events -n "$NS" --field-selector involvedObject.name=demo-pending,reason=FailedScheduling \
  -o custom-columns=WHY:.message --no-headers | tail -1
echo "Expected: PodPendingTooLong after 5 min (1 min in demo mode). Stop: bash scripts/demo/pod-pending.sh stop"
where_to_look