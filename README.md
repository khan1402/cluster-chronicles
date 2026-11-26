# cluster chronicles 📜

The sherlock-logs system (Project 4) moved from separate VMs to **Kubernetes**.
The same FastAPI app, CI/CD pipeline and monitoring goals now run as pods in
one Minikube cluster: the app, Jenkins, Prometheus + Grafana + Alertmanager,
and the EFK logging stack (Elasticsearch, Fluent Bit, Kibana).

Everything is declarative and lives in this repository: manifests, Helm values,
dashboards, alert rules, network policies and scripts. One command installs it
all (`scripts/deploy-all.sh`) and one command checks it all (`scripts/validate.sh`).

- [Architecture](docs/architecture.md) - how the parts fit together
- [Notes](docs/notes.md) - what was built, every problem hit and how it was fixed
- [Review guide](docs/review-guide.md) - answers and demos for every review question

---

## Overview

```
Browser (home network)
   │  http://192.168.0.122/  and  http://<tool>.192.168.0.122.nip.io/
   ▼
Proxmox VM 500 "minikube" (192.168.0.122) - 16 vCPU, 128 GB RAM, 40 GB disk
   │  nginx stream forwarder: VM ports 80/443/8443 → Minikube node 192.168.49.2
   ▼
Minikube (Docker driver, Kubernetes v1.37) - one node
   ├── ingress-nginx     the front door (Ingress controller addon)
   ├── app               frontend x2 (HPA 2-5) + backend x1
   ├── cicd              Jenkins (StatefulSet) + build pods (Kaniko, Trivy, k6)
   ├── monitoring        Prometheus, Alertmanager, Grafana (kube-prometheus-stack)
   └── logging           Elasticsearch x2, Fluent Bit (DaemonSet), Kibana
```

- **App:** frontend (2 replicas) calls the backend (1 replica) through the
  `backend` Service. ingress-nginx spreads users over the frontend pods. Both
  run as non-root (UID 10001) with probes, requests and limits.
- **CI/CD:** a push to Gitea starts Jenkins (polling every minute). It runs code
  checks, builds images with Kaniko, scans them with Trivy, does a rolling
  deploy with `kubectl set image`, smoke-tests through the Ingress, runs a k6
  load test, and rolls back automatically if anything after the deploy fails.
  Every result goes to Slack.
- **Monitoring:** Prometheus finds its targets by service discovery
  (ServiceMonitors). 3 Grafana dashboards, 10 alert rules, Alertmanager sends
  this project's alerts to Slack with grouping and throttling.
- **Logging:** Fluent Bit reads every container log and the node journal and
  ships them to a 2-node Elasticsearch cluster. Logs are deleted after 3 days
  (ILM). 3 Kibana dashboards.
- **Security:** namespaces with Pod Security levels, RBAC with least privilege,
  22 NetworkPolicies (default deny), Secrets created from a local file that is
  never committed.

## Repository structure

```
app/                     the application (FastAPI + Jinja2)
  backend/               /api/metrics, /health, /metrics + unit tests + Dockerfile
  frontend/              web page, /health, /metrics + unit tests + Dockerfile
  ruff.toml, requirements-dev.txt   lint rules and test tools for the code checks
ci/                      pipeline helpers
  build-agent-pod.yaml   the Jenkins build pod (jnlp, tools, python, kaniko, trivy, k6)
  code-checks.sh         ruff, bandit, pytest
  deploy.sh              rolling deploy / read the live version
  notify.sh              Slack messages
  load-test.js           k6 load test
Jenkinsfile              the pipeline
infra/proxmox/           create-vm.sh - creates the Minikube VM on Proxmox
manifests/               everything that runs in the cluster, one folder per part
  namespaces/            app, cicd, monitoring, logging (+ Pod Security levels)
  storage/               StorageClass "manual" + 5 PersistentVolumes
  backend/               Deployment + Service
  frontend/              ConfigMap + Deployment + Service + HPA
  ingress/               Ingresses for the app and every web UI
  cicd/                  Jenkins: ServiceAccounts, RBAC, PVC, config as code, StatefulSet
  monitoring/            Helm values, ServiceMonitor, alert rules, Grafana dashboards
  logging/               Elasticsearch, setup Job, exporter, Fluent Bit, Kibana, dashboards
security/
  network-policies/      default deny + allow lists per namespace
  secrets/               secrets.env.example (the real secrets.env is never committed)
scripts/
  setup-cluster.sh       installs Docker, Minikube, kubectl, addons on the VM
  create-secrets.sh      creates the Kubernetes Secrets from secrets.env
  deploy-all.sh          installs / updates everything in the right order
  validate.sh            53 PASS/FAIL checks of the whole system
  smoke-test.sh          checks the live app through the Ingress
  build-dashboards.py    generates the Grafana and Kibana dashboards
  demo/                  one script per alert + HPA load test + cleanup
docs/                    architecture, notes, review guide
```

