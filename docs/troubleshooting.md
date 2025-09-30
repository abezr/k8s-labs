# Kubernetes Manual Setup Troubleshooting Guide

## Common Failure Patterns & Fixes

### 1. Pods Stuck in Pending State

**Symptoms:**
- `kubectl get pods` shows pods with `Pending` status
- Events show "failed to create pod network" or "network not ready"

**Root Causes & Fixes:**

**CNI Plugin Not Applied:**
```bash
# Check if CNI config exists and is valid JSON
cat /etc/cni/net.d/10-mynet.conf

# Verify CNI binaries exist
ls -la /opt/cni/bin/

# Check bridge interface
ip addr show cni0 || echo "Bridge not created"

# Restart containerd to reapply CNI
pkill containerd
PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml &
```

**IP Route Issues:**
```bash
# Check if CNI subnet route exists
ip route | grep 10.22.0.0/16

# Manual route add if missing (temporary fix)
sudo ip route add 10.22.0.0/16 dev cni0

# Check iptables rules
sudo iptables -t nat -L | grep 10.22
```

**Containerd CRI Socket Issues:**
```bash
# Check if socket exists
ls -la /run/containerd/containerd.sock

# Check containerd logs for CRI errors
ps aux | grep containerd
# Find PID and check journalctl -u containerd (if systemd available)
```

### 2. API Server Unreachable

**Symptoms:**
- `kubectl get nodes` returns connection refused
- `kubectl get --raw='/readyz'` fails

**Root Causes & Fixes:**

**etcd Not Running:**
```bash
# Check etcd status
ss -ltnp | grep 2379 || echo "etcd not listening"

# Check etcd logs (find PID from /tmp/etcd.pid)
PID=$(cat /tmp/etcd.pid 2>/dev/null)
ps -p $PID > /dev/null && echo "etcd running" || echo "etcd not running"

# Restart etcd if needed
pkill etcd
kubebuilder/bin/etcd --advertise-client-urls http://$HOST_IP:2379 --listen-client-urls http://0.0.0.0:2379 --data-dir ./etcd --listen-peer-urls http://0.0.0.0:2380 --initial-cluster default=http://$HOST_IP:2380 --initial-advertise-peer-urls http://$HOST_IP:2380 --initial-cluster-state new --initial-cluster-token test-token &
```

**Wrong Service Cluster IP Range:**
```bash
# Check if service CIDR conflicts with pod CIDR
# Pod CIDR: 10.22.0.0/16, Service CIDR: 10.0.0.0/24 - should be fine

# Check API server bind address
ss -ltnp | grep 6443

# Verify token file exists and is readable
ls -la /tmp/token.csv
cat /tmp/token.csv
```

**Advertise Address Issues:**
```bash
# Check if HOST_IP is correct
echo $HOST_IP
hostname -I

# Verify API server can bind to all interfaces
# Check if port 6443 is already in use
ss -ltnp | grep 6443
```

### 3. Kubelet NotReady

**Symptoms:**
- `kubectl get nodes` shows `NotReady` status
- Node shows scheduling disabled

**Root Causes & Fixes:**

**Container Runtime Endpoint Issues:**
```bash
# Check if containerd socket exists
ls -la /run/containerd/containerd.sock

# Check containerd status
ps aux | grep containerd | grep -v grep

# Restart containerd if needed
pkill containerd
PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd -c /etc/containerd/config.toml &
```

**CA Certificate Path Issues:**
```bash
# Verify CA files exist
ls -la /var/lib/kubelet/ca.crt
ls -la /var/lib/kubelet/pki/ca.crt

# Check file permissions
stat /var/lib/kubelet/ca.crt

# Regenerate if missing
openssl req -x509 -new -nodes -key /tmp/ca.key -subj "/CN=kubelet-ca" -days 365 -out /tmp/ca.crt
cp /tmp/ca.crt /var/lib/kubelet/ca.crt
cp /tmp/ca.crt /var/lib/kubelet/pki/ca.crt
```

**Node IP Configuration:**
```bash
# Check if node IP matches HOST_IP
echo "HOST_IP: $HOST_IP"
echo "Node IP in kubelet config should match"

# Check hostname override
hostname

# Verify kubelet can connect to API server
curl -k https://127.0.0.1:6443/readyz
```

**Cgroup Driver Mismatch:**
```bash
# Check if cgroupfs is correct for containerd
# containerd uses cgroupfs by default, systemd would be for dockerd

# Verify in kubelet config
grep cgroup-driver /var/lib/kubelet/config.yaml
```

**Max Pods Setting:**
```bash
# Check if max-pods=4 is appropriate for Codespaces
# This is intentionally low for resource constraints

# Monitor resource usage
ps aux | grep -E "(etcd|kube-apiserver|containerd|kubelet|kube-scheduler|kube-controller-manager)" | grep -v grep
```

### 4. Image Pull Failures

**Symptoms:**
- Pods stuck in `ImagePullBackOff` or `ErrImagePull`
- Events show "failed to pull image"

**Root Causes & Fixes:**

**Registry Access Issues:**
```bash
# Test connectivity to k8s.gcr.io (now registry.k8s.io)
curl -I https://registry.k8s.io/v2/

# Check DNS resolution
nslookup registry.k8s.io

# Verify containerd can pull images
crictl pull registry.k8s.io/pause:3.10
```

**Pause Image Version Issues:**
```bash
# Verify pause image version is available
# Use older version if 3.10 fails
crictl pull registry.k8s.io/pause:3.9
crictl pull registry.k8s.io/pause:3.8

# Update kubelet config if needed
sed -i 's/registry.k8s.io\/pause:3.10/registry.k8s.io\/pause:3.9/' /var/lib/kubelet/config.yaml
```

### 5. DNS Resolution Issues

**Symptoms:**
- Pods cannot resolve external hostnames
- CoreDNS pods failing (if deployed)

**Root Causes & Fixes:**

**resolv.conf Configuration:**
```bash
# Check current resolv.conf
cat /etc/resolv.conf

# Verify kubelet resolvConf setting
grep resolvConf /var/lib/kubelet/config.yaml

# Check if kube-dns IP (10.0.0.10) is reachable
ping -c 1 10.0.0.10 || echo "DNS service IP not reachable"
```

**CNI DNS Issues:**
```bash
# Check if CNI bridge has DNS
ip addr show cni0

# Verify DNS configuration in pod network
# The bridge plugin should handle DNS through /etc/resolv.conf
```

### 6. Component Version Skew

**Symptoms:**
- Components failing to start
- Incompatible API versions
- Communication failures between components

**Root Causes & Fixes:**

**Version Consistency Check:**
```bash
# Verify all components are v1.30.0
kubebuilder/bin/etcd --version
kubebuilder/bin/kube-apiserver --version
kubebuilder/bin/kube-scheduler --version
kubebuilder/bin/kube-controller-manager --version
kubebuilder/bin/kubelet --version

# Check containerd version
/opt/cni/bin/containerd --version

# Verify CNI plugin versions
ls /opt/cni/bin/ | head -10
```

**Download Fresh Binaries:**
```bash
# Redownload if version mismatch suspected
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kubelet" -o kubebuilder/bin/kubelet
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-scheduler" -o kubebuilder/bin/kube-scheduler
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-controller-manager" -o kubebuilder/bin/kube-controller-manager
```

### 7. Resource Constraints in Codespaces

**Symptoms:**
- Components killed by OOM killer
- Slow startup times
- Intermittent failures

**Root Causes & Fixes:**

**Memory Pressure:**
```bash
# Monitor memory usage
free -h

# Check if components are being killed
dmesg | grep -i kill | tail -10

# Reduce max-pods if needed
sed -i 's/--max-pods=4/--max-pods=2/' /var/lib/kubelet/config.yaml
```

**Disk Space Issues:**
```bash
# Check available space
df -h

# Clean up temp files if needed
rm -f /tmp/*.tar.gz /tmp/*.tgz
```

### 8. Certificate and Token Issues

**Symptoms:**
- Authentication failures
- "Unauthorized" errors
- Components failing to join cluster

**Root Causes & Fixes:**

**Token File Issues:**
```bash
# Verify token file format
cat /tmp/token.csv
# Should be: 1234567890,admin,admin,system:masters

# Check file permissions
stat /tmp/token.csv

# Regenerate if corrupted
echo "1234567890,admin,admin,system:masters" > /tmp/token.csv
```

**Service Account Key Issues:**
```bash
# Verify SA key files exist
ls -la /tmp/sa.key /tmp/sa.pub

# Regenerate if missing
openssl genrsa -out /tmp/sa.key 2048
openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub
```

### 9. Debug Commands Cheat Sheet

**Quick Health Checks:**
```bash
# All-in-one status check
echo "=== Network ==="
ip route | grep 10.22
ip addr show cni0

echo "=== Processes ==="
for comp in etcd apiserver containerd scheduler kubelet controller-manager; do
    pidfile="/tmp/${comp}.pid"
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile")
        ps -p "$pid" > /dev/null && echo "$comp: RUNNING (PID $pid)" || echo "$comp: STOPPED"
    else
        echo "$comp: NO_PID_FILE"
    fi
done

echo "=== Ports ==="
ss -ltnp | grep -E "(2379|2380|6443|10250)"

echo "=== API Server ==="
curl -k https://127.0.0.1:6443/readyz || echo "API server not responding"
```

**Log Monitoring:**
```bash
# Monitor component logs in real-time
tail -f /var/log/kubernetes/*.log 2>/dev/null || echo "No log files found"

# Check systemd journal if available
journalctl -u containerd -f 2>/dev/null || echo "No systemd journal"
```

**Network Debugging:**
```bash
# Test pod-to-pod communication
kubectl run test-pod --image=busybox:1.28 --rm -it --restart=Never -- nslookup kubernetes.default

# Check CNI network configuration
cat /etc/cni/net.d/*.conf

# Verify bridge setup
brctl show cni0 2>/dev/null || echo "Bridge not found"