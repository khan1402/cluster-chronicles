#!/usr/bin/env bash
# validate.sh - check the whole system and print PASS / FAIL for each part.
#
# Runs on the laptop (WSL), from anywhere in the repo:
#   bash scripts/validate.sh
#
# Read-only: it changes nothing (the only thing it creates is one short-lived
# test pod in the "default" namespace, to prove the network policies block
# traffic). Takes about 1 minute. Exit code 0 = everything passed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

IP=192.168.0.122
APP="http://$IP"
JENKINS="http://jenkins.$IP.nip.io"
GRAFANA="http://grafana.$IP.nip.io"
PROMETHEUS="http://prometheus.$IP.nip.io"
ALERTMANAGER="http://alertmanager.$IP.nip.io"
KIBANA="http://kibana.$IP.nip.io"
DEPLOYER=system:serviceaccount:cicd:jenkins-deployer
JENKINS_SA=system:serviceaccount:cicd:jenkins

PASSED=0
FAILED=0
pass()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
title() { printf '\n\033[1m%s\033[0m\n' "$1"; }
expect() {   # expect "<description>" <command...>  -> PASS if the command succeeds
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
http_code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$1"; }
http_ok()   { [[ "$(http_code "$1")" == "200" ]]; }
count()     { grep -o "$1" | wc -l; }
ready() {    # ready <kind/name> <namespace>  -> all wanted replicas are ready
  local want have
  want="$(kubectl get "$1" -n "$2" -o jsonpath='{.status.replicas}{.status.desiredNumberScheduled}' 2>/dev/null)"
  have="$(kubectl get "$1" -n "$2" -o jsonpath='{.status.readyReplicas}{.status.numberReady}' 2>/dev/null)"
  [[ -n "$want" && "$want" != "0" && "$want" == "$have" ]]
}
can()    { [[ "$(kubectl auth can-i "$@" 2>/dev/null)" == "yes" ]]; }
cannot() { ! can "$@"; }

# --- 1. Cluster ---------------------------------------------------------------------------
title "1. Cluster"
expect "kubectl reaches the API server" kubectl cluster-info
expect "the node is Ready" bash -c "kubectl get nodes --no-headers | grep -qw Ready"
expect "ingress-nginx controller is ready" ready deployment/ingress-nginx-controller ingress-nginx
expect "metrics-server works (kubectl top)" kubectl top nodes

# --- 2. Namespaces and Pod Security ---------------------------------------------------
title "2. Namespaces and Pod Security"
psa() { [[ "$(kubectl get ns "$1" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" == "$2" ]]; }
expect "app enforces 'restricted'"      psa app restricted
expect "cicd enforces 'baseline'"       psa cicd baseline
expect "monitoring namespace exists"    kubectl get ns monitoring
expect "logging namespace exists"       kubectl get ns logging

# --- 3. Storage -----------------------------------------------------------------------
title "3. Storage"
expect "StorageClass 'manual' exists" kubectl get storageclass manual
pvcs_total="$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l)"
pvcs_bound="$(kubectl get pvc -A --no-headers 2>/dev/null | grep -cw Bound)"
expect "all PVCs are Bound ($pvcs_bound/$pvcs_total)" test "$pvcs_total" -ge 5 -a "$pvcs_total" -eq "$pvcs_bound"

# --- 4. App ---------------------------------------------------------------------------
title "4. App"
expect "backend deployment ready"  ready deployment/backend app
expect "frontend deployment ready" ready deployment/frontend app
page="$(curl -s -m 10 "$APP/")"
expect "app answers on $APP/" grep -q "Responding server" <<<"$page"
expect "frontend reaches the backend" bash -c "! grep -qi unreachable <<<\"\$1\"" _ "$page"
expect "backend runs as non-root (uid 10001)"  bash -c "[[ \$(kubectl exec -n app deploy/backend -- id -u) == 10001 ]]"
expect "frontend runs as non-root (uid 10001)" bash -c "[[ \$(kubectl exec -n app deploy/frontend -- id -u) == 10001 ]]"
hpa_cpu="$(kubectl get hpa -n app -o jsonpath='{.items[0].status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
expect "HPA reads CPU usage (now ${hpa_cpu:-unknown}%)" test -n "$hpa_cpu"

# --- 5. CI/CD -------------------------------------------------------------------------
title "5. CI/CD (Jenkins)"
expect "Jenkins StatefulSet ready" ready statefulset/jenkins cicd
expect "Jenkins web UI answers"    http_ok "$JENKINS/login"
expect "RBAC: deployer CAN patch deployments in app"     can    patch deployments -n app --as="$DEPLOYER"
expect "RBAC: deployer can NOT read secrets in app"      cannot get secrets -n app --as="$DEPLOYER"
expect "RBAC: deployer can NOT delete namespaces"        cannot delete namespaces --as="$DEPLOYER"
expect "RBAC: jenkins CAN create build pods in cicd"     can    create pods -n cicd --as="$JENKINS_SA"
expect "RBAC: jenkins can NOT touch deployments in app"  cannot patch deployments -n app --as="$JENKINS_SA"

# --- 6. Secrets -----------------------------------------------------------------------
title "6. Secrets"
for s in cicd/jenkins-secrets cicd/dockerhub-push monitoring/grafana-admin monitoring/alertmanager-slack; do
  expect "Secret $s exists" kubectl get secret "${s#*/}" -n "${s%/*}"
done
expect "secrets.env is NOT in git" bash -c "! git ls-files --error-unmatch security/secrets/secrets.env"

# --- 7. Monitoring --------------------------------------------------------------------
title "7. Monitoring"
expect "Prometheus ready"   ready statefulset/prometheus-kps-prometheus monitoring
expect "Alertmanager ready" ready statefulset/alertmanager-kps-alertmanager monitoring
expect "Grafana ready"      ready deployment/grafana monitoring
targets="$(curl -s -m 10 "$PROMETHEUS/api/v1/targets?state=active")"
up="$(count '"health":"up"' <<<"$targets")"
down="$(count '"health":"down"' <<<"$targets")"
expect "Prometheus targets: $up up, $down down" test "$up" -gt 0 -a "$down" -eq 0
expect "app targets are scraped" grep -q '"job":"backend"' <<<"$targets"
rules="$(curl -s -m 10 "$PROMETHEUS/api/v1/rules?type=alert")"
missing=""
for a in NodeHighCPU NodeLowDiskSpace NodeHighMemory PodFrequentRestarts ContainerMemoryNearLimit \
         PodPendingTooLong KubeAPIServerDown ElasticsearchClusterNotGreen FluentBitOutputErrors FluentBitNoLogsCollected; do
  grep -q "\"name\":\"$a\"" <<<"$rules" || missing="$missing $a"
done
expect "all 10 project alert rules loaded${missing:+ (missing:$missing)}" test -z "$missing"
want5="$(grep -cE '^[[:space:]]+for: 5m' manifests/monitoring/alert-rules.yaml)"
have5="$(kubectl get prometheusrule cluster-chronicles-alerts -n monitoring \
  -o jsonpath='{range .spec.groups[*].rules[*]}{.for}{"\n"}{end}' 2>/dev/null | grep -c '^5m$')"
expect "demo mode is off (real 5-minute alert windows)" test "$want5" -eq "$have5"
expect "Alertmanager answers" http_ok "$ALERTMANAGER/-/healthy"
expect "Grafana answers"      http_ok "$GRAFANA/api/health"
for d in cluster-performance pods-containers app-performance; do
  expect "Grafana dashboard '$d' is loaded" kubectl get configmap "dashboard-$d" -n monitoring
done

# --- 8. Logging -----------------------------------------------------------------------
title "8. Logging"
es() { kubectl exec -n logging elasticsearch-0 -c elasticsearch -- curl -s -m 10 "localhost:9200/$1" 2>/dev/null; }
health="$(es _cluster/health)"
expect "Elasticsearch is green"        grep -q '"status":"green"' <<<"$health"
expect "Elasticsearch has 2 nodes"     grep -q '"number_of_nodes":2' <<<"$health"
expect "ILM policy k8s-logs (delete after 3 days)" grep -q '"k8s-logs"' <<<"$(es _ilm/policy/k8s-logs)"
indices="$(es '_cat/indices/k8s-*?h=index,docs.count')"
expect "container logs are stored (k8s-containers-*)" grep -q '^k8s-containers-' <<<"$indices"
expect "node logs are stored (k8s-node-*)"            grep -q '^k8s-node-' <<<"$indices"
expect "Fluent Bit runs on every node" ready daemonset/fluent-bit logging
expect "Elasticsearch exporter ready"  ready deployment/elasticsearch-exporter logging
expect "Kibana answers" bash -c "curl -s -m 10 '$KIBANA/api/status' | grep -q '\"level\":\"available\"'"
dash="$(curl -s -m 10 "$KIBANA/api/saved_objects/_find?type=dashboard&per_page=100")"
expect "Kibana has the 3 project dashboards" grep -q '"total":3' <<<"$dash"

# --- 9. Network policies --------------------------------------------------------------
title "9. Network policies"
np="$(kubectl get networkpolicy -A --no-headers 2>/dev/null | wc -l)"
expect "network policies applied ($np)" test "$np" -ge 22
# A "stranger" pod in the default namespace tries the backend and Elasticsearch.
# No attach (-i): the pod runs on its own, we wait for it, then read its log.
probe_pod="np-check-$RANDOM"
kubectl run "$probe_pod" --restart=Never --image=busybox:1.36 --command -- \
  sh -c 'wget -qO- -T 3 http://backend.app:3000/metrics >/dev/null 2>&1 && echo BACKEND-OPEN || echo BACKEND-BLOCKED
         wget -qO- -T 3 http://elasticsearch.logging:9200 >/dev/null 2>&1 && echo ES-OPEN || echo ES-BLOCKED' >/dev/null 2>&1
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$probe_pod" --timeout=60s >/dev/null 2>&1
probe="$(kubectl logs "$probe_pod" 2>/dev/null)"
kubectl delete pod "$probe_pod" --wait=false >/dev/null 2>&1
expect "a stranger pod can NOT reach the backend"   grep -q BACKEND-BLOCKED <<<"$probe"
expect "a stranger pod can NOT reach Elasticsearch" grep -q ES-BLOCKED <<<"$probe"

# --- Summary --------------------------------------------------------------------------
title "Result: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]