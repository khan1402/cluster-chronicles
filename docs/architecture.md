# Architecture - cluster chronicles

How the parts of this project fit together, and why they were built this way.

---

## 1. The big picture

```
                         Home network 192.168.0.0/24
 Laptop (WSL: kubectl, git)          Browser
        │ https://192.168.0.122:8443        │ http://192.168.0.122/ , http://<tool>.192.168.0.122.nip.io/
        ▼                                   ▼
┌──────────────────────────── Proxmox host "pve" (192.168.0.121) ────────────────────────────┐
│  VM 500 "minikube" (192.168.0.122) - Ubuntu 22.04, 16 vCPU, 128 GB RAM, 40 GB disk        │
│    nginx (stream): VM :80/:443/:8443  ──►  Minikube node 192.168.49.2                     │
│  ┌────────────────────── Minikube node (Docker container, limit 124 GB) ────────────────┐ │
│  │  kube-system   API server, etcd, scheduler, controller manager, CoreDNS, kindnet     │ │
│  │  ingress-nginx Ingress controller (addon)                                             │ │
│  │  app           frontend x2-5 (HPA) ──► backend x1                                     │ │
│  │  cicd          Jenkins (StatefulSet) ──► build pods (Kaniko, Trivy, k6, kubectl)      │ │
│  │  monitoring    Prometheus Operator, Prometheus, Alertmanager, Grafana,                │ │
│  │                node-exporter, kube-state-metrics                                      │ │
│  │  logging       Elasticsearch x2, Fluent Bit (DaemonSet), Kibana, ES exporter          │ │
│  └───────────────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
        Outside: Gitea (code), Docker Hub (images), Slack (notifications and alerts)
```

The brief asks for Minikube "on the local machine". In this project the local
machine is one Proxmox VM: still Minikube, with far more CPU and RAM than a
laptop. It runs with the Docker driver, so the whole cluster is one node
(a Docker container inside the VM).

---

## 2. Getting in: networking from outside

- **Minikube's node IP (192.168.49.2) only exists inside the VM.** An nginx
  stream proxy on the VM forwards ports 80, 443 and 8443 to it, so the home
  network can reach the Ingress controller and the API server.
- **kubectl** on the laptop uses `https://192.168.0.122:8443`.
- **Ingress** (`manifests/ingress/ingress.yaml`): one Ingress per namespace,
  because an Ingress can only point to Services in its own namespace.
  - no host name → the app (frontend Service)
  - `jenkins.`, `grafana.`, `prometheus.`, `alertmanager.`, `kibana.` +
    `192.168.0.122.nip.io` → each web UI
- **nip.io** is public DNS that answers `<anything>.192.168.0.122.nip.io` with
  192.168.0.122, so name-based routing works without editing hosts files.
- **All Services are ClusterIP.** Nothing is exposed with NodePort or
  LoadBalancer: the Ingress is the only door, which keeps one place for
  routing and access control.

Inside the cluster, every pod gets its own IP from the CNI (kindnet), pods talk
to each other directly, and they find each other by Service name through
CoreDNS (`http://backend:3000`).

---

## 3. Namespaces and Pod Security

`manifests/namespaces/namespaces.yaml`

- **app** - frontend and backend. Pod Security `enforce: restricted`: no root,
  no privilege escalation, all capabilities dropped, seccomp on.
- **cicd** - Jenkins and its build pods. `enforce: baseline`, `warn: restricted`.
  Jenkins needs one init container with the CHOWN capability.
- **monitoring** - the Prometheus stack. `enforce: privileged`, `warn: baseline`.
  node-exporter needs host access to read the node's CPU, memory and disk.
- **logging** - EFK. `enforce: privileged`, `warn: baseline`. Fluent Bit reads
  log files on the node through hostPath.

Namespaces give each part its own RBAC, network policies, Pod Security level
and a clear `kubectl get -n <namespace>` view. Labels
`app.kubernetes.io/name` and `app.kubernetes.io/part-of: cluster-chronicles`
are on every object.