## Setup and installation

Where each command runs is written above it.

### 1. Create the VM (Proxmox web Shell: pve → Shell)

```bash
bash create-vm.sh        # copy of infra/proxmox/create-vm.sh
```

A linked clone of template 9000 (Ubuntu 22.04): VM 500 "minikube", 16 vCPU,
128 GB RAM (no ballooning), 40 GB disk with `discard`, static IP 192.168.0.122,
starts on boot. 128 GB matters: the memory alert fires above 90%, and the
remaining 10% must be big enough for Elasticsearch, Prometheus and Jenkins to
keep working during that demo.

### 2. Install the cluster (on the VM: `ssh minikube-vm`)

```bash
bash setup-cluster.sh    # copy of scripts/setup-cluster.sh
```

Installs Docker, Minikube and kubectl, starts Minikube (Docker driver, 16 CPUs,
124 GB) with the `ingress` and `metrics-server` addons, sets the kernel setting
Elasticsearch needs, makes Minikube start on boot, and runs the nginx forwarder
so the cluster is reachable from the home network.

### 3. Connect kubectl from the laptop (WSL)

kubectl in WSL talks to the API server through the VM's forwarder:
`https://192.168.0.122:8443`. The kubeconfig is copied from the VM once and
kept only on the laptop (`~/.kube/config`, never in Git):

```bash
mkdir -p ~/.kube
ssh minikube-vm "kubectl config view --raw --minify --flatten" > ~/.kube/config
sed -i 's#server: https://.*#server: https://192.168.0.122:8443#' ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes        # minikube   Ready
```

### 4. Secrets (WSL, repo root)

```bash
cp security/secrets/secrets.env.example security/secrets/secrets.env
chmod 600 security/secrets/secrets.env
nano security/secrets/secrets.env      # fill in the real values
```

