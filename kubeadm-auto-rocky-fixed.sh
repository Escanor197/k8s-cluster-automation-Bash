#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# kubeadm 1-master + 2-worker automation - FIXED Calico + Rocky resolver flow
# Master OS: Ubuntu
# Worker OS: Rocky Linux / RHEL compatible
# Runtime: CRI-O v1.36
# Kubernetes: v1.36 latest patch from pkgs.k8s.io v1.36 repo
# CNI: Calico v3.32.0
# Rocky fix: forces kubelet to use /etc/resolv.conf and creates /run/systemd/resolve/resolv.conf compatibility file
# ==========================================================

# -------- EDIT THESE VALUES TO MATCH YOUR LAB NETWORK --------
MASTER_HOSTNAME="k8s-master"
WORKER1_HOSTNAME="k8s-worker1"
WORKER2_HOSTNAME="k8s-worker2"

MASTER_IP="192.168.129.130"
WORKER1_IP="192.168.129.131"
WORKER2_IP="192.168.129.132"

PREFIX="24"
GATEWAY="192.168.129.2"
DNS_SERVERS="8.8.8.8,1.1.1.1"

POD_CIDR="192.168.0.0/16"
SERVICE_CIDR="10.96.0.0/12"

KUBERNETES_VERSION="v1.36"
CRIO_VERSION="v1.36"
CALICO_VERSION="v3.32.0"

# Set to false if IPs are already configured manually.
ASSIGN_STATIC_IP="true"

# Optional: set a specific interface, for example ens33. Leave empty for auto-detect.
NET_IFACE=""
# ------------------------------------------------------------

ROLE="${1:-}"
JOIN_COMMAND="${2:-}"

usage() {
  cat <<EOF_USAGE
Usage:
  sudo bash $0 master
  sudo bash $0 worker1 "kubeadm join ..."
  sudo bash $0 worker2 "kubeadm join ..."
  sudo bash $0 reset

Run reset on all nodes only when you want to destroy the current kubeadm cluster state and start again.
EOF_USAGE
}

if [[ -z "$ROLE" ]]; then
  usage
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0 $ROLE"
  exit 1
fi

log() {
  echo -e "\n[INFO] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

node_ip_for_role() {
  case "$ROLE" in
    master)  echo "$MASTER_IP" ;;
    worker1) echo "$WORKER1_IP" ;;
    worker2) echo "$WORKER2_IP" ;;
    *) fail "Invalid role: $ROLE. Use master, worker1, worker2, or reset." ;;
  esac
}

node_hostname_for_role() {
  case "$ROLE" in
    master)  echo "$MASTER_HOSTNAME" ;;
    worker1) echo "$WORKER1_HOSTNAME" ;;
    worker2) echo "$WORKER2_HOSTNAME" ;;
    *) fail "Invalid role: $ROLE. Use master, worker1, worker2, or reset." ;;
  esac
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "${ID,,}"
  else
    fail "Cannot detect OS. /etc/os-release not found."
  fi
}

detect_iface() {
  if [[ -n "$NET_IFACE" ]]; then
    echo "$NET_IFACE"
    return
  fi
  ip route show default | awk '{print $5; exit}'
}

set_hostname_and_hosts() {
  local node_hostname="$1"
  log "Setting hostname to $node_hostname"
  hostnamectl set-hostname "$node_hostname"

  sed -i '/# K8S_CLUSTER_START/,/# K8S_CLUSTER_END/d' /etc/hosts
  cat >> /etc/hosts <<EOF_HOSTS
# K8S_CLUSTER_START
${MASTER_IP}  ${MASTER_HOSTNAME}
${WORKER1_IP} ${WORKER1_HOSTNAME}
${WORKER2_IP} ${WORKER2_HOSTNAME}
# K8S_CLUSTER_END
EOF_HOSTS
}