---

## 4. The application

Images: `zeek14/chronicles-backend:<commit>` and `zeek14/chronicles-frontend:<commit>`
on Docker Hub. Both run as UID 10001 (non-root).

- **backend** (`manifests/backend/`) - Deployment with 1 replica, port 3000.
  `/api/metrics` returns the node's CPU, memory and OS facts, `/health` for
  probes, `/metrics` for Prometheus. Service `backend` (ClusterIP :3000).
- **frontend** (`manifests/frontend/`) - Deployment with 2 replicas, port 8080.
  Renders the page, calls the backend at `BACKEND_URL=http://backend:3000`
  (from the ConfigMap `frontend-config`). Service `frontend` (ClusterIP :80 → 8080).
- **Probes:** liveness and readiness on `/health`. A pod only receives traffic
  once its readiness probe passes, which is what makes rolling updates safe.
- **Resources:** every container has CPU/memory requests (what the scheduler
  reserves) and limits (the maximum).
- **Security context:** `runAsNonRoot`, `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`.
- **HPA** (`manifests/frontend/hpa.yaml`): 2-5 frontend pods, target 50% CPU
  of the request. metrics-server supplies the CPU numbers.
- **Logs:** one JSON line per request on stdout (method, path, status,
  duration), which Fluent Bit picks up.
- **Metrics:** prometheus-fastapi-instrumentator (request count, duration
  histogram) plus custom metrics: `metrics_collect_seconds` (backend) and
  `frontend_backend_errors_total{reason}` (frontend).

---

## 5. Storage

`manifests/storage/`

- **StorageClass `manual`** (no provisioner): PVs are created by hand and
  matched to PVCs by a label selector (`storage.cluster-chronicles/for`), so
  each PVC gets exactly the PV meant for it.
- **5 hostPath PVs** under `/data` on the node, `ReadWriteOnce`,
  `persistentVolumeReclaimPolicy: Retain`:
  - `jenkins-home` 5Gi - Jenkins configuration, jobs, build history, plugin cache
  - `prometheus-data` 5Gi - metrics (retention 3 days / 3 GB)
  - `grafana-data` 1Gi - Grafana database
  - `elasticsearch-data-0`, `elasticsearch-data-1` 4Gi each - log indices
- hostPath folders are created as root, so pods that run as non-root get an
  **init container** with only the CHOWN capability that hands the folder to
  their user once (Jenkins 1000, Prometheus 1000:2000, Elasticsearch 1000).
- `ReadWriteOnce` fits: each volume belongs to exactly one pod.
- Disk is the tight resource (40 GB VM disk), so every data store has a size
  or time limit.

---

## 6. CI/CD

```
git push ─► Gitea ◄── Jenkins polls every minute
                         │ starts a build pod in "cicd" (ci/build-agent-pod.yaml)
                         ▼
 Version ─► Code checks ─► Build & push ─► Image scan ─► Deploy ─► Smoke test ─► Load test
 (commit)   ruff/bandit/    Kaniko          Trivy        kubectl    through the     k6
            pytest                          gate         set image  Ingress
                                                            │
                         any failure after Deploy ──► redeploy previous version ─► smoke test
                         every result ──► Slack
```

- **Jenkins** (`manifests/cicd/`) runs as a **StatefulSet** with 1 replica and
  its own PVC: one stable pod name, one disk, never two copies writing to the
  same home folder.
- **Configuration as code:** `jenkins-casc.yaml` holds `casc.yaml` (security,
  credentials, the Kubernetes cloud, the pipeline job via Job DSL) and
  `plugins.txt`. No click-setup; the whole Jenkins is rebuilt from Git.
- **Plugins** are cached on the Jenkins disk and only downloaded again when
  `plugins.txt` changes, so a restart doesn't depend on the internet.
- **Build pod** containers: `jnlp` (agent), `tools` (alpine: git, curl,
  kubectl), `python` (code checks), `kaniko` (image build), `trivy` (scan),
  `k6` (load test). All non-root except Kaniko.
