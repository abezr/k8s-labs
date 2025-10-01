# Kubernetes Manual Control Plane Setup - Runbook

## Environment Setup for Codespaces

**Environment Variables** (export these before starting):
```bash
export KUBEBUILDER_DIR="./kubebuilder"
export CNI_BIN="/opt/cni/bin"
export CNI_CONF="/etc/cni/net.d"
export HOST_IP=$(hostname -I | awk '{print $1}')
export PATH="$PATH:$CNI_BIN:$KUBEBUILDER_DIR/bin"
export KUBECONFIG="$HOME/.kube/config"
```

**Required Directories** (create before starting components):
```bash
mkdir -p $KUBEBUILDER_DIR/bin

# Try system directories first, fall back to local if permission denied
mkdir -p /etc/cni/net.d /var/lib/kubelet /var/lib/kubelet/pki /etc/kubernetes/manifests /var/log/kubernetes /etc/containerd /run/containerd /opt/cni/bin 2>/dev/null || {
    mkdir -p ./etc/cni/net.d ./var/lib/kubelet ./var/lib/kubelet/pki ./etc/kubernetes/manifests ./var/log/kubernetes ./etc/containerd ./run/containerd ./opt/cni/bin
}
```

## 1. Download Core Components

**Download kubebuilder tools (includes etcd, kubectl):**
```bash
curl -L https://storage.googleapis.com/kubebuilder-tools/kubebuilder-tools-1.30.0-linux-amd64.tar.gz -o /tmp/kubebuilder-tools.tar.gz
tar -C $KUBEBUILDER_DIR --strip-components=1 -zxf /tmp/kubebuilder-tools.tar.gz
rm /tmp/kubebuilder-tools.tar.gz
chmod -R 755 $KUBEBUILDER_DIR/bin
```

**Download kubelet:**
```bash
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kubelet" -o $KUBEBUILDER_DIR/bin/kubelet
chmod 755 $KUBEBUILDER_DIR/bin/kubelet
```

**Download controller manager and scheduler:**
```bash
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-controller-manager" -o $KUBEBUILDER_DIR/bin/kube-controller-manager
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-scheduler" -o $KUBEBUILDER_DIR/bin/kube-scheduler
curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/cloud-controller-manager" -o $KUBEBUILDER_DIR/bin/cloud-controller-manager

chmod 755 $KUBEBUILDER_DIR/bin/kube-controller-manager
chmod 755 $KUBEBUILDER_DIR/bin/kube-scheduler
chmod 755 $KUBEBUILDER_DIR/bin/cloud-controller-manager
```

## 2. Install Container Runtime

**Download and install containerd:**
```bash
wget https://github.com/containerd/containerd/releases/download/v2.0.5/containerd-static-2.0.5-linux-amd64.tar.gz -O /tmp/containerd.tar.gz
tar zxf /tmp/containerd.tar.gz -C /opt/cni/
rm /tmp/containerd.tar.gz
```

**Install runc:**
```bash
curl -L "https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.amd64" -o /opt/cni/bin/runc
chmod +x /opt/cni/bin/runc
```

**Install CNI plugins:**
```bash
wget https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz -O /tmp/cni-plugins.tgz
tar zxf /tmp/cni-plugins.tgz -C /opt/cni/bin/
rm /tmp/cni-plugins.tgz
```

## 3. Generate Certificates and Tokens

**Generate service account key pair:**
```bash
openssl genrsa -out /tmp/sa.key 2048
openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub
```

**Generate token file:**
```bash
TOKEN="1234567890"
echo "${TOKEN},admin,admin,system:masters" > /tmp/token.csv
```

**Generate CA certificate:**
```bash
openssl genrsa -out /tmp/ca.key 2048
openssl req -x509 -new -nodes -key /tmp/ca.key -subj "/CN=kubelet-ca" -days 365 -out /tmp/ca.crt
# Copy to system location or local if permission denied
cp /tmp/ca.crt /var/lib/kubelet/ca.crt 2>/dev/null || cp /tmp/ca.crt ./var/lib/kubelet/ca.crt
cp /tmp/ca.crt /var/lib/kubelet/pki/ca.crt 2>/dev/null || cp /tmp/ca.crt ./var/lib/kubelet/pki/ca.crt
cp /tmp/ca.crt /tmp/ca.crt  # Also copy to /tmp for kubelet config
```

## 4. Configure kubectl

```bash
$KUBEBUILDER_DIR/bin/kubectl config set-credentials test-user --token=1234567890
$KUBEBUILDER_DIR/bin/kubectl config set-cluster test-env --server=https://127.0.0.1:6443 --insecure-skip-tls-verify
$KUBEBUILDER_DIR/bin/kubectl config set-context test-context --cluster=test-env --user=test-user --namespace=default
$KUBEBUILDER_DIR/bin/kubectl config use-context test-context
```

