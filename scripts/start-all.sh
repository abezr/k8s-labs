#!/bin/bash

# Kubernetes Manual Control Plane Startup Script
# Starts all components in the correct order with PID tracking

set -e  # Exit on any error

# Configuration
KUBEBUILDER_DIR="./kubebuilder"
CNI_BIN="./opt/cni/bin"
HOST_IP=$(hostname -I | awk '{print $1}')
TOKEN="1234567890"

echo "=== Kubernetes Manual Control Plane Setup ==="
echo "HOST_IP: $HOST_IP"
echo "Starting components in order..."

# Function to cleanup on failure
cleanup_on_failure() {
    echo "ERROR: Setup failed, cleaning up..."
    ./scripts/stop-all.sh
    exit 1
}

# Set trap for cleanup on script failure
trap cleanup_on_failure ERR

# 1. Create required directories
echo "Creating directories..."
mkdir -p $KUBEBUILDER_DIR/bin

# Try to create system directories, use local if permission denied
mkdir -p /etc/cni/net.d || mkdir -p ./etc/cni/net.d
mkdir -p /var/lib/kubelet || mkdir -p ./var/lib/kubelet
mkdir -p /var/lib/kubelet/pki || mkdir -p ./var/lib/kubelet/pki
mkdir -p /etc/kubernetes/manifests || mkdir -p ./etc/kubernetes/manifests
mkdir -p /var/log/kubernetes || mkdir -p ./var/log/kubernetes
mkdir -p /etc/containerd || mkdir -p ./etc/containerd
mkdir -p /run/containerd || mkdir -p ./run/containerd
mkdir -p /opt/cni/bin || mkdir -p ./opt/cni/bin

# Set fallback paths if system directories aren't available
CNI_CONF_DIR="/etc/cni/net.d"
KUBELET_DIR="/var/lib/kubelet"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
[ ! -w "/etc/cni/net.d" ] && CNI_CONF_DIR="./etc/cni/net.d"
[ ! -w "/var/lib/kubelet" ] && KUBELET_DIR="./var/lib/kubelet"
[ ! -w "/etc/containerd" ] && CONTAINERD_CONFIG="./etc/containerd/config.toml"

# 2. Download components if they don't exist
echo "Checking and downloading components..."

# kubebuilder tools (includes etcd, kubectl)
if [ ! -f "$KUBEBUILDER_DIR/bin/etcd" ]; then
    echo "Downloading kubebuilder tools..."
    curl -L https://storage.googleapis.com/kubebuilder-tools/kubebuilder-tools-1.30.0-linux-amd64.tar.gz -o /tmp/kubebuilder-tools.tar.gz
    tar -C $KUBEBUILDER_DIR --strip-components=1 -zxf /tmp/kubebuilder-tools.tar.gz
    rm /tmp/kubebuilder-tools.tar.gz
    chmod -R 755 $KUBEBUILDER_DIR/bin
fi

# kubelet
if [ ! -f "$KUBEBUILDER_DIR/bin/kubelet" ]; then
    echo "Downloading kubelet..."
    curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kubelet" -o $KUBEBUILDER_DIR/bin/kubelet
    chmod 755 $KUBEBUILDER_DIR/bin/kubelet
fi

# controller manager and scheduler
if [ ! -f "$KUBEBUILDER_DIR/bin/kube-controller-manager" ]; then
    echo "Downloading controller manager and scheduler..."
    curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-controller-manager" -o $KUBEBUILDER_DIR/bin/kube-controller-manager
    curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-scheduler" -o $KUBEBUILDER_DIR/bin/kube-scheduler
    curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/cloud-controller-manager" -o $KUBEBUILDER_DIR/bin/cloud-controller-manager

    chmod 755 $KUBEBUILDER_DIR/bin/kube-controller-manager
    chmod 755 $KUBEBUILDER_DIR/bin/kube-scheduler
    chmod 755 $KUBEBUILDER_DIR/bin/cloud-controller-manager
fi

# containerd
if [ ! -f "$CNI_BIN/containerd" ]; then
    echo "Downloading containerd..."
    wget https://github.com/containerd/containerd/releases/download/v2.0.5/containerd-static-2.0.5-linux-amd64.tar.gz -O /tmp/containerd.tar.gz
    tar zxf /tmp/containerd.tar.gz -C $CNI_BIN/
    rm /tmp/containerd.tar.gz
fi

# runc
if [ ! -f "$CNI_BIN/runc" ]; then
    echo "Downloading runc..."
    curl -L "https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.amd64" -o $CNI_BIN/runc
    chmod +x $CNI_BIN/runc
fi

# CNI plugins
if [ ! -f "$CNI_BIN/bridge" ]; then
    echo "Downloading CNI plugins..."
    wget https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz -O /tmp/cni-plugins.tgz
    tar zxf /tmp/cni-plugins.tgz -C $CNI_BIN/
    rm /tmp/cni-plugins.tgz
fi

# 3. Generate certificates and tokens
echo "Generating certificates and tokens..."
openssl genrsa -out /tmp/sa.key 2048
openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub

echo "${TOKEN},admin,admin,system:masters" > /tmp/token.csv