- **Kaniko** builds images from a Dockerfile inside a normal pod, without a
  Docker daemon and without privileged mode, then pushes to Docker Hub.
- **Trivy gate:** reports HIGH + CRITICAL, fails the build on any CRITICAL
  vulnerability that has a fix.
- **Deploy** (`ci/deploy.sh`): `kubectl set image` on both Deployments plus a
  change-cause annotation, then `kubectl rollout status`. Kubernetes does the
  rolling update.
- **Smoke test** (`scripts/smoke-test.sh`): every request must return 200 and
  show the new frontend and backend version, and at least 2 different frontend
  pods must answer (load balancing). It waits up to 30 requests for the second
  pod to join the load balancer.
- **Rollback:** the version that was live before the build is read at the
  start. If deploy, smoke test or load test fails, that version is deployed
  again and smoke-tested.

**RBAC** (`manifests/cicd/rbac.yaml`):

- ServiceAccount `jenkins` (the controller): may manage pods in `cicd` only,
  to start and stop build pods.
- ServiceAccount `jenkins-deployer` (the build pods): a Role in `app`
  (`app-deployer`) that may read and update Deployments and read what a
  rollout needs to follow, bound with a RoleBinding in `app`. It cannot read
  Secrets, touch other namespaces or delete namespaces (checked by `validate.sh`).

---

## 7. Monitoring and alerting

Installed with Helm: **kube-prometheus-stack** (release `kps`, values in
`manifests/monitoring/values.yaml`).

- **Prometheus Operator** watches ServiceMonitor and PrometheusRule objects and
  turns them into Prometheus configuration - an Operator in practice.
- **Prometheus** (retention 3 days / 3 GB, PV `prometheus-data`) scrapes:
  the API server, kubelet/cAdvisor (container metrics), node-exporter (node),
  kube-state-metrics (object state), CoreDNS, the app (ServiceMonitor `app`),
  Fluent Bit and the Elasticsearch exporter. All found by service discovery.
- Minikube's etcd, scheduler, controller manager and kube-proxy listen only on
  127.0.0.1 inside the node, so they are switched off as targets instead of
  being permanently DOWN.
- **Grafana** (PV `grafana-data`, login from a Secret). Dashboards are
  ConfigMaps generated by `scripts/build-dashboards.py`; the sidecar loads
  every ConfigMap labelled `grafana_dashboard: "1"` into the folder
  "Cluster Chronicles":
  - Cluster Performance - nodes ready, pods running/pending/failed, CPU,
    memory, disk (/var), load
  - Pods and Containers - CPU, memory, memory vs limit, restarts, waiting containers
  - Application Performance - requests per second, error rate, response time
    percentiles, frontend replicas (HPA)
- **Alert rules** (`manifests/monitoring/alert-rules.yaml`, PrometheusRule,
  all labelled `project: cluster-chronicles`):
  - NodeHighCPU - CPU above 80% for 5 minutes
  - NodeLowDiskSpace - less than 20% free on `/var` for 1 minute
  - NodeHighMemory - memory above 90% for 5 minutes
  - PodFrequentRestarts - more than 3 restarts in 15 minutes
  - ContainerMemoryNearLimit - container above 80% of its memory limit for 1 minute
  - PodPendingTooLong - pod Pending for 5 minutes
  - KubeAPIServerDown - no API server target up for 1 minute
  - ElasticsearchClusterNotGreen - yellow or red for 1 minute
  - FluentBitOutputErrors - any error or given-up retry, or more than 5
    retries in 5 minutes, for 2 minutes
  - FluentBitNoLogsCollected - no log lines read for 5 minutes (wrong input path)