`deploy-all.sh` turns it into Kubernetes Secrets. See [Secrets](#secrets) below.

### 5. Deploy everything (WSL, repo root)

```bash
bash scripts/deploy-all.sh
```

In order: namespaces → storage → secrets → app → Jenkins → monitoring (Helm) →
logging → ingress → network policies, then it waits until every workload is
up. Safe to run again at any time: nothing changes that is already correct,
Jobs are re-created, and the app keeps the image version Jenkins deployed.

### 6. Check it (WSL, repo root)

```bash
bash scripts/validate.sh               # Result: 53 passed, 0 failed
```

## Usage

### Web addresses

- App: http://192.168.0.122/
- Jenkins: http://jenkins.192.168.0.122.nip.io/
- Grafana: http://grafana.192.168.0.122.nip.io/ (folder "Cluster Chronicles")
- Prometheus: http://prometheus.192.168.0.122.nip.io/ (targets, alerts)
- Alertmanager: http://alertmanager.192.168.0.122.nip.io/
- Kibana: http://kibana.192.168.0.122.nip.io/
- Proxmox: https://192.168.0.121:8006

`nip.io` is public DNS: `<anything>.192.168.0.122.nip.io` resolves to
192.168.0.122, so no hosts file is needed.

### Deploy a new version

```bash
git add . && git commit -m "..." && git push origin main
```

Jenkins notices the commit within a minute and runs: Version → Code checks →
Build & push (Kaniko) → Image scan (Trivy) → Deploy → Smoke test → Load test.
Slack gets "Deployed", or "Deploy failed - automatically rolled back".
The version (short commit ID) is shown in the app footer.

### Everyday commands

```bash
kubectl get pods -A                          # everything at a glance
kubectl get pods -n app -o wide
kubectl logs -n app deploy/frontend
kubectl describe pod <name> -n <namespace>
kubectl rollout history deployment/frontend -n app
kubectl get hpa -n app
kubectl get pv,pvc -A
kubectl get networkpolicy -A
```

### Review demos (WSL, repo root)

```bash
bash scripts/demo/demo-mode.sh on            # 5-minute alerts fire after 1 minute
bash scripts/demo/cpu.sh                     # NodeHighCPU
bash scripts/demo/memory.sh                  # NodeHighMemory (run alone)
bash scripts/demo/disk.sh                    # NodeLowDiskSpace       (stop: disk.sh stop)
bash scripts/demo/pod-restarts.sh            # PodFrequentRestarts
bash scripts/demo/container-memory.sh        # ContainerMemoryNearLimit
bash scripts/demo/pod-pending.sh             # PodPendingTooLong
bash scripts/demo/apiserver-down.sh          # KubeAPIServerDown (restores itself)
bash scripts/demo/es-yellow.sh               # ElasticsearchClusterNotGreen (restore: es-yellow.sh restore)
bash scripts/demo/fluentbit-errors.sh        # FluentBitOutputErrors   (restore: fluentbit-errors.sh restore)
bash scripts/demo/hpa-load.sh                # HPA scales the frontend 2 → 5
bash scripts/demo/cleanup.sh                 # undo everything, demo mode off
```

Each script returns within a minute and prints what to expect and where to look.
CPU and memory demos have safety limits and stop by themselves.

### Start and stop

- **Stop:** Proxmox → VM 500 → Shutdown, then pve → Shutdown.
- **Start:** power on the server; the VM and Minikube start by themselves.
  Elasticsearch needs up to 10 minutes after a cold start. Then run
  `bash scripts/validate.sh`.
- **Snapshots** (Proxmox → VM 500 → Snapshots) were taken after every group,
  without RAM.

## Secrets

No password, token or webhook is stored in Git. The real values live in one
local file, `security/secrets/secrets.env` (git-ignored, `chmod 600`).
`scripts/create-secrets.sh` turns it into Kubernetes Secrets; from then on the
values exist only inside the cluster.

Values in `secrets.env` (`NAME=value`, one per line):

- `JENKINS_ADMIN_PASSWORD` - Jenkins admin login
- `GITEA_USERNAME`, `GITEA_TOKEN` - Jenkins reads the repository (read-only token)
- `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` - Kaniko pushes images (access token, not the password)
- `SLACK_WEBHOOK_URL` - Jenkins and Alertmanager post to Slack
- `GRAFANA_ADMIN_PASSWORD` - Grafana admin login

The Secrets in the cluster:

- `cicd/jenkins-secrets` - Jenkins admin password, Gitea login, Slack webhook
- `cicd/dockerhub-push` - type `kubernetes.io/dockerconfigjson`, Docker Hub login for Kaniko
- `monitoring/grafana-admin` - `admin-user` and `admin-password`
- `monitoring/alertmanager-slack` - `url`, the Slack webhook

How `create-secrets.sh` keeps them safe: values go in through `<(printf ...)`
(never on the command line or in `ps`), `kubectl apply --server-side` stores no
copy in a `last-applied-configuration` annotation, and nothing is printed.

How pods use them - both ways Kubernetes offers:

- **Environment variable:** Jenkins gets `JENKINS_ADMIN_PASSWORD` through
  `secretKeyRef`; Jenkins config as code reads `${JENKINS_ADMIN_PASSWORD}`.
- **Files (volume):** Jenkins mounts the Gitea login and Slack webhook at
  `/var/jenkins_secrets/` (mode 0440) and reads them with `${readFile:...}`;
  Kaniko mounts the Docker config at `/kaniko/.docker/config.json`; Alertmanager
  reads the webhook from a mounted file (`slack_api_url_file`); Grafana uses
  `existingSecret`. Files are preferred: an environment variable can leak
  through `env` output or child processes.

Who can read them: the `jenkins-deployer` ServiceAccount (build pods) can only
update Deployments in `app` and can **not** read Secrets (checked by
`validate.sh`). Secrets are namespaced, and Jenkins masks credentials in build
logs (`****`).

Rotation:

1. Create the new value at the source (new token, webhook or password).
2. Put it in `secrets.env` and run `bash scripts/create-secrets.sh`.
3. Restart what uses it:
   ```bash
   kubectl -n cicd rollout restart statefulset/jenkins
   kubectl -n monitoring rollout restart deployment/grafana
   kubectl -n monitoring rollout restart statefulset/alertmanager-kps-alertmanager
   ```
   Kaniko reads `dockerhub-push` fresh in every build pod.
4. Revoke the old value at the source.

Limits: Kubernetes Secrets are only base64-encoded and Minikube does not
encrypt etcd. In production: encryption at rest for etcd, a vault (HashiCorp
Vault or a cloud secret manager) synced by the External Secrets Operator or
Sealed Secrets/SOPS, and short-lived tokens with automatic rotation.

## Extra requirements and bonus features

- **Image scanning (extra):** Trivy scans both images before deployment. HIGH
  and CRITICAL findings are reported; the pipeline fails on any CRITICAL
  vulnerability that has a fix.
- **Horizontal Pod Autoscaler (extra):** the frontend scales 2-5 pods at 50%
  CPU. `scripts/demo/hpa-load.sh` shows it scaling up, and it scales back down
  after the 5-minute stabilisation window.
- **Beyond the requirements:**
  - NetworkPolicies: default deny with allow lists (22 policies), proven by a test pod
  - Pod Security Admission levels per namespace (app: restricted)
  - Kaniko: images built inside the cluster without a Docker daemon or privileged pod
  - Automatic rollback with a smoke test that checks version and load balancing
  - k6 load test in the pipeline
  - Jenkins fully configured as code (JCasC + Job DSL), plugins cached on its disk
  - Grafana and Kibana dashboards generated as code (`build-dashboards.py`)
  - Alertmanager routing: only this project's alerts reach Slack, grouped and throttled
  - Elasticsearch exporter + logging alerts, log retention with ILM
  - `deploy-all.sh` (idempotent install) and `validate.sh` (53 automated checks)
  - Demo scripts with safety limits for every alert
