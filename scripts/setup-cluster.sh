#!/usr/bin/env bash
# setup-cluster.sh - turn the fresh "minikube" VM into a Kubernetes host.
#
# Runs ON the minikube VM as the devops user (copied there with scp):
#   bash /tmp/setup-cluster.sh
#
# Safe to run again: every step checks first or is idempotent.
set -euo pipefail

MINIKUBE_CPUS=14          # the VM has 16; 2 stay free for the VM itself
MINIKUBE_MEMORY=40g       # the VM has 48 GB; 8 GB stay free for the VM itself
ADDONS=ingress,metrics-server

# The VM's own address on the home network (source IP of its default route).
VM_IP="$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
echo "==> VM address: ${VM_IP}"

# --- 1. Packages -------------------------------------------------------------------
echo "==> 1/7 Packages: Docker, nginx (TCP forwarder), QEMU guest agent"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker.io nginx libnginx-mod-stream qemu-guest-agent curl ca-certificates
sudo systemctl enable --now docker qemu-guest-agent
sudo usermod -aG docker "$USER"

# --- 2. Kernel settings ----------------------------------------------------------------
# The Minikube node is a container, so it shares this VM's kernel. These
# settings must be made HERE, not inside Kubernetes.
echo "==> 2/7 Kernel settings for Elasticsearch and Fluent Bit"
sudo tee /etc/sysctl.d/90-cluster-chronicles.conf >/dev/null <<'EOF'
# Elasticsearch refuses to start below this value (memory-mapped files)
vm.max_map_count = 262144
# Fluent Bit and the kubelet watch many log files at once
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system >/dev/null

# --- 3. Tools -----------------------------------------------------------------------------
echo "==> 3/7 kubectl, minikube, helm"
if ! command -v kubectl >/dev/null; then
  KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi
if ! command -v minikube >/dev/null; then
  curl -fsSLo /tmp/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  sudo install -m 0755 /tmp/minikube /usr/local/bin/minikube
fi
if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- 4. Start Minikube ----------------------------------------------------------------------
# driver=docker   : the Kubernetes node runs as a Docker container in this VM
# --apiserver-ips : adds the VM's IP to the API server's TLS certificate, so
#                   kubectl on the laptop can use https://VM_IP:8443
# sg docker       : use the new docker group right away, without logging out
echo "==> 4/7 Starting Minikube (first run downloads ~1 GB, 5-10 min on this disk)"
sg docker -c "minikube start --driver=docker \
  --cpus=${MINIKUBE_CPUS} --memory=${MINIKUBE_MEMORY} \
  --apiserver-ips=${VM_IP} --addons=${ADDONS}"
MINIKUBE_IP="$(sg docker -c 'minikube ip')"

# --- 5. Start on boot -------------------------------------------------------------------------
# Without this, the cluster stays down after every server power-on.
# ExecStop stops it cleanly when the VM shuts down.
echo "==> 5/7 Minikube starts automatically when the VM boots"
sudo tee /etc/systemd/system/minikube.service >/dev/null <<EOF
[Unit]
Description=Minikube cluster (cluster-chronicles)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${USER}
Group=docker
ExecStart=/usr/local/bin/minikube start
ExecStop=/usr/local/bin/minikube stop
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now minikube.service

# --- 6. Port forwarding -------------------------------------------------------------------------
# The Minikube node (${MINIKUBE_IP}) is on a Docker network the home network
# can't reach. nginx "stream" passes the ports through as plain TCP:
# no TLS termination, no HTTP parsing - Kubernetes still does all of that.
echo "==> 6/7 Forwarding VM ports 80, 443, 8443 to Minikube (${MINIKUBE_IP})"
sudo mkdir -p /etc/nginx/stream.d
sudo tee /etc/nginx/stream.d/minikube.conf >/dev/null <<EOF
server { listen 80;   proxy_pass ${MINIKUBE_IP}:80;   }   # Ingress (HTTP)
server { listen 443;  proxy_pass ${MINIKUBE_IP}:443;  }   # Ingress (HTTPS)
server { listen 8443; proxy_pass ${MINIKUBE_IP}:8443; }   # Kubernetes API (kubectl)
EOF
sudo rm -f /etc/nginx/sites-enabled/default      # frees port 80 for the forwarder
if ! grep -q 'stream.d' /etc/nginx/nginx.conf; then
  printf '\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' | sudo tee -a /etc/nginx/nginx.conf >/dev/null
fi
sudo nginx -t
sudo systemctl enable nginx
sudo systemctl restart nginx

# --- 7. Check ----------------------------------------------------------------------------------------
echo "==> 7/7 Checking the cluster"
kubectl get nodes
kubectl wait --namespace ingress-nginx --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=300s
kubectl get pods -n kube-system -l k8s-app=metrics-server

echo
echo "Done."
echo "  Ingress (browser):    http://${VM_IP}/"
echo "  Kubernetes API:       https://${VM_IP}:8443"