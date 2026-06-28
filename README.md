# Automated kubeadm Kubernetes Cluster

This repository contains a Bash automation script to build a Kubernetes cluster using `kubeadm`.

The lab architecture is:

| Node | OS | Role | IP Address |
|---|---|---|---|
| `k8s-master` | Ubuntu | Control Plane / Master | `192.168.129.130` |
| `k8s-worker1` | Rocky Linux | Worker | `192.168.129.131` |
| `k8s-worker2` | Rocky Linux | Worker | `192.168.129.132` |

The script installs and configures:

- Kubernetes `v1.36`
- CRI-O `v1.36`
- Calico CNI `v3.32.0`
- Tigera Operator
- Static IP configuration
- Required kernel modules and sysctl settings
- Swap disablement
- Firewall disablement for lab usage
- Rocky Linux kubelet DNS resolver fix

---

## Repository Files

```text
.
├── kubeadm-auto-rocky-fixed.sh
└── README.md
```

---

## What the Script Does

The script automates the full kubeadm cluster setup.

On the **Ubuntu master**, it:

1. Sets the hostname.
2. Configures the static IP.
3. Updates `/etc/hosts`.
4. Disables swap.
5. Loads required kernel modules.
6. Applies Kubernetes sysctl settings.
7. Installs CRI-O.
8. Installs `kubelet`, `kubeadm`, and `kubectl`.
9. Initializes the Kubernetes control plane.
10. Installs Calico CNI using Tigera Operator.
11. Generates the worker join command.

On the **Rocky Linux workers**, it:

1. Sets the hostname.
2. Configures the static IP.
3. Updates `/etc/hosts`.
4. Disables swap.
5. Loads required kernel modules.
6. Applies Kubernetes sysctl settings.
7. Sets SELinux to permissive.
8. Disables firewall for lab usage.
9. Installs CRI-O.
10. Installs `kubelet`, `kubeadm`, and `kubectl`.
11. Applies the Rocky Linux kubelet resolver fix.
12. Joins the node to the Kubernetes cluster.

---

## Network Configuration

Default IP configuration inside the script:

```bash
MASTER_IP="192.168.129.130"
WORKER1_IP="192.168.129.131"
WORKER2_IP="192.168.129.132"

PREFIX="24"
GATEWAY="192.168.129.2"
DNS_SERVERS="8.8.8.8,1.1.1.1"
```

Kubernetes internal network configuration:

```bash
POD_CIDR="192.168.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
```

Update these values before running the script if your lab network is different.

---

## Prerequisites

Prepare three virtual machines:

| Requirement | Master | Workers |
|---|---|---|
| OS | Ubuntu | Rocky Linux |
| CPU | 2 vCPU or more | 2 vCPU or more |
| RAM | 2 GB minimum, 4 GB recommended | 2 GB minimum, 4 GB recommended |
| Internet | Required | Required |
| User | sudo/root access | sudo/root access |

Recommended lab specs:

```text
Master:  2 CPU / 4 GB RAM / 30 GB Disk
Worker1: 2 CPU / 4 GB RAM / 30 GB Disk
Worker2: 2 CPU / 4 GB RAM / 30 GB Disk
```

---

## Important Notes Before Running

Run the script from the VM console if you are changing static IPs.

If you are connected through SSH and the script changes the machine IP, your SSH session may disconnect.

If your IPs are already configured manually, you can disable static IP assignment inside the script:

```bash
ASSIGN_STATIC_IP="false"
```

---

## Usage

Make the script executable on all nodes:

```bash
chmod +x kubeadm-auto-rocky-fixed.sh
```

---

## Step 1: Run on the Master Node

Run this on the Ubuntu master:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh master
```

After the master initialization finishes, get the worker join command:

```bash
sudo cat /root/kubeadm-join-command.sh
```

The output will look similar to this:

```bash
kubeadm join 192.168.129.130:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Copy this command.

---

## Step 2: Run on Worker 1

Run this on Rocky worker 1:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh worker1 "PASTE_JOIN_COMMAND_HERE"
```

Example:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh worker1 "kubeadm join 192.168.129.130:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:xxxxxxxxxxxxxxxxxxxxxxxx"
```

---

## Step 3: Run on Worker 2

Run this on Rocky worker 2:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh worker2 "PASTE_JOIN_COMMAND_HERE"
```

Example:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh worker2 "kubeadm join 192.168.129.130:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:xxxxxxxxxxxxxxxxxxxxxxxx"
```

---

## Validate the Cluster

Run these commands on the master:

```bash
kubectl get nodes -o wide
```

Expected output:

```text
NAME          STATUS   ROLES           AGE   VERSION
k8s-master    Ready    control-plane   10m   v1.36.x
k8s-worker1   Ready    <none>          5m    v1.36.x
k8s-worker2   Ready    <none>          5m    v1.36.x
```