configure_static_ip_ubuntu() {
  local iface="$1"
  local ip_addr="$2"
  log "Configuring static IP on Ubuntu: ${ip_addr}/${PREFIX} via ${iface}"

  mkdir -p /root/netplan-backup
  cp -a /etc/netplan/*.yaml /root/netplan-backup/ 2>/dev/null || true

  cat > /etc/netplan/99-k8s-static.yaml <<EOF_NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${ip_addr}/${PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_SERVERS}]
EOF_NETPLAN
  chmod 600 /etc/netplan/99-k8s-static.yaml
  netplan apply
}

configure_static_ip_rocky() {
  local iface="$1"
  local ip_addr="$2"
  log "Configuring static IP on Rocky/RHEL: ${ip_addr}/${PREFIX} via ${iface}"

  systemctl enable --now NetworkManager 2>/dev/null || true

  local con_name
  con_name=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v dev="$iface" '$2 == dev {print $1; exit}')
  if [[ -z "$con_name" ]]; then
    fail "No active NetworkManager connection found for interface $iface"
  fi

  nmcli connection modify "$con_name" \
    ipv4.method manual \
    ipv4.addresses "${ip_addr}/${PREFIX}" \
    ipv4.gateway "${GATEWAY}" \
    ipv4.dns "${DNS_SERVERS}"
  nmcli connection up "$con_name"
}

configure_static_ip() {
  if [[ "$ASSIGN_STATIC_IP" != "true" ]]; then
    log "Static IP assignment skipped because ASSIGN_STATIC_IP=false"
    return
  fi

  local os_id="$1"
  local node_ip="$2"
  local iface
  iface=$(detect_iface)
  [[ -n "$iface" ]] || fail "Could not detect default network interface. Set NET_IFACE manually."

  case "$os_id" in
    ubuntu) configure_static_ip_ubuntu "$iface" "$node_ip" ;;
    rocky|rhel|centos|almalinux) configure_static_ip_rocky "$iface" "$node_ip" ;;
    *) fail "Unsupported OS for static IP automation: $os_id" ;;
  esac
}

disable_swap_and_prepare_kernel() {
  log "Disabling swap and preparing kernel settings"
  swapoff -a || true
  sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

  cat > /etc/modules-load.d/k8s.conf <<'EOF_MODULES'
overlay
br_netfilter
EOF_MODULES
  modprobe overlay
  modprobe br_netfilter

  cat > /etc/sysctl.d/k8s.conf <<'EOF_SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF_SYSCTL
  sysctl --system >/dev/null
}

disable_firewall_for_lab() {
  log "Disabling local firewall for lab connectivity"
  systemctl disable --now firewalld 2>/dev/null || true
  ufw disable 2>/dev/null || true
}

set_selinux_permissive_if_present() {
  if command -v getenforce >/dev/null 2>&1; then
    log "Setting SELinux to permissive"
    setenforce 0 || true
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
  fi
}

install_crio_and_kubernetes_ubuntu() {
  log "Installing CRI-O and Kubernetes on Ubuntu"
  apt-get update
  apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common
  mkdir -p -m 755 /etc/apt/keyrings

  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/Release.key" \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  curl -fsSL "https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/Release.key" \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/cri-o.list

  apt-get update
  apt-get install -y cri-o kubelet kubeadm kubectl
  apt-mark hold cri-o kubelet kubeadm kubectl
}

install_crio_and_kubernetes_rocky() {
  log "Installing CRI-O and Kubernetes on Rocky/RHEL"
  dnf install -y curl iproute-tc conntrack-tools socat ebtables ethtool NetworkManager
  dnf install -y container-selinux || true

  cat > /etc/yum.repos.d/kubernetes.repo <<EOF_K8S_REPO
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${KUBERNETES_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF_K8S_REPO

  cat > /etc/yum.repos.d/cri-o.repo <<EOF_CRIO_REPO
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/${CRIO_VERSION}/rpm/repodata/repomd.xml.key
EOF_CRIO_REPO

  dnf install -y cri-o kubelet kubeadm kubectl --disableexcludes=kubernetes
}

configure_crio() {
  log "Configuring and starting CRI-O"
  mkdir -p /etc/crio/crio.conf.d
  cat > /etc/crio/crio.conf.d/02-cgroup-manager.conf <<'EOF_CRIO'
[crio.runtime]
cgroup_manager = "systemd"
EOF_CRIO
  systemctl daemon-reload
  systemctl enable --now crio
  systemctl restart crio
}

enable_kubelet() {
  log "Enabling kubelet"
  systemctl enable --now kubelet || true
}

fix_rocky_kubelet_resolver() {
  local node_ip="$1"

  log "Applying Rocky/RHEL kubelet DNS resolver compatibility fix"

  # Rocky/RHEL nodes may not have /run/systemd/resolve/resolv.conf.
  # Some kubelet/CRI-O combinations still try to use it, which causes:
  # FailedCreatePodSandBox: open /run/systemd/resolve/resolv.conf: no such file or directory
  mkdir -p /run/systemd/resolve

  if [[ -f /etc/resolv.conf ]]; then
    # Use a real file, not a symlink. This was confirmed to work on Rocky workers.
    cp -fL /etc/resolv.conf /run/systemd/resolve/resolv.conf
  else
    cat > /etc/resolv.conf <<EOF_RESOLV
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF_RESOLV
    cp -fL /etc/resolv.conf /run/systemd/resolve/resolv.conf
  fi
  chmod 644 /run/systemd/resolve/resolv.conf

  # Recreate the compatibility file after reboot because /run is tmpfs.
  cat > /etc/tmpfiles.d/k8s-rocky-resolv.conf <<'EOF_TMPFILES'
d /run/systemd/resolve 0755 root root -
C /run/systemd/resolve/resolv.conf 0644 root root - /etc/resolv.conf
EOF_TMPFILES
  systemd-tmpfiles --create /etc/tmpfiles.d/k8s-rocky-resolv.conf || true

  # Force kubelet to use Rocky's resolver path and the expected node IP.
  mkdir -p /etc/systemd/system/kubelet.service.d
  cat > /etc/systemd/system/kubelet.service.d/20-rocky-resolv.conf <<EOF_KUBELET_DROPIN
[Service]
Environment="KUBELET_EXTRA_ARGS=--resolv-conf=/etc/resolv.conf --node-ip=${node_ip}"
EOF_KUBELET_DROPIN

  cat > /etc/sysconfig/kubelet <<EOF_SYSCONFIG
KUBELET_EXTRA_ARGS=--resolv-conf=/etc/resolv.conf --node-ip=${node_ip}
EOF_SYSCONFIG

  # kubeadm creates this file during init/join. If it exists, correct it.
  if [[ -f /var/lib/kubelet/config.yaml ]]; then
    sed -i 's#/run/systemd/resolve/resolv.conf#/etc/resolv.conf#g' /var/lib/kubelet/config.yaml || true
    if grep -q '^resolvConf:' /var/lib/kubelet/config.yaml; then
      sed -i 's#^resolvConf:.*#resolvConf: /etc/resolv.conf#g' /var/lib/kubelet/config.yaml || true
    else
      echo 'resolvConf: /etc/resolv.conf' >> /var/lib/kubelet/config.yaml
    fi
  fi

  if [[ -f /var/lib/kubelet/kubeadm-flags.env ]]; then
    sed -i 's#/run/systemd/resolve/resolv.conf#/etc/resolv.conf#g' /var/lib/kubelet/kubeadm-flags.env || true
  fi

  systemctl daemon-reload
  systemctl restart crio 2>/dev/null || true
  systemctl restart kubelet 2>/dev/null || true

  log "Resolver compatibility file: $(ls -l /run/systemd/resolve/resolv.conf 2>/dev/null || echo missing)"
}

install_common() {
  local os_id="$1"
  local node_ip="${2:-}"
  case "$os_id" in
    ubuntu) install_crio_and_kubernetes_ubuntu ;;
    rocky|rhel|centos|almalinux) install_crio_and_kubernetes_rocky ;;
    *) fail "Unsupported OS: $os_id. Use Ubuntu for master and Rocky/RHEL-compatible OS for workers." ;;
  esac
  configure_crio
  enable_kubelet

  case "$os_id" in
    rocky|rhel|centos|almalinux) fix_rocky_kubelet_resolver "$node_ip" ;;
  esac
}

wait_for_crd() {
  local crd="$1"
  local timeout_seconds="${2:-180}"
  local elapsed=0

  until kubectl --kubeconfig=/etc/kubernetes/admin.conf get crd "$crd" >/dev/null 2>&1; do
    if (( elapsed >= timeout_seconds )); then
      fail "Timed out waiting for CRD: $crd"
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  kubectl --kubeconfig=/etc/kubernetes/admin.conf wait \
    --for=condition=Established "crd/${crd}" \
    --timeout=120s
}

install_calico() {
  log "Installing Calico CNI ${CALICO_VERSION} with CRD wait/retry"

  kubectl --kubeconfig=/etc/kubernetes/admin.conf apply \
    -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

  log "Waiting for Tigera Operator CRDs to be registered"
  wait_for_crd "installations.operator.tigera.io" 240
  wait_for_crd "apiservers.operator.tigera.io" 240
  wait_for_crd "goldmanes.operator.tigera.io" 240
  wait_for_crd "whiskers.operator.tigera.io" 240

  kubectl --kubeconfig=/etc/kubernetes/admin.conf -n tigera-operator rollout status \
    deployment/tigera-operator --timeout=240s || true

  curl -fsSL -o /root/calico-custom-resources.yaml \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml"

  sed -i "s#cidr: 192.168.0.0/16#cidr: ${POD_CIDR}#g" /root/calico-custom-resources.yaml

  log "Applying Calico custom resources"
  local attempt
  for attempt in {1..12}; do
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf apply -f /root/calico-custom-resources.yaml; then
      log "Calico custom resources applied successfully"
      break
    fi
    if [[ "$attempt" == "12" ]]; then
      fail "Failed to apply Calico custom resources after multiple retries"
    fi
    log "Calico CRDs are not ready yet. Retrying in 10 seconds. Attempt ${attempt}/12"
    sleep 10
  done

  log "Waiting for Calico pods to start"
  kubectl --kubeconfig=/etc/kubernetes/admin.conf wait \
    --for=condition=Available deployment/tigera-operator \
    -n tigera-operator --timeout=240s || true

  # calico-system namespace is created after the Installation resource is processed.
  for attempt in {1..24}; do
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get namespace calico-system >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n tigera-operator || true
  kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n calico-system || true
}

initialize_master() {
  log "Initializing Kubernetes control plane"

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    log "Kubernetes is already initialized on this master. Skipping kubeadm init."
  else
    local local_k8s_version
    local_k8s_version=$(kubeadm version -o short)

    kubeadm init \
      --apiserver-advertise-address="$MASTER_IP" \
      --control-plane-endpoint="${MASTER_IP}:6443" \
      --pod-network-cidr="$POD_CIDR" \
      --service-cidr="$SERVICE_CIDR" \
      --cri-socket="unix:///var/run/crio/crio.sock" \
      --kubernetes-version="$local_k8s_version"
  fi

  mkdir -p /root/.kube
  cp -f /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config

  local sudo_user="${SUDO_USER:-}"
  if [[ -n "$sudo_user" && "$sudo_user" != "root" && -d "/home/$sudo_user" ]]; then
    mkdir -p "/home/$sudo_user/.kube"
    cp -f /etc/kubernetes/admin.conf "/home/$sudo_user/.kube/config"
    chown -R "$sudo_user:$sudo_user" "/home/$sudo_user/.kube"
  fi

  install_calico

  log "Creating worker join command"
  kubeadm token create --print-join-command > /root/kubeadm-join-command.sh
  chmod 600 /root/kubeadm-join-command.sh

  echo -e "\n============================================================"
  echo "MASTER IS READY. Run this command on each worker:"
  cat /root/kubeadm-join-command.sh
  echo "============================================================"
}

join_worker() {
  log "Joining worker node to the cluster"

  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    log "This node already appears joined. Skipping kubeadm join."
    return
  fi

  if [[ -z "$JOIN_COMMAND" ]]; then
    echo -e "\nWorker preparation is complete. Now get the join command from the master:"
    echo "sudo cat /root/kubeadm-join-command.sh"
    echo -e "Then run on this worker, example:\n"
    echo "sudo bash $0 $ROLE \"kubeadm join ${MASTER_IP}:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>\""
    return
  fi

  # shellcheck disable=SC2086
  $JOIN_COMMAND --cri-socket="unix:///var/run/crio/crio.sock"

  # kubeadm join creates /var/lib/kubelet/config.yaml, so apply the Rocky resolver fix again after join.
  case "$(detect_os)" in
    rocky|rhel|centos|almalinux)
      fix_rocky_kubelet_resolver "$(node_ip_for_role)"
      ;;
  esac
}

reset_cluster() {
  log "Resetting kubeadm/Kubernetes state on this node"

  systemctl stop kubelet 2>/dev/null || true

  if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f --cri-socket="unix:///var/run/crio/crio.sock" || kubeadm reset -f || true
  fi

  rm -rf /etc/kubernetes \
         /var/lib/etcd \
         /etc/cni/net.d \
         /var/lib/cni \
         /root/.kube \
         /root/calico-custom-resources.yaml \
         /root/kubeadm-join-command.sh

  rm -f /etc/systemd/system/kubelet.service.d/20-rocky-resolv.conf \
        /etc/tmpfiles.d/k8s-rocky-resolv.conf

  # Clean common CNI interfaces if they exist.
  ip link delete cni0 2>/dev/null || true
  ip link delete flannel.1 2>/dev/null || true
  ip link delete vxlan.calico 2>/dev/null || true
  ip link delete tunl0 2>/dev/null || true

  # Flush Kubernetes/CNI iptables rules for a clean lab reset.
  if command -v iptables >/dev/null 2>&1; then
    iptables -F || true
    iptables -t nat -F || true
    iptables -t mangle -F || true
    iptables -X || true
  fi

  if command -v ipvsadm >/dev/null 2>&1; then
    ipvsadm --clear || true
  fi

  systemctl start crio 2>/dev/null || true
  systemctl start kubelet 2>/dev/null || true

  log "Reset completed on this node"
}

main() {
  if [[ "$ROLE" == "reset" ]]; then
    reset_cluster
    exit 0
  fi

  local os_id node_ip node_hostname
  os_id=$(detect_os)
  node_ip=$(node_ip_for_role)
  node_hostname=$(node_hostname_for_role)

  if [[ "$ROLE" == "master" && "$os_id" != "ubuntu" ]]; then
    fail "Master must be Ubuntu. Detected OS: $os_id"
  fi
  if [[ "$ROLE" == worker* && "$os_id" != "rocky" && "$os_id" != "rhel" && "$os_id" != "centos" && "$os_id" != "almalinux" ]]; then
    fail "Workers must be Rocky/RHEL-compatible. Detected OS: $os_id"
  fi

  configure_static_ip "$os_id" "$node_ip"
  set_hostname_and_hosts "$node_hostname"
  disable_swap_and_prepare_kernel
  disable_firewall_for_lab
  set_selinux_permissive_if_present
  install_common "$os_id" "$node_ip"

  if [[ "$ROLE" == "master" ]]; then
    initialize_master
  else
    join_worker
  fi

  log "Done for role: $ROLE"
}

main
