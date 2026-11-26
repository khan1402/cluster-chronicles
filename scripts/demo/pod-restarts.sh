#!/usr/bin/env bash
# pod-restarts.sh - review test: a pod restarts more than 3 times (PodFrequentRestarts).
#
#   bash scripts/demo/pod-restarts.sh        start a pod that crashes every few seconds
#   bash scripts/demo/pod-restarts.sh stop   delete it
#
# The container exits with an error after 3 seconds; Kubernetes restarts it
# again and again (CrashLoopBackOff, with growing pauses: 10 s, 20 s, 40 s...).
# Expected: Firing after about 3 minutes (the 4th restart).
# Resolved only when fewer than 4 restarts are left in the 15-minute window,
# so about 10-15 minutes after stop - that is how the rule is defined.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

if [[ "${1:-}" == "stop" ]]; then
  stop_pod demo-crash; echo "Crashing pod deleted."; exit 0
fi

ensure_ns
stop_pod demo-crash
apply_pod "$(cat <<'EOT'
apiVersion: v1
kind: Pod
metadata:
  name: demo-crash
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: cluster-chronicles
spec:
  restartPolicy: Always
  containers:
    - name: crash
      image: busybox:1.36
      command: [sh, -c, 'echo "Crashing on purpose"; sleep 3; exit 1']
EOT
)"
echo "Pod demo-crash started. Watch the RESTARTS column grow:"
echo "  kubectl get pod demo-crash -n $NS -w"
echo "Expected: PodFrequentRestarts after ~3 min. Stop: bash scripts/demo/pod-restarts.sh stop"
where_to_look