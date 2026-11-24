#!/usr/bin/env bash
# _common.sh - shared helpers for the review demo scripts (sourced, not run).
#
# Every demo runs on the laptop (WSL), from anywhere in the repo, with kubectl
# connected to the cluster. Each script returns within about a minute: the
# load itself keeps running inside the cluster, in the "demo" namespace.
#
# Undo everything at once: bash scripts/demo/cleanup.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

NS=demo
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

# The demo namespace: separate from the real app, deleted by cleanup.sh.
# Privileged level: the node-level demos (disk, API server) need root on the node.
ensure_ns() {
  # Still being deleted by a cleanup.sh run a moment ago? Wait until it is gone.
  if [[ "$(kubectl get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Terminating" ]]; then
    echo "Waiting for the old demo namespace to finish deleting..."
    kubectl wait --for=delete "namespace/$NS" --timeout=180s >/dev/null
  fi
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$NS" --overwrite >/dev/null \
    app.kubernetes.io/part-of=cluster-chronicles \
    pod-security.kubernetes.io/enforce=privileged
}

# stop_pod <name>: delete a demo pod right away.
stop_pod() {
  kubectl delete pod "$1" -n "$NS" --ignore-not-found --grace-period=0 --force >/dev/null 2>&1 || true
}

# apply_pod <yaml>: create a pod from a template; __NS__ and __NODE__ are filled in.
apply_pod() {
  sed "s/__NS__/$NS/g; s/__NODE__/$NODE/g" <<<"$1" | kubectl apply -f - >/dev/null
}

# node_pod <name> <script>: run <script> as root DIRECTLY on the node.
# A privileged pod mounts the node's whole filesystem at /host and chroots
# into it, so the script sees the node exactly as an SSH login would.
node_pod() {
  local name="$1" script="$2"
  ensure_ns
  kubectl delete pod "$name" -n "$NS" --ignore-not-found --wait=true >/dev/null
  kubectl apply -f - >/dev/null <<EOT
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: cluster-chronicles
spec:
  nodeName: $NODE
  restartPolicy: Never
  hostPID: true
  containers:
    - name: node
      image: busybox:1.36
      command: [chroot, /host, sh, -c]
      args:
        - |
$(sed 's/^/          /' <<<"$script")
      securityContext:
        privileged: true
      volumeMounts:
        - {name: host, mountPath: /host}
  volumes:
    - name: host
      hostPath: {path: /}
EOT
}

# node_run <name> <script>: node_pod, wait until it finishes, print its output, delete it.
node_run() {
  node_pod "$1" "$2"
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" -n "$NS" --timeout=90s >/dev/null
  kubectl logs "$1" -n "$NS"
  kubectl delete pod "$1" -n "$NS" --wait=false >/dev/null
}

where_to_look() {
  echo
  echo "Watch it here:"
  echo "  Alerts (Pending -> Firing): http://prometheus.192.168.0.122.nip.io/alerts"
  echo "  Dashboards:                 http://grafana.192.168.0.122.nip.io/dashboards (folder 'Cluster Chronicles')"
  echo "  Slack:                      FIRING, then RESOLVED after the stop/restore step"
}