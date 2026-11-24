#!/usr/bin/env bash
# hpa-load.sh - review test: the HorizontalPodAutoscaler adds frontend pods under load.
#
#   bash scripts/demo/hpa-load.sh [seconds]   send traffic (default 300 s)
#   bash scripts/demo/hpa-load.sh stop        stop early
#
# One pod sends many requests at once through ingress-nginx to the frontend,
# exactly the path real users take. Frontend CPU goes above the 50% target, so
# the HPA adds pods (2 -> up to 5). After the load, it waits 5 minutes before
# removing them (scale-down stabilisation: no flapping up and down).
# Expected: more frontend pods within 1-2 minutes.

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

ARG="${1:-300}"
if [[ "$ARG" == "stop" ]]; then
  stop_pod demo-load; echo "Load stopped. The HPA scales back down after about 5 minutes."; exit 0
fi
[[ "$ARG" =~ ^[0-9]+$ ]] || { echo "usage: bash scripts/demo/hpa-load.sh [seconds|stop]" >&2; exit 1; }

ensure_ns
stop_pod demo-load
apply_pod "$(sed "s/__SECONDS__/$ARG/g" <<'EOT'
apiVersion: v1
kind: Pod
metadata:
  name: demo-load
  namespace: __NS__
  labels:
    app.kubernetes.io/part-of: cluster-chronicles
spec:
  restartPolicy: Never
  containers:
    - name: load
      image: busybox:1.36
      command: [sh, -c]
      args:
        - |
          URL=http://ingress-nginx-controller.ingress-nginx.svc.cluster.local
          end=$(( $(date +%s) + __SECONDS__ ))
          worker() { while [ "$(date +%s)" -lt "$end" ]; do wget -q -O /dev/null -T 5 "$URL$1" || true; done; }
          echo "Sending traffic for __SECONDS__ s: 16 workers on /health, 4 on / (the real page)"
          for i in $(seq 16); do worker /health & done
          for i in $(seq 4); do worker / & done
          wait
          echo "Done"
EOT
)"
kubectl wait --for=condition=Ready pod/demo-load -n "$NS" --timeout=60s >/dev/null
kubectl logs demo-load -n "$NS"
echo "Watch the HPA (Ctrl+C to stop watching):"
echo "  kubectl get hpa -n app -w"
echo "  kubectl get pods -n app -l app.kubernetes.io/name=frontend -w"