- **Alertmanager** routing: alerts with `project="cluster-chronicles"` go to
  Slack, everything else (the chart's ~100 standard alerts) to a `null`
  receiver. Against alert fatigue: `group_by [alertname, namespace, pod,
  instance]`, `group_wait 30s`, `group_interval 5m`, `repeat_interval 4h`.
  The Slack webhook is read from a mounted Secret file.

---

## 8. Logging (EFK)

`manifests/logging/`

- **Elasticsearch 8.19** StatefulSet with 2 pods:
  - `elasticsearch-0` - master + data + ingest (the only master-eligible node,
    so 2 nodes never have to vote between equal masters)
  - `elasticsearch-1` - data + ingest, holds the replica copy of every index
  - heap 512 MB, disk watermarks 3gb / 2gb / 1gb (absolute, fits the small disk)
  - security switched off to keep the lab small; instead it has no Ingress and
    network policies allow port 9200 only from its clients
- **Setup Job** (`elasticsearch-ilm-job.yaml`): ILM policy `k8s-logs` deletes
  indices after 3 days; index template maps strings as keyword, `log` and
  `MESSAGE` as full text, 1 replica.
- **Fluent Bit 5.1** DaemonSet (one pod per node):
  - `tail` input for app containers (`*_app_*.log`), with Kubernetes metadata
    and JSON parsing of the app's log lines (into the `app` field)
  - `tail` input for all other containers (metadata, no JSON parsing - other
    tools' JSON clashes in field types)
  - `systemd` input for the node journal (kubelet, containerd)
  - outputs: `k8s-containers-YYYY.MM.DD` and `k8s-node-YYYY.MM.DD`
  - read positions kept in a hostPath database, so restarts don't re-send logs
- **Kibana 8.19** with an import Job that loads 21 saved objects from a
  ConfigMap: 2 data views and 3 dashboards (Cluster Logs, Application Logs,
  Pod and Container Logs).
- **Elasticsearch exporter** turns cluster health into Prometheus metrics for
  the ElasticsearchClusterNotGreen alert.

---

## 9. Security summary

- **Least privilege containers:** non-root, no privilege escalation,
  capabilities dropped, seccomp, Pod Security levels per namespace.
- **RBAC:** two Jenkins ServiceAccounts with only the rights each needs.
- **NetworkPolicies** (`security/network-policies/`, 22 policies, enforced by kindnet):
  - app and logging: default deny in and out, then allow only the real paths
    (ingress-nginx → frontend → backend, Prometheus → metrics ports, Fluent
    Bit/Kibana/exporter → Elasticsearch, DNS, kubelet probes)
  - cicd and monitoring: default deny incoming; outgoing stays open because
    Jenkins and Alertmanager must reach Gitea, Docker Hub and Slack, whose IPs
    change
- **Secrets:** created from a git-ignored file, mounted as files where
  possible, never printed (see the README).

---

## 10. Design choices and trade-offs

- **Minikube with the Docker driver** - what the brief asks for; one node, so
  no real node failover. The Proxmox VM gives it 16 vCPU and 128 GB.
- **128 GB RAM, Minikube limit 124 GB** - the memory alert needs the node above
  90%; the last 10% must still be enough for Elasticsearch, Prometheus and
  Jenkins, or the node stops responding (seen with 48 GB / 40 GB).
- **hostPath PVs** - simplest persistent storage on one node. In production:
  a CSI driver (Ceph, Longhorn, cloud disks) with dynamic provisioning.
- **Jenkins** - mature, self-hosted, pipeline as code (Jenkinsfile with
  Trivy, rollback and Slack); the Kubernetes plugin gives a fresh build pod
  per build.
- **Polling instead of a webhook** - Gitea is on the internet, Jenkins is on a
  home network without a public address, so Gitea can't call Jenkins.
- **Kaniko instead of Docker-in-Docker** - no privileged pod, no Docker socket.
- **kube-prometheus-stack via Helm** - Operator, CRDs, exporters and standard
  rules in one tested chart; the project's own parts are plain YAML on top.
- **Fluent Bit instead of Fluentd** - much lighter (one small binary per node),
  enough for collecting and forwarding.
- **Dashboards as code** - generated by a Python script, reviewed in Git,
  loaded automatically; nothing hand-built in the UI that could be lost.