openssl genrsa -out /tmp/ca.key 2048
openssl req -x509 -new -nodes -key /tmp/ca.key -subj "/CN=kubelet-ca" -days 365 -out /tmp/ca.crt
cp /tmp/ca.crt "$KUBELET_DIR/ca.crt"
cp /tmp/ca.crt "$KUBELET_DIR/pki/ca.crt"

# 4. Configure kubectl
echo "Configuring kubectl..."
mkdir -p ~/.kube
$KUBEBUILDER_DIR/bin/kubectl config set-credentials test-user --token=1234567890
$KUBEBUILDER_DIR/bin/kubectl config set-cluster test-env --server=https://127.0.0.1:6443 --insecure-skip-tls-verify
$KUBEBUILDER_DIR/bin/kubectl config set-context test-context --cluster=test-env --user=test-user --namespace=default
$KUBEBUILDER_DIR/bin/kubectl config use-context test-context

# 5. Create configuration files
echo "Creating configuration files..."

# CNI config
cat > "$CNI_CONF_DIR/10-mynet.conf" <<EOF
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
EOF

# containerd config
cat > "$CONTAINERD_CONFIG" <<EOF
version = 3

[grpc]
  address = "./run/containerd/containerd.sock"

[state]
  run = "./run/containerd"

[plugins.'io.containerd.grpc.v1.cri']
  sandbox_image = "registry.k8s.io/pause:3.10"

[plugins.'io.containerd.cri.v1.runtime']
  enable_selinux = false
  enable_unprivileged_ports = true
  enable_unprivileged_icmp = true
  device_ownership_from_security_context = false

[plugins.'io.containerd.cri.v1.images']
  snapshotter = "native"
  disable_snapshot_annotations = true

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dir = "./opt/cni/bin"
  conf_dir = "./etc/cni/net.d"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false

[plugins.'io.containerd.grpc.v1.cri'.containerd]
  default_runtime_name = "runc"
  runtimes = { "runc" = { runtime_type = "io.containerd.runc.v2" } }
EOF

# kubelet config
cat > "$KUBELET_DIR/config.yaml" <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: true
  x509:
    clientCAFile: "ca.crt"
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
containerRuntimeEndpoint: "unix://./run/containerd/containerd.sock"
staticPodPath: "./etc/kubernetes/manifests"
EOF

# 6. Start components in order
echo "Starting etcd..."
export PATH=$PATH:$CNI_BIN:$KUBEBUILDER_DIR/bin

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

echo "Waiting for etcd to start..."
sleep 3

echo "Starting kube-apiserver..."
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

echo "Waiting for API server to start..."
sleep 5

echo "Starting containerd..."
# Create writable containerd directories
mkdir -p ./var/lib/containerd
mkdir -p ./run/containerd
# Set containerd runtime state directory
export CONTAINERD_ROOT="./var/lib/containerd"
export CONTAINERD_STATE_DIR="./run/containerd"
PATH=$PATH:/opt/cni/bin:/usr/sbin /opt/cni/bin/containerd --config "$CONTAINERD_CONFIG" --root "$CONTAINERD_ROOT" &
echo $! > /tmp/containerd.pid

echo "Waiting for containerd to start..."
sleep 3

echo "Starting kube-scheduler..."
$KUBEBUILDER_DIR/bin/kube-scheduler \
    --kubeconfig=$HOME/.kube/config \
    --leader-elect=false \
    --v=2 \
    --bind-address=0.0.0.0 &
echo $! > /tmp/scheduler.pid

echo "Preparing kubelet prerequisites..."
# Copy kubeconfig
cp $HOME/.kube/config $KUBELET_DIR/kubeconfig
export KUBECONFIG=~/.kube/config
cp /tmp/sa.pub /tmp/ca.crt

# Create service account and configmap (ignore if already exists)
$KUBEBUILDER_DIR/bin/kubectl create sa default --dry-run=client -o yaml | $KUBEBUILDER_DIR/bin/kubectl apply -f - || echo "Service account may already exist"
$KUBEBUILDER_DIR/bin/kubectl create configmap kube-root-ca.crt --from-file=ca.crt=/tmp/ca.crt -n default --dry-run=client -o yaml | $KUBEBUILDER_DIR/bin/kubectl apply -f - || echo "ConfigMap may already exist"

echo "Starting kubelet..."
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

echo "Waiting for kubelet to register..."
sleep 5

echo "Labeling node..."
NODE_NAME=$(hostname)
# Wait for node to be registered
TIMEOUT=30
COUNT=0
while ! $KUBEBUILDER_DIR/bin/kubectl get nodes "$NODE_NAME" &>/dev/null; do
  if [ $COUNT -ge $TIMEOUT ]; then
    echo "Timeout waiting for node $NODE_NAME to register"
    break
  fi
  sleep 2
  COUNT=$((COUNT + 2))
done
$KUBEBUILDER_DIR/bin/kubectl label node "$NODE_NAME" node-role.kubernetes.io/master="" --overwrite 2>/dev/null || echo "Node labeling failed, continuing..."

echo "Starting kube-controller-manager..."
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

echo "=== Setup Complete ==="
echo "All components started successfully!"
echo ""
echo "Verification commands:"
echo "kubectl get nodes"
echo "kubectl get componentstatuses"
echo "kubectl get --raw='/readyz?verbose'"
echo "kubectl create deploy demo --image nginx"
echo ""
echo "Check status with: ./scripts/status.sh"
echo "Stop all with: ./scripts/stop-all.sh"