Check all pods:

```bash
kubectl get pods -A
```

Expected important pods:

```text
calico-system     calico-node-xxxxx        1/1 Running
kube-system       coredns-xxxxx            1/1 Running
kube-system       kube-proxy-xxxxx         1/1 Running
tigera-operator   tigera-operator-xxxxx    1/1 Running
```

---

## Reset the Cluster

To reset everything and start again, run this on **all nodes**:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh reset
```

Then run the setup again.

On master:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh master
```

On workers:

```bash
sudo bash kubeadm-auto-rocky-fixed.sh worker1 "PASTE_JOIN_COMMAND_HERE"
sudo bash kubeadm-auto-rocky-fixed.sh worker2 "PASTE_JOIN_COMMAND_HERE"
```

---

## Generate a New Join Command

If the old join command expires, generate a new one from the master:

```bash
sudo kubeadm token create --print-join-command
```

Then use the new command on the workers.

---

## Rocky Linux Worker DNS Resolver Fix

Rocky Linux may not have this file:

```bash
/run/systemd/resolve/resolv.conf
```

When this file is missing, worker pods may get stuck with this error:

```text
FailedCreatePodSandBox: open /run/systemd/resolve/resolv.conf: no such file or directory
```

The script fixes this by:

1. Creating the missing path:

```bash
/run/systemd/resolve/resolv.conf
```

2. Forcing kubelet to use:

```bash
/etc/resolv.conf
```

3. Adding kubelet systemd override:

```bash
KUBELET_EXTRA_ARGS=--resolv-conf=/etc/resolv.conf
```

This fix is required for Rocky workers in this lab.

---

## Calico and Tigera Operator

Kubernetes does not include pod networking by default after `kubeadm init`.

That is why the script installs Calico CNI.

The script uses Tigera Operator to install and manage Calico.

Correct installation order:

```text
1. Install Tigera Operator
2. Wait for Calico/Tigera CRDs
3. Apply Calico custom resources
4. Calico pods start
5. Nodes become Ready
```

This avoids the error:

```text
no matches for kind "Installation" in version "operator.tigera.io/v1"
ensure CRDs are installed first
```

---

## Troubleshooting

### Check node status

```bash
kubectl get nodes -o wide
```

### Check all pods

```bash
kubectl get pods -A
```

### Watch pods in real time

```bash
kubectl get pods -A -w
```

### Describe a stuck pod

```bash
kubectl describe pod -n <namespace> <pod-name>
```

Example:

```bash
kubectl describe pod -n calico-system calico-node-xxxxx
kubectl describe pod -n kube-system kube-proxy-xxxxx
```

### Check kubelet service on a worker

```bash
sudo systemctl status kubelet --no-pager
```

### Check CRI-O service

```bash
sudo systemctl status crio --no-pager
```

### Restart kubelet and CRI-O

```bash
sudo systemctl restart crio
sudo systemctl restart kubelet
```

### Check kubelet logs

```bash
sudo journalctl -u kubelet -f
```

### Check CRI-O logs

```bash
sudo journalctl -u crio -f
```

---

## Common Issues

### Worker stuck in NotReady

Check the worker pods:

```bash
kubectl get pods -A -o wide
```

If `calico-node`, `kube-proxy`, or `csi-node-driver` are stuck on the worker, describe them:

```bash
kubectl describe pod -n calico-system <calico-node-pod>
kubectl describe pod -n kube-system <kube-proxy-pod>
```

If you see:

```text
open /run/systemd/resolve/resolv.conf: no such file or directory
```

then the Rocky resolver fix is needed. The fixed script already includes this solution.

---

### Calico custom resources error

If you see:

```text
no matches for kind "Installation"
ensure CRDs are installed first
```

then Calico custom resources were applied before CRDs were ready.

The fixed script waits for CRDs before applying Calico custom resources.

---

### kubeadm join command expired

Generate a new join command from the master:

```bash
sudo kubeadm token create --print-join-command
```

Then run the new command on the worker using the script.

---

## Useful Kubernetes Commands

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get svc -A
kubectl get deployments -A
kubectl get daemonsets -A
kubectl describe node k8s-worker1
kubectl describe node k8s-worker2
```

---

## Lab Security Notice

This script disables the firewall and sets SELinux to permissive on Rocky workers.

This is acceptable for a local lab environment.

For production environments, do not disable security controls blindly. Instead, open only the required Kubernetes ports and configure SELinux properly.

---

## Author

Created as a kubeadm automation lab for building a Kubernetes cluster with:

```text
Ubuntu master
Rocky Linux workers
CRI-O runtime
Calico CNI
```