## 5. Create Configuration Files

**CNI Configuration** (create in `/etc/cni/net.d/10-mynet.conf` or `./etc/cni/net.d/10-mynet.conf` if permission denied):
```json
{
    "cniVersion": "0.3.1",
    "name": "mynet",
    "type": "bridge",
    "bridge": "cni0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "subnet": "10.22.0.0/16",
        "routes": [
            { "dst": "0.0.0.0/0" }
        ]
    }
}
```

**containerd Configuration** (create in `/etc/containerd/config.toml` or `./etc/containerd/config.toml` if permission denied):
```toml
version = 3

[grpc]
  address = "/run/containerd/containerd.sock"

[state]
  run = "./run/containerd"

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "native"
  disable_snapshot_annotations = true

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false
```

**kubelet Configuration** (create in `/var/lib/kubelet/config.yaml` or `./var/lib/kubelet/config.yaml` if permission denied):
```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: true
  x509:
    clientCAFile: "/tmp/ca.crt"
authorization:
  mode: AlwaysAllow
clusterDomain: "cluster.local"
clusterDNS:
  - "10.0.0.10"
resolvConf: "/etc/resolv.conf"
runtimeRequestTimeout: "15m"
failSwapOn: false
seccompDefault: true
serverTLSBootstrap: false
containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
staticPodPath: "/etc/kubernetes/manifests"
```

## 6. Start Components (in order)

**Start etcd:**
```bash
$KUBEBUILDER_DIR/bin/etcd \
    --advertise-client-urls http://$HOST_IP:2379 \
    --listen-client-urls http://0.0.0.0:2379 \
    --data-dir ./etcd \
    --listen-peer-urls http://0.0.0.0:2380 \
    --initial-cluster default=http://$HOST_IP:2380 \
    --initial-advertise-peer-urls http://$HOST_IP:2380 \
    --initial-cluster-state new \
    --initial-cluster-token test-token &
echo $! > /tmp/etcd.pid
```

**Start kube-apiserver:**
```bash
# Create writable cert directory
mkdir -p ./var/run/kubernetes

$KUBEBUILDER_DIR/bin/kube-apiserver \
    --etcd-servers=http://$HOST_IP:2379 \
    --service-cluster-ip-range=10.0.0.0/24 \
    --bind-address=0.0.0.0 \
    --secure-port=6443 \
    --advertise-address=$HOST_IP \
    --authorization-mode=AlwaysAllow \
    --token-auth-file=/tmp/token.csv \
    --enable-priority-and-fairness=false \
    --allow-privileged=true \
    --profiling=false \
    --storage-backend=etcd3 \
    --storage-media-type=application/json \
    --v=0 \
    --cloud-provider=external \
    --service-account-issuer=https://kubernetes.default.svc.cluster.local \
    --service-account-key-file=/tmp/sa.pub \
    --service-account-signing-key-file=/tmp/sa.key \
    --cert-dir=./var/run/kubernetes \
    --etcd-prefix=/kubernetes &
echo $! > /tmp/apiserver.pid
```

**Start containerd:**
```bash
export PATH=$PATH:/opt/cni/bin:$KUBEBUILDER_DIR/bin
# Create writable containerd directories
mkdir -p ./var/lib/containerd ./run/containerd
# Use system config or local config if permission denied
CONTAINERD_CONFIG="/etc/containerd/config.toml"
[ ! -w "/etc/containerd" ] && CONTAINERD_CONFIG="./etc/containerd/config.toml"
# Set containerd runtime state directory
export CONTAINERD_ROOT="./var/lib/containerd"
export CONTAINERD_STATE_DIR="./run/containerd"
PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd --config "$CONTAINERD_CONFIG" --root "$CONTAINERD_ROOT" &
echo $! > /tmp/containerd.pid
```

**Start kube-scheduler:**
```bash
$KUBEBUILDER_DIR/bin/kube-scheduler \
    --kubeconfig=$HOME/.kube/config \
    --leader-elect=false \
    --v=2 \
    --bind-address=0.0.0.0 &
echo $! > /tmp/scheduler.pid
```

**Prepare kubelet prerequisites:**
```bash
# Copy kubeconfig
cp /root/.kube/config /var/lib/kubelet/kubeconfig 2>/dev/null || cp /root/.kube/config ./var/lib/kubelet/kubeconfig
export KUBECONFIG=~/.kube/config
cp /tmp/sa.pub /tmp/ca.crt

# Create service account and configmap (ignore if already exists)
$KUBEBUILDER_DIR/bin/kubectl create sa default --dry-run=client -o yaml | $KUBEBUILDER_DIR/bin/kubectl apply -f - || echo "Service account may already exist"
$KUBEBUILDER_DIR/bin/kubectl create configmap kube-root-ca.crt --from-file=ca.crt=/tmp/ca.crt -n default --dry-run=client -o yaml | $KUBEBUILDER_DIR/bin/kubectl apply -f - || echo "ConfigMap may already exist"
```

