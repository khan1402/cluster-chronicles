#!/usr/bin/env bash
# create-vm.sh - create the "minikube" VM on Proxmox from template 9000.
#
# Runs ON the Proxmox host (copied there with scp, see the run steps):
#   bash /root/create-vm.sh
#
# Needs the laptop's public key at /root/cluster-chronicles.pub on the host.
# Safe to run again: it stops if the VM already exists.
set -euo pipefail

TEMPLATE_ID=9000
VMID=500
NAME=minikube
CORES=16
MEMORY_MB=49152            # 48 GB
DISK_SIZE=40G              # the pool has ~48 GB in total
VM_IP=192.168.0.122        # must be OUTSIDE the router's DHCP range
GATEWAY=192.168.0.1
CI_USER=devops
SSH_KEY=/root/cluster-chronicles.pub

# --- Safety checks -------------------------------------------------------------
[[ -f "$SSH_KEY" ]] || { echo "ERROR: $SSH_KEY not found - copy the public key first"; exit 1; }

if qm status "$VMID" &>/dev/null; then
  echo "VM $VMID already exists - nothing to do."
  exit 0
fi

if ping -c 1 -W 1 "$VM_IP" &>/dev/null; then
  echo "ERROR: something already answers on $VM_IP - pick another IP"
  exit 1
fi

# --- Create ---------------------------------------------------------------------
# Linked clone (no --full): the VM shares the template's base disk and stores
# only its own changes. Starts at ~1-2 GB instead of a full 20 GB copy.
echo "==> Linked clone: template $TEMPLATE_ID -> VM $VMID ($NAME)"
qm clone "$TEMPLATE_ID" "$VMID" --name "$NAME"

# Find the VM's main disk (scsi0, virtio0, ...) and its current settings.
DISK="$(qm config "$VMID" | grep -E '^(scsi|virtio|sata)[0-9]+:' | grep -v cloudinit | head -1 | cut -d: -f1)"
SPEC="$(qm config "$VMID" | grep -E "^${DISK}:" | sed -E "s/^${DISK}: //; s/,size=[^,]*//")"

# cpu host   : the VM sees the real Xeon CPU features (faster than the default)
# balloon 0  : fixed memory - Kubernetes and Elasticsearch expect RAM not to shrink
# onboot 1   : the VM starts by itself when the server is powered on
echo "==> CPU, memory, user, SSH key, network"
qm set "$VMID" \
  --cores "$CORES" --cpu host \
  --memory "$MEMORY_MB" --balloon 0 \
  --ciuser "$CI_USER" --sshkeys "$SSH_KEY" \
  --ipconfig0 "ip=${VM_IP}/24,gw=${GATEWAY}" --nameserver "$GATEWAY" \
  --agent enabled=1 --onboot 1

# discard=on: files deleted inside the VM give their space back to the thin pool.
# Without it, the pool only ever grows.
echo "==> Disk $DISK: discard on, grow to $DISK_SIZE"
if [[ "$SPEC" != *discard=* ]]; then
  qm set "$VMID" --"$DISK" "${SPEC},discard=on,ssd=1"
fi
qm resize "$VMID" "$DISK" "$DISK_SIZE"

# --- Start ------------------------------------------------------------------------
echo "==> Starting VM $VMID"
qm start "$VMID"

echo "==> Waiting for SSH on $VM_IP (first boot runs cloud-init, 1-3 min)"
for _ in $(seq 1 60); do
  if timeout 2 bash -c "</dev/tcp/${VM_IP}/22" 2>/dev/null; then
    echo "VM is up: ssh ${CI_USER}@${VM_IP}"
    exit 0
  fi
  sleep 5
done

echo "WARNING: no SSH after 5 minutes - open the VM console in Proxmox (VM 500 -> Console)"
exit 1