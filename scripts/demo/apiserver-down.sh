#!/usr/bin/env bash
# apiserver-down.sh - review test: the Kubernetes API server is down (KubeAPIServerDown).
#
#   bash scripts/demo/apiserver-down.sh [seconds]   stop it for N seconds (default 180)
#
# The API server is a "static pod": the kubelet runs whatever manifest sits in
# /etc/kubernetes/manifests on the node. A root pod on the node moves that
# file away (the kubelet stops the API server), waits, then moves it back
# (the kubelet starts it again). It restores itself - nothing to undo.
#
# While it is down, kubectl doesn't work ("connection refused") - that is the
# point. The running app, Prometheus, Alertmanager and Slack keep working.
# Expected: Firing after about 2 minutes, Resolved ~1-2 minutes after it is back.
#
# Emergency only (if the node pod was somehow killed mid-way), on the VM:
#   minikube ssh "sudo mv /etc/kubernetes/kube-apiserver.yaml.demo /etc/kubernetes/manifests/kube-apiserver.yaml"

# shellcheck source=/dev/null
source "$(dirname "$0")/_common.sh"

DOWN="${1:-180}"
[[ "$DOWN" =~ ^[0-9]+$ ]] || { echo "usage: bash scripts/demo/apiserver-down.sh [seconds]" >&2; exit 1; }

script='M=/etc/kubernetes/manifests/kube-apiserver.yaml
B=/etc/kubernetes/kube-apiserver.yaml.demo
restore() { if [ -f "$B" ]; then mv "$B" "$M"; echo "$(date +%T) manifest back - API server starting"; fi; }
trap restore EXIT INT TERM
mv "$M" "$B" && echo "$(date +%T) manifest moved away - API server stopping for __DOWN__ s"
sleep __DOWN__'
node_pod demo-apiserver "${script//__DOWN__/$DOWN}"
kubectl wait --for=condition=Ready pod/demo-apiserver -n "$NS" --timeout=60s >/dev/null 2>&1 || true

echo "API server goes down now, for $DOWN s. kubectl will fail until then."
echo "Expected: KubeAPIServerDown FIRING in Slack after ~2 min, RESOLVED after it is back."
echo "Check it is back:  kubectl get nodes   (then: bash scripts/demo/cleanup.sh removes the finished pod)"
where_to_look