**Start kubelet:**
```bash
# Use system paths or local paths if permission denied
KUBELET_DIR="/var/lib/kubelet"
[ ! -w "/var/lib/kubelet" ] && KUBELET_DIR="./var/lib/kubelet"
PATH=$PATH:/opt/cni/bin:/usr/sbin $KUBEBUILDER_DIR/bin/kubelet \
    --kubeconfig=$KUBELET_DIR/kubeconfig \
    --config=$KUBELET_DIR/config.yaml \
    --root-dir=$KUBELET_DIR \
    --cert-dir=$KUBELET_DIR/pki \
    --hostname-override=$(hostname) \
    --pod-infra-container-image=registry.k8s.io/pause:3.10 \
    --node-ip=$HOST_IP \
    --cloud-provider=external \
    --cgroup-driver=cgroupfs \
    --max-pods=4  \
    --v=1 &
echo $! > /tmp/kubelet.pid
```

**Label the node:**
```bash
NODE_NAME=$(hostname)
$KUBEBUILDER_DIR/bin/kubectl label node "$NODE_NAME" node-role.kubernetes.io/master="" --overwrite
```

**Start kube-controller-manager:**
```bash
# Use system paths or local paths if permission denied
KUBELET_DIR="/var/lib/kubelet"
[ ! -w "/var/lib/kubelet" ] && KUBELET_DIR="./var/lib/kubelet"
PATH=$PATH:/opt/cni/bin:/usr/sbin $KUBEBUILDER_DIR/bin/kube-controller-manager \
    --kubeconfig=$KUBELET_DIR/kubeconfig \
    --leader-elect=false \
    --cloud-provider=external \
    --service-cluster-ip-range=10.0.0.0/24 \
    --cluster-name=kubernetes \
    --root-ca-file=$KUBELET_DIR/ca.crt \
    --service-account-private-key-file=/tmp/sa.key \
    --use-service-account-credentials=true \
    --v=2 &
echo $! > /tmp/controller-manager.pid
```

## 7. Verification Commands

**Check node status:**
```bash
$KUBEBUILDER_DIR/bin/kubectl get nodes
```

**Check component status:**
```bash
$KUBEBUILDER_DIR/bin/kubectl get componentstatuses
```

**Check API server health:**
```bash
$KUBEBUILDER_DIR/bin/kubectl get --raw='/readyz?verbose'
```

**Create and verify demo deployment:**
```bash
$KUBEBUILDER_DIR/bin/kubectl create deploy demo --image nginx
$KUBEBUILDER_DIR/bin/kubectl get all -A
```

## 8. Process Management

**Check running processes:**
```bash
echo "etcd:"; ss -ltnp | grep 2379 || echo "not running"
echo "apiserver:"; ss -ltnp | grep 6443 || echo "not running"
echo "containerd:"; ss -ltnp | grep 2376 || echo "not running"
echo "scheduler:"; ps aux | grep kube-scheduler | grep -v grep || echo "not running"
echo "kubelet:"; ps aux | grep kubelet | grep -v grep || echo "not running"
echo "controller-manager:"; ps aux | grep kube-controller-manager | grep -v grep || echo "not running"
```

**View process logs:**
```bash
# Find PIDs from /tmp/*.pid files and check logs
for pidfile in /tmp/*.pid; do
    component=$(basename $pidfile .pid)
    echo "=== $component logs ==="
    if [ -f $pidfile ]; then
        pid=$(cat $pidfile)
        if ps -p $pid > /dev/null; then
            echo "Process $pid is running"
        else
            echo "Process $pid is not running"
        fi
    fi
done
```

## 9. Cleanup (if needed)

**Stop all processes:**
```bash
# Kill processes by PID files
for pidfile in /tmp/*.pid; do
    if [ -f $pidfile ]; then
        pid=$(cat $pidfile)
        echo "Killing $(basename $pidfile .pid) (PID: $pid)"
        kill $pid 2>/dev/null || true
    fi
done

# Clean temp files
rm -f /tmp/*.pid /tmp/sa.* /tmp/ca.* /tmp/token.csv /tmp/kubebuilder-tools.tar.gz /tmp/containerd.tar.gz /tmp/cni-plugins.tgz
```

## Notes for Codespaces

- All commands run without `sudo` as Codespaces typically provides root access
- `max-pods=4` is set low for resource-constrained environments
- Self-signed certificates are used for development only
- Token "1234567890" is hardcoded for simplicity
- Components use insecure local connections
- This setup is for learning only, not production use