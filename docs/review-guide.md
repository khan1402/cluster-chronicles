# Review guide - cluster chronicles

Answers and demos for every review question, in the order of the testing list.
All commands run in WSL from the repo root unless written otherwise.

**Before the review:**

```bash
bash scripts/validate.sh                 # 53 passed, 0 failed
bash scripts/demo/demo-mode.sh on        # 5-minute alerts fire after 1 minute
```

**Links:** app http://192.168.0.122/ · Jenkins http://jenkins.192.168.0.122.nip.io/ ·
Grafana http://grafana.192.168.0.122.nip.io/ · Prometheus http://prometheus.192.168.0.122.nip.io/alerts ·
Alertmanager http://alertmanager.192.168.0.122.nip.io/ · Kibana http://kibana.192.168.0.122.nip.io/

**After the review:** `bash scripts/demo/cleanup.sh` (also turns demo mode off).

---

## 1. Kubernetes architecture components

- **API server** - the front door of the cluster. Every command (kubectl,
  controllers, kubelet) goes through it; it checks authentication, RBAC and
  admission rules, then stores the result in etcd.
- **etcd** - the key-value database that holds the whole cluster state
  (desired and current). Only the API server talks to it.
- **Controller manager** - runs the control loops: compares desired state with
  real state and fixes the difference (e.g. the Deployment controller creates
  ReplicaSets, the ReplicaSet controller keeps the right number of pods).
- **Scheduler** - picks a node for every new pod, based on requests, free
  resources, taints and affinity. A pod with no fitting node stays Pending.
- **kubelet** - the agent on every node: starts the pod's containers through
  containerd, runs the probes, reports status back to the API server.

Show: `kubectl get pods -n kube-system` (kube-apiserver-minikube, etcd-minikube,
kube-controller-manager-minikube, kube-scheduler-minikube; the kubelet is a
system service on the node: `ssh minikube-vm "minikube ssh -- systemctl is-active kubelet"`).

## 2. Kubernetes vs VM-based deployments

Benefits:
- declarative: the desired state is in YAML in Git, Kubernetes keeps it true
- self-healing: crashed pods restart, failed probes take pods out of traffic
- built-in rolling updates, rollbacks, scaling (HPA) and service discovery
- better use of hardware: many small pods share nodes, with requests/limits
- the same manifests run on any cluster (laptop, cloud)

Drawbacks:
- much more to learn and run (control plane, networking, storage, RBAC)
- debugging has more layers (pod, node, CNI, Ingress)
- stateful systems (databases, Elasticsearch) need extra care
- overkill for one small app on one server

In this project: one VM runs all parts as pods instead of one VM per role, an
Ingress replaces a separate load-balancer VM, and `kubectl set image` replaces
deploy scripts run on each server.

## 3. Namespaces

Logical separation inside one cluster: names only have to be unique per
namespace, and RBAC, NetworkPolicies, Pod Security levels and resource quotas
apply per namespace. Here: `app`, `cicd`, `monitoring`, `logging` - each with
its own security level and policies.

Show: `kubectl get ns --show-labels`

## 4. Deployment vs StatefulSet

- **Deployment** - identical, interchangeable pods with random names; any pod
  can be replaced by a new one anywhere. For stateless apps. Here: frontend,
  backend, Kibana, Grafana.
- **StatefulSet** - each pod has a stable name (`-0`, `-1`), its own PVC that
  follows it, and pods start/stop in order. For databases and clustered
  systems. Here: Elasticsearch (each node keeps its own data and DNS name),
  Jenkins (one controller, one home folder, never two copies at once),
  Prometheus and Alertmanager (created by the Operator).

Show: `kubectl get deploy,sts -A`

## 5. Networking model

- Every pod gets its own IP; all pods can reach all pods directly, across
  nodes, without NAT. The CNI plugin (kindnet in Minikube) builds this network.
- Services give a stable virtual IP and DNS name (`backend.app.svc.cluster.local`)
  in front of changing pod IPs. CoreDNS resolves the names.
- Across nodes, the CNI routes pod traffic between node IPs. Minikube has one
  node, so all traffic stays on it, but the model is the same.

Show: `kubectl get pods -n app -o wide` (pod IPs) and
`kubectl get endpoints -n app frontend` (the pods behind the Service).

## 6. kube-proxy

Runs on every node and turns Services into packet rules (iptables/IPVS): traffic
to a Service's ClusterIP is sent to one of its ready pods, spreading load
across them. When pods come and go, kube-proxy updates the rules from the
EndpointSlices. External traffic in this project goes through ingress-nginx,
which balances across the same endpoints.

Show: `kubectl get pods -n kube-system -l k8s-app=kube-proxy`

## 7. Operators

An Operator is a controller plus Custom Resource Definitions that teaches
Kubernetes to run a complex app. You describe what you want in a custom
resource; the Operator does the work a human admin would. Here: the
**Prometheus Operator** - a ServiceMonitor says "scrape these Services", a
PrometheusRule holds alert rules, and the Operator turns them into Prometheus
configuration and reloads it.

Show: `kubectl get servicemonitor,prometheusrule -n monitoring`

## 8. Minikube limitations

- one node: no real high availability, node failure = cluster down,
  `podAntiAffinity` and spreading can't be shown
- no cloud LoadBalancer: `LoadBalancer` Services stay `<pending>` unless
  `minikube tunnel` is used; here an Ingress + nginx forwarder is used instead
- storage is hostPath on the node, not real network disks
- control plane parts listen on 127.0.0.1, so etcd/scheduler/controller-manager
  can't be scraped by Prometheus
- node = a Docker container: its limit (124 GB) can differ from what the node
  reports (VM RAM) - this caused the memory demo overload in this project
- it runs as one big machine, not a real production setup (no etcd backups,
  upgrades, multiple zones)

## 9. Probes

- **readiness** - "can this pod take traffic?" Not ready → removed from the
  Service endpoints, not restarted. Used during rolling updates.
- **liveness** - "is it stuck?" Fails repeatedly → the kubelet restarts the container.
- **startup** - "has it finished starting?" Liveness and readiness wait until it
  passes. For slow starters.

Here: frontend and backend use `/health` for liveness and readiness;
Jenkins has a startup probe of up to 10 minutes (first start loads plugins);
Elasticsearch checks its HTTP port for readiness and transport port for liveness.

Show: `kubectl describe deploy frontend -n app | grep -A3 -i probe`

## 10. Requests, limits and exceeding memory

- **requests** - what the scheduler reserves; a pod only lands on a node with
  that much free. Also the base for HPA percentages.
- **limits** - the maximum. CPU above the limit is throttled (slowed down).
- **Memory above the limit** → the kernel kills the container (`OOMKilled`,
  exit code 137) and the kubelet restarts it. Repeated → `CrashLoopBackOff`.
- ContainerMemoryNearLimit warns at 80% of the limit, before the kill.

Show: `kubectl describe pod -n app -l app.kubernetes.io/name=backend | grep -A6 Limits`

## 11. Init containers

Run to completion, one after another, before the main containers start.
Example from this project: hostPath volumes are created as root, but Jenkins
(UID 1000), Prometheus and Elasticsearch run as non-root. An init container
with only the CHOWN capability hands the folder to the right user once.
Jenkins has a second init container that installs plugins from the cache.

Show: `kubectl get sts jenkins -n cicd -o jsonpath='{.spec.template.spec.initContainers[*].name}'`

## 12. Manifests, deployment, replicas

Show:
```bash
ls manifests/backend manifests/frontend
kubectl get deploy -n app                 # backend 1/1, frontend 2/2
kubectl get pods -n app
```

## 13. Services and Ingress

Show:
```bash
kubectl get svc,ingress -A
kubectl exec -n app deploy/frontend -- python -c "import urllib.request;print(urllib.request.urlopen('http://backend:3000/health').read())"
for i in $(seq 1 6); do curl -s http://192.168.0.122/ | grep -o 'Responding server: <strong>[^<]*'; done
```
The first proves internal communication by Service name, the loop shows
external access through the Ingress and load balancing over 2 frontend pods.

## 14. Troubleshooting

```bash
kubectl get pods -A | grep -v Running          # what isn't healthy
kubectl describe pod <pod> -n <ns>             # Events: scheduling, probes, pulls, OOM
kubectl logs <pod> -n <ns> [--previous] [-c <container>]
kubectl get events -n <ns> --sort-by=.lastTimestamp
kubectl rollout status deploy/<name> -n <ns>
kubectl top pods -n <ns>
```
Real examples from this project are in [notes.md](notes.md): Jenkins
`RunContainerError` (Secret mount path), Prometheus `CrashLoopBackOff` (root-owned
volume), Jenkins stuck in `Init` (plugin download), Fluent Bit rejected logs.

## 15. Network policies

- By default every pod can reach every pod. A NetworkPolicy selects pods and
  lists the allowed traffic; once a pod is selected, everything else is denied.
- Here: `default-deny-all` in `app` and `logging`, then allow lists:
  ingress-nginx → frontend :8080 → backend :3000, Prometheus → metrics ports,
  Fluent Bit/Kibana/exporter → Elasticsearch :9200, DNS, kubelet probes.
  `cicd` and `monitoring` deny incoming; outgoing stays open (Gitea, Docker
  Hub, Slack have changing IPs).
- Security: limits what an attacker can reach from a broken pod (Elasticsearch
  has no password, so the policy is its protection).

Show:
```bash
kubectl get networkpolicy -A
kubectl run np-test --rm -i --restart=Never --image=busybox:1.36 -- wget -qO- -T 3 http://backend.app:3000/metrics
# → download timed out
```

## 16. ClusterIP, NodePort, LoadBalancer

- **ClusterIP** - virtual IP reachable only inside the cluster (default).
- **NodePort** - opens a port (30000-32767) on every node's IP.
- **LoadBalancer** - asks the cloud for an external load balancer (needs a cloud
  or MetalLB/`minikube tunnel`).

Here every Service is **ClusterIP**: backend must never be reached from outside,
and all web access goes through one Ingress (host-based routing, one place to
control access) instead of many open ports.

## 17. Persistent storage

Containers lose their files when they restart or move. Jenkins jobs and build
history, Prometheus metrics, Grafana settings and Elasticsearch logs must
survive that, so they live on PersistentVolumes.

Show:
```bash
kubectl get pv,pvc -A                         # 5 PVs, all Bound
kubectl delete pod jenkins-0 -n cicd          # job and builds still there afterwards
```

## 18. Access modes

- **ReadWriteOnce (RWO)** - read-write by one node.
- **ReadOnlyMany (ROX)** - read-only by many nodes.
- **ReadWriteMany (RWX)** - read-write by many nodes (needs NFS/CephFS etc.).

All volumes here are **RWO**: each belongs to exactly one pod (Jenkins,
Prometheus, Grafana, each Elasticsearch node), and hostPath can't be shared
across nodes anyway. RWX would only be needed if several pods wrote the same files.

## 19. Data loss when pods move to another node

- hostPath/local volumes stay on the old node - a pod moved elsewhere starts empty.
- Answers: network storage (CSI: Ceph, Longhorn, cloud disks) that follows the
  pod; node affinity to keep the pod with its data; StatefulSets so each pod
  gets back its own PVC; replication in the app itself (Elasticsearch keeps a
  replica of every index on the other node); `Retain` reclaim policy so data
  isn't deleted with the PVC; regular backups/snapshots (here: Proxmox snapshots).

## 20. CI/CD tool deployed in the cluster

Show: `kubectl get sts,pod,pvc -n cicd` and http://jenkins.192.168.0.122.nip.io/

## 21. Why Jenkins

- pipeline as code: one Jenkinsfile holds every stage (code checks, Kaniko,
  Trivy, deploy, smoke test, k6, rollback, Slack)
- the Kubernetes plugin starts a fresh build pod for every build and removes it
- fully configured as code (JCasC + Job DSL), so it rebuilds from Git
- widely used in Finnish companies; free and self-hosted (no external CI needed
  for a cluster on a home network)

## 22. Jenkins interacts with the cluster

Build pods run with ServiceAccount `jenkins-deployer`; its Role in `app` allows
updating Deployments, nothing more.

Show:
```bash
kubectl auth can-i patch deployments -n app --as=system:serviceaccount:cicd:jenkins-deployer   # yes
kubectl auth can-i get secrets -n app --as=system:serviceaccount:cicd:jenkins-deployer         # no
kubectl rollout history deploy/frontend -n app                                                  # change-cause per build
```

## 23. Secrets in the pipeline, management and rotation

- Values only in the git-ignored `secrets.env` → `create-secrets.sh` → Secrets
  (`--server-side`, never on the command line).
- Jenkins reads Gitea token and Slack webhook as **files**, admin password as an
  **environment variable**; Kaniko mounts the Docker Hub config; build logs mask them.
- Rotation: new value at the source → `secrets.env` → `create-secrets.sh` →
  restart Jenkins/Grafana/Alertmanager → revoke the old value.
  Details in the README, section Secrets.

Show: `grep -n secretKeyRef -A3 manifests/cicd/statefulset.yaml` and `git check-ignore -v security/secrets/secrets.env`

## 24. Rolling updates, failed deployments, rollback

- Deployments use `RollingUpdate`: new pods start, and old pods are removed
  only when new ones pass the readiness probe - no downtime.
- The pipeline: `kubectl set image` + `rollout status`, then smoke test and k6
  through the Ingress. Any failure → the version that was live before the
  build is deployed again and smoke-tested, Slack says "rolled back".
- Manual: `kubectl rollout undo deploy/frontend -n app`.
- Real example: build #17 failed its smoke test and rolled back by itself;
  builds #4/#5 did the same.

## 25. Prometheus scraping

Show http://prometheus.192.168.0.122.nip.io/targets - 18 targets, all UP
(apiserver, kubelet/cAdvisor, node-exporter, kube-state-metrics, CoreDNS,
app backend/frontend, Fluent Bit, Elasticsearch exporter, the stack itself).

## 26. Custom metrics

- The app uses `prometheus-fastapi-instrumentator` (request counts and
  duration histograms per endpoint) and its own metrics:
  `frontend_backend_errors_total{reason}` (failed calls to the backend) and
  `metrics_collect_seconds` (backend histogram).
- They're served on `/metrics`; the ServiceMonitor `app` tells Prometheus to
  scrape the Services named backend/frontend on port `http`.

Show:
```bash
kubectl exec -n app deploy/frontend -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/metrics').read().decode()[:600])"
```
Then query `frontend_backend_errors_total` or
`histogram_quantile(0.95, sum by (le) (rate(metrics_collect_seconds_bucket[5m])))` in Prometheus.

## 27. Service discovery and missing targets

- Prometheus asks the API server for Services/Endpoints/Pods and finds targets
  by labels; a ServiceMonitor says which labels, namespaces and port. A new
  pod (restart, HPA) becomes a target automatically.
- Challenges met and how they were handled:
  - Prometheus selects ServiceMonitors from all releases
    (`serviceMonitorSelectorNilUsesHelmValues: false`)
  - the Service port must be named (`http`) and match the ServiceMonitor
  - RBAC: Prometheus needs list/watch on the namespaces it scrapes (chart creates it)
  - NetworkPolicies must allow the `monitoring` namespace to the metrics port
  - Minikube's control plane listens on 127.0.0.1 → those targets are disabled
  - `validate.sh` fails if any target is DOWN

## 28. Grafana dashboards

Show the folder "Cluster Chronicles": Cluster Performance, Pods and Containers,
Application Performance. They are ConfigMaps generated by
`scripts/build-dashboards.py` and loaded by the Grafana sidecar.

## 29. EFK and Fluent Bit

Show: `kubectl get pods -n logging` and `kubectl get cm fluent-bit-config -n logging -o yaml | head -80`
(inputs: app container logs with JSON parsing, other containers, node journal;
outputs: `k8s-containers-*`, `k8s-node-*`).

## 30. Log rotation and retention

- **Rotation on the node:** the kubelet rotates container log files
  (`containerLogMaxSize`, `containerLogMaxFiles`); Fluent Bit remembers its read
  position in a database, so rotation loses nothing.
- **Retention in Elasticsearch:** one index per day; ILM policy `k8s-logs`
  deletes indices older than 3 days.
- **Disk protection:** watermarks 3gb/2gb/1gb (Elasticsearch stops placing data
  before the disk is full), PVs of 4 GB each, Prometheus limited to 3 days / 3 GB,
  NodeLowDiskSpace alert at 20% free.

Show:
```bash
kubectl exec -n logging elasticsearch-0 -c elasticsearch -- curl -s 'localhost:9200/_ilm/policy/k8s-logs?pretty'
kubectl exec -n logging elasticsearch-0 -c elasticsearch -- curl -s 'localhost:9200/_cat/indices/k8s-*?v'
```

## 31. Kibana dashboards

Show Kibana → Dashboards: Cluster Logs, Application Logs (status codes, levels,
endpoints, errors), Pod and Container Logs. For error lines in Application Logs:
```bash
kubectl scale deploy backend -n app --replicas=0
for i in $(seq 1 10); do curl -s -o /dev/null http://192.168.0.122/; sleep 1; done
kubectl scale deploy backend -n app --replicas=1
```

## 32. Alert rules and Alertmanager routing

- A rule = PromQL expression + `for` duration + labels + annotations
  (`manifests/monitoring/alert-rules.yaml`). Prometheus evaluates every 15 s:
  true → Pending, still true after `for` → Firing → sent to Alertmanager.
- Alertmanager routes by labels: `project="cluster-chronicles"` → Slack,
  everything else → `null`.

Show: http://prometheus.192.168.0.122.nip.io/alerts and `kubectl get secret alertmanager-kps-alertmanager -n monitoring -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | sed -n '/route:/,/receivers:/p'`

## 33. Frequent pod restarts, grouping and throttling

- Rule: `increase(kube_pod_container_status_restarts_total[15m]) > 3`.
- Against alert fatigue: `group_by [alertname, namespace, pod, instance]` (one
  message per problem), `group_wait 30s` (collect related alerts first),
  `group_interval 5m` (new alerts in a group at most every 5 minutes),
  `repeat_interval 4h` (no repeats for a still-firing alert), and only this
  project's alerts reach Slack.

## 34-42. Alert demos

Run each script, watch the Prometheus alerts page and Slack. Each script prints
how to stop it.

- **CPU > 80% for 5 min:** `bash scripts/demo/cpu.sh` - CPU capped at 88% of
  the node by a CPU limit, stops after 4 minutes.
- **Disk < 20%:** `bash scripts/demo/disk.sh` (fallocate to 18% free on `/var`) → `disk.sh stop`.
- **Memory > 90% for 5 min:** `bash scripts/demo/memory.sh` - 91% with a
  memory limit, frees itself after 4 minutes, run it alone.
- **Pod restarts > 3 in 15 min:** `bash scripts/demo/pod-restarts.sh` → `pod-restarts.sh stop`
  (RESOLVED only after the 15-minute window).
- **Container memory > 80% of limit:** `bash scripts/demo/container-memory.sh`
  (85 MiB of a 100 MiB limit) → `container-memory.sh stop`.
- **Pod Pending > 5 min:** `bash scripts/demo/pod-pending.sh` (requests 100 CPUs) → `pod-pending.sh stop`.
- **API server unreachable:** `bash scripts/demo/apiserver-down.sh` - moves the
  static pod manifest away for 3 minutes and back; kubectl fails meanwhile, the
  app keeps running. Then `kubectl get nodes`.
- **Elasticsearch yellow/red:** `bash scripts/demo/es-yellow.sh` (1 node) → `es-yellow.sh restore`.
- **Fluent Bit collection errors:** `bash scripts/demo/fluentbit-errors.sh`
  removes Fluent Bit from the network policy allow list, so deliveries fail →
  `fluentbit-errors.sh restore`. A wrong log source path is caught by the
  second rule, FluentBitNoLogsCollected (no lines read for 5 minutes).

Timing with demo mode: about 2-4 minutes per alert. Finish with
`bash scripts/demo/cleanup.sh`.

## 43. RBAC

Role-based access control: who (user/ServiceAccount) may do which verbs on which
resources in which namespace. Least privilege limits the damage of a leaked
token. Examples here:
- `jenkins` - manage pods in `cicd` only (build pods)
- `jenkins-deployer` - update Deployments in `app` only, no Secrets
- Prometheus, Fluent Bit - read-only ClusterRoles (list/watch pods, nodes)

Show: `kubectl auth can-i --list -n app --as=system:serviceaccount:cicd:jenkins-deployer`

## 44. Network segmentation

Namespaces separate the parts logically; NetworkPolicies separate them on the
network: `app` and `logging` accept only listed traffic and send only listed
traffic; Elasticsearch accepts 9200 only from Fluent Bit, Kibana, the exporter
and the setup Job; the backend only from the frontend and Prometheus. Ingress
is the only way in from outside. See question 15.

## 45. Kubernetes Secrets

Objects for sensitive data, kept apart from Pod specs and ConfigMaps, readable
only with RBAC rights, mounted only into pods in the same namespace. Only
base64-encoded by default - encryption at rest and a vault are the production
answer (README, section Secrets).

## 46. Secrets as volumes and environment variables

Show:
```bash
grep -n -B2 -A4 'secretKeyRef' manifests/cicd/statefulset.yaml        # env var
grep -n -A12 'name: jenkins-secrets' manifests/cicd/statefulset.yaml  # volume
kubectl exec -n cicd jenkins-0 -- ls -l /var/jenkins_secrets            # files, mode 0440
```

## 47. No secrets in plain text

Show:
```bash
git check-ignore -v security/secrets/secrets.env
git ls-files | grep -i secret                     # only secrets.env.example
grep -rniE 'password|token|hooks.slack' manifests ci Jenkinsfile | grep -v -i 'secretKeyRef\|readFile\|existingSecret\|_file\|credentialsId'
```

## 48. Namespaces for components

Show: `kubectl get pods -A -o wide | awk '{print $1}' | sort | uniq -c`

## 49. Debugging CrashLoopBackOff

1. `kubectl get pods -n <ns>` - RESTARTS growing, status CrashLoopBackOff
2. `kubectl describe pod <pod> -n <ns>` - Last State: reason (Error,
   OOMKilled = memory limit), exit code, probe failures in Events
3. `kubectl logs <pod> -n <ns> --previous` - the log of the crashed run
4. check config: env vars, ConfigMaps/Secrets mounted, image tag, command,
   volume permissions
5. fix, then `kubectl rollout restart` or let the next deploy replace it

Real example: Prometheus crashed because its volume subPath was root-owned →
`disableMountSubPath` + init container chown (notes, Group 3A).
Demo: `bash scripts/demo/pod-restarts.sh` makes a CrashLoopBackOff to inspect.

## 50. Pending because of insufficient resources

1. `kubectl get pods` - status Pending
2. `kubectl describe pod` - Events: `0/1 nodes are available: 1 Insufficient cpu`
3. `kubectl describe node minikube` - "Allocated resources" vs capacity;
   `kubectl top nodes`
4. fix: lower the pod's requests, remove or scale down other workloads, add a
   node (or more CPU/RAM to Minikube), or check taints/affinity/PVC binding,
   which also cause Pending

Demo: `bash scripts/demo/pod-pending.sh` shows the exact message.

## 51-53. Folder structure, README, code quality

- Folders: `manifests/<part>/`, `ci/`, `scripts/`, `security/`, `infra/`, `docs/`
  (README, section Repository structure).
- README: overview, setup, usage, secrets, extras.
- Every manifest and script starts with a comment explaining what it does and
  why; ruff, bandit and pytest run in the pipeline; `validate.sh` checks the result.

## Quality: image scanning

- Trivy runs in the pipeline after Kaniko pushes and **before** Deploy.
- First run: HIGH + CRITICAL report (exit code 0) for visibility.
- Second run: `--severity CRITICAL --ignore-unfixed --exit-code 1` - the
  pipeline stops if a CRITICAL vulnerability with an available fix exists;
  unfixed ones are reported but can't be acted on yet.

Show: the "Image scan (Trivy)" stage of the last build in Jenkins.

## Quality: HPA

- `manifests/frontend/hpa.yaml`: min 2, max 5, target 50% average CPU of the
  frontend's request; metrics from metrics-server.
- The HPA changes the Deployment's replica count; the Deployment creates/removes
  pods; scale-down waits 5 minutes (stabilisation) to avoid flapping.

Show:
```bash
bash scripts/demo/hpa-load.sh
kubectl get hpa -n app -w          # CPU rises far above 50%, REPLICAS 2 → 5
```
After the 5-minute load and the 5-minute stabilisation window it returns to 2.

## Quality: beyond the core requirements

NetworkPolicies (22, default deny), Pod Security levels, Kaniko (no privileged
builds), automatic rollback with version + load-balancing smoke test, k6 load
test, JCasC with plugin cache, dashboards as code, Alertmanager routing and
grouping, Elasticsearch exporter + logging alerts, ILM retention,
`deploy-all.sh`, `validate.sh` (53 checks), demo scripts with safety limits.

---

## Challenges faced (short version)

- disk alert silent: `/` is overlay, not reported → watch `/var`
- CPU + memory demos together froze the node: Minikube container limit
  (40 GB) below what the node reported → 128 GB VM, 124 GB limit, safe demos
- Fluent Bit rejected logs: merged JSON from all pods clashed in field types
  → parse JSON only for the app
- Prometheus CrashLoopBackOff: root-owned volume subPath → disable subPath + chown
- smoke test too fast for ingress-nginx → wait for the second pod

Full list: [notes.md](notes.md).
