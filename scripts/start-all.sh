#!/bin/bash

# Kubernetes Manual Control Plane Startup Script
# Starts all components in the correct order with PID tracking (Codespaces-friendly, no systemd)

set -e  # Exit on any error

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
KUBEBUILDER_DIR="./kubebuilder"
CNI_BIN="./opt/cni/bin"
HOST_IP=$(hostname -I | awk '{print $1}')
TOKEN="1234567890"

echo "=== Kubernetes Manual Control Plane Setup ==="
echo "HOST_IP: $HOST_IP"
echo "Starting components in order..."

# -----------------------------------------------------------------------------
# Cleanup on failure
# -----------------------------------------------------------------------------
cleanup_on_failure() {
    echo "ERROR: Setup failed, cleaning up..."
    ./scripts/stop-all.sh || true
    exit 1
}
trap cleanup_on_failure ERR

# -----------------------------------------------------------------------------
# 1. Create required directories (prefer system dirs, fall back to local)
# -----------------------------------------------------------------------------
echo "Creating directories..."
mkdir -p "$KUBEBUILDER_DIR/bin"

# Try to create system directories; fall back to local if permission denied
mkdir -p /etc/cni/net.d || mkdir -p ./etc/cni/net.d
mkdir -p /var/lib/kubelet || mkdir -p ./var/lib/kubelet
mkdir -p /var/lib/kubelet/pki || mkdir -p ./var/lib/kubelet/pki
mkdir -p /etc/kubernetes/manifests || mkdir -p ./etc/kubernetes/manifests
mkdir -p /var/log/kubernetes || mkdir -p ./var/log/kubernetes
mkdir -p /etc/containerd || mkdir -p ./etc/containerd
mkdir -p ./run/containerd

# Fallback paths if system paths not writable
CNI_CONF_DIR="/etc/cni/net.d"
KUBELET_DIR="/var/lib/kubelet"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
[ ! -w "/etc/cni/net.d" ] && CNI_CONF_DIR="./etc/cni/net.d"
[ ! -w "/var/lib/kubelet" ] && KUBELET_DIR="./var/lib/kubelet"
[ ! -w "/etc/containerd" ] && CONTAINERD_CONFIG="./etc/containerd/config.toml"

# Compute absolute paths to avoid relative path duplication in generated files
WORKDIR="$(pwd)"
CNI_BIN_ABS="$(cd "$CNI_BIN" && pwd)"
CNI_CONF_DIR_ABS="$(cd "$CNI_CONF_DIR" && pwd)"
KUBELET_DIR_ABS="$(cd "$KUBELET_DIR" && pwd)"

if [ -d "/etc/kubernetes/manifests" ] && [ -w "/etc/kubernetes/manifests" ]; then
  KUBE_MANIFESTS_DIR="/etc/kubernetes/manifests"
else
  KUBE_MANIFESTS_DIR="./etc/kubernetes/manifests"
fi
KUBE_MANIFESTS_DIR_ABS="$(cd "$KUBE_MANIFESTS_DIR" && pwd)"

# Containerd runtime/root directories and socket (use /run for socket with sudo)
CONTAINERD_ROOT="./var/lib/containerd"
CONTAINERD_STATE="/run/containerd"
CONTAINERD_SOCK_ABS="/run/containerd/containerd.sock"

# Log directory
LOG_DIR="/var/log/kubernetes"
[ ! -w "/var/log/kubernetes" ] && LOG_DIR="./var/log/kubernetes"

# Ensure dirs exist
mkdir -p "$CONTAINERD_ROOT" "$LOG_DIR"
# Ensure containerd state dir under /run exists (may require sudo)
if ! mkdir -p "$CONTAINERD_STATE" 2>/dev/null; then
  if command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$CONTAINERD_STATE"
  else
    echo "ERROR: cannot create $CONTAINERD_STATE and sudo is unavailable"
    exit 1
  fi
fi
# Relax permissions to avoid chown errors from containerd on ttrpc sockets
if command -v sudo >/dev/null 2>&1; then
  sudo chmod 0777 "$CONTAINERD_STATE" || true
fi
chmod 0777 "$CONTAINERD_STATE" || true
# Provide a local symlink to the system state dir so any legacy paths under ./run/containerd resolve
ln -sfn /run/containerd ./run/containerd 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Download components if not present
# -----------------------------------------------------------------------------
echo "Checking and downloading components..."

# kubebuilder tools (includes etcd, kubectl)
if [ ! -f "$KUBEBUILDER_DIR/bin/etcd" ]; then
  echo "Downloading kubebuilder tools..."
  curl -L https://storage.googleapis.com/kubebuilder-tools/kubebuilder-tools-1.30.0-linux-amd64.tar.gz -o /tmp/kubebuilder-tools.tar.gz
  tar -C "$KUBEBUILDER_DIR" --strip-components=1 -zxf /tmp/kubebuilder-tools.tar.gz
  rm -f /tmp/kubebuilder-tools.tar.gz
  chmod -R 755 "$KUBEBUILDER_DIR/bin"
fi

# kubelet
if [ ! -f "$KUBEBUILDER_DIR/bin/kubelet" ]; then
  echo "Downloading kubelet..."
  curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kubelet" -o "$KUBEBUILDER_DIR/bin/kubelet"
  chmod 755 "$KUBEBUILDER_DIR/bin/kubelet"
fi

# controller-manager, scheduler, cloud-controller-manager
if [ ! -f "$KUBEBUILDER_DIR/bin/kube-controller-manager" ]; then
  echo "Downloading controller manager and scheduler..."
  curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-controller-manager" -o "$KUBEBUILDER_DIR/bin/kube-controller-manager"
  curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/kube-scheduler" -o "$KUBEBUILDER_DIR/bin/kube-scheduler"
  curl -L "https://dl.k8s.io/v1.30.0/bin/linux/amd64/cloud-controller-manager" -o "$KUBEBUILDER_DIR/bin/cloud-controller-manager"
  chmod 755 "$KUBEBUILDER_DIR/bin/kube-controller-manager" "$KUBEBUILDER_DIR/bin/kube-scheduler" "$KUBEBUILDER_DIR/bin/cloud-controller-manager"
fi

# containerd (static) - prefer local static containerd to avoid system version schema conflicts
if [ ! -f "$CNI_BIN/containerd" ]; then
  echo "Downloading containerd static binary..."
  wget https://github.com/containerd/containerd/releases/download/v2.0.5/containerd-static-2.0.5-linux-amd64.tar.gz -O /tmp/containerd.tar.gz
  mkdir -p ./opt/cni
  tar zxf /tmp/containerd.tar.gz -C ./opt/cni/
  rm -f /tmp/containerd.tar.gz
fi

# runc
if [ ! -f "$CNI_BIN/runc" ]; then
  echo "Downloading runc..."
  curl -L "https://github.com/opencontainers/runc/releases/download/v1.2.6/runc.amd64" -o "$CNI_BIN/runc"
  chmod +x "$CNI_BIN/runc"
fi

# CNI plugins
if [ ! -f "$CNI_BIN/bridge" ]; then
  echo "Downloading CNI plugins..."
  wget https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz -O /tmp/cni-plugins.tgz
  tar zxf /tmp/cni-plugins.tgz -C "$CNI_BIN/"
  rm -f /tmp/cni-plugins.tgz
fi

# -----------------------------------------------------------------------------
# 3. Generate certificates and tokens
# -----------------------------------------------------------------------------
echo "Generating certificates and tokens..."
openssl genrsa -out /tmp/sa.key 2048
openssl rsa -in /tmp/sa.key -pubout -out /tmp/sa.pub

echo "${TOKEN},admin,admin,system:masters" > /tmp/token.csv

openssl genrsa -out /tmp/ca.key 2048
openssl req -x509 -new -nodes -key /tmp/ca.key -subj "/CN=kubelet-ca" -days 365 -out /tmp/ca.crt
cp /tmp/ca.crt "$KUBELET_DIR/ca.crt"
cp /tmp/ca.crt "$KUBELET_DIR/pki/ca.crt"

# -----------------------------------------------------------------------------
# 4. Configure kubectl
# -----------------------------------------------------------------------------
echo "Configuring kubectl..."
mkdir -p ~/.kube
"$KUBEBUILDER_DIR/bin/kubectl" config set-credentials test-user --token=1234567890
"$KUBEBUILDER_DIR/bin/kubectl" config set-cluster test-env --server=https://127.0.0.1:6443 --insecure-skip-tls-verify
"$KUBEBUILDER_DIR/bin/kubectl" config set-context test-context --cluster=test-env --user=test-user --namespace=default
"$KUBEBUILDER_DIR/bin/kubectl" config use-context test-context

# KUBECONFIG for subsequent kubectl calls
export KUBECONFIG="$HOME/.kube/config"

# -----------------------------------------------------------------------------
# 5. Create configuration files
# -----------------------------------------------------------------------------
echo "Creating configuration files..."

# CNI config (bridge + host-local)
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

# containerd config (v2.0 schema - version = 3)
cat > "$CONTAINERD_CONFIG" <<EOF
version = 3
root = "${WORKDIR}/var/lib/containerd"
state = "/run/containerd"

[grpc]
  address = "${CONTAINERD_SOCK_ABS}"

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
  bin_dir = "${CNI_BIN_ABS}"
  conf_dir = "${CNI_CONF_DIR_ABS}"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false

[plugins.'io.containerd.grpc.v1.cri'.containerd]
  default_runtime_name = "runc"
  runtimes = { "runc" = { runtime_type = "io.containerd.runc.v2" } }
EOF

# kubelet config (absolute paths; endpoint references local containerd socket)
cat > "$KUBELET_DIR/config.yaml" <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: false
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
staticPodPath: "${KUBE_MANIFESTS_DIR_ABS}"
EOF

# -----------------------------------------------------------------------------
# 6. Start components in order
# -----------------------------------------------------------------------------
export PATH="$PATH:$CNI_BIN:$KUBEBUILDER_DIR/bin"

echo "Starting etcd..."
"$KUBEBUILDER_DIR/bin/etcd" \
  --advertise-client-urls "http://$HOST_IP:2379" \
  --listen-client-urls "http://0.0.0.0:2379" \
  --data-dir ./etcd \
  --listen-peer-urls "http://0.0.0.0:2380" \
  --initial-cluster "default=http://$HOST_IP:2380" \
  --initial-advertise-peer-urls "http://$HOST_IP:2380" \
  --initial-cluster-state new \
  --initial-cluster-token test-token >> "$LOG_DIR/etcd.log" 2>&1 &
echo $! > /tmp/etcd.pid

echo "Waiting for etcd to start..."
sleep 3

echo "Starting kube-apiserver..."
mkdir -p ./var/run/kubernetes
"$KUBEBUILDER_DIR/bin/kube-apiserver" \
  --etcd-servers="http://$HOST_IP:2379" \
  --service-cluster-ip-range=10.0.0.0/24 \
  --bind-address=0.0.0.0 \
  --secure-port=6443 \
  --advertise-address="$HOST_IP" \
  --authorization-mode=AlwaysAllow \
  --token-auth-file=/tmp/token.csv \
  --client-ca-file=/tmp/ca.crt \
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
  --etcd-prefix=/kubernetes >> "$LOG_DIR/kube-apiserver.log" 2>&1 &
echo $! > /tmp/apiserver.pid

echo "Waiting for API server to start..."
sleep 5

echo "Starting containerd (local static preferred)..."
if [ -S /run/containerd/containerd.sock ]; then
  echo "Using system containerd at /run/containerd/containerd.sock"
else
  # Prefer local static containerd (v2.0.5). Fallback to system containerd if local missing.
  CONTAINERD_BIN=""
  if [ -x "$CNI_BIN_ABS/containerd" ]; then
    CONTAINERD_BIN="$CNI_BIN_ABS/containerd"
  else
    CONTAINERD_BIN="$(command -v containerd || true)"
  fi
  if [ -z "$CONTAINERD_BIN" ]; then
    echo "ERROR: containerd binary not found (checked $CNI_BIN_ABS/containerd and system PATH)"
    exit 1
  fi

  # Start containerd (needs root for socket ownership/chown on ttrpc)
  if command -v sudo >/dev/null 2>&1; then
    sudo -E bash -c 'PATH="$PATH:/opt/cni/bin:/usr/sbin" "'"$CONTAINERD_BIN"'" --config "'"$CONTAINERD_CONFIG"'" --root "'"$CONTAINERD_ROOT"'" --state "'"$CONTAINERD_STATE"'" >> "'"$LOG_DIR"'/containerd.log" 2>&1 & echo $! > /tmp/containerd.pid'
  else
    echo "ERROR: containerd must run as root to manage socket ownership (ttrpc chown). Install sudo or run this script as root."
    exit 1
  fi
fi

echo "Waiting for containerd socket: $CONTAINERD_SOCK_ABS ..."
for i in {1..15}; do
  [ -S "$CONTAINERD_SOCK_ABS" ] && break
  sleep 1
done
if [ ! -S "$CONTAINERD_SOCK_ABS" ]; then
  echo "WARNING: containerd socket not found at $CONTAINERD_SOCK_ABS"
  tail -n 100 "$LOG_DIR/containerd.log" || true
fi

echo "Starting kube-scheduler..."
"$KUBEBUILDER_DIR/bin/kube-scheduler" \
  --kubeconfig="$HOME/.kube/config" \
  --leader-elect=false \
  --v=2 \
  --bind-address=0.0.0.0 >> "$LOG_DIR/kube-scheduler.log" 2>&1 &
echo $! > /tmp/scheduler.pid

# -----------------------------------------------------------------------------
# Kubelet prerequisites
# -----------------------------------------------------------------------------
echo "Preparing kubelet prerequisites..."
# kubeconfig used by kubectl; kubelet will use bootstrap-kubeconfig
cp "$HOME/.kube/config" "$KUBELET_DIR/kubeconfig"
cp "$HOME/.kube/config" /var/lib/kubelet/kubeconfig 2>/dev/null || cp "$HOME/.kube/config" "./var/lib/kubelet/kubeconfig"

export KUBECONFIG="$HOME/.kube/config"

# Build bootstrap kubeconfig for kubelet (absolute paths)
"$KUBEBUILDER_DIR/bin/kubectl" config set-cluster manual --server=https://127.0.0.1:6443 --insecure-skip-tls-verify=true --kubeconfig="$KUBELET_DIR_ABS/bootstrap-kubeconfig"
"$KUBEBUILDER_DIR/bin/kubectl" config set-credentials kubelet-bootstrap --token="$TOKEN" --kubeconfig="$KUBELET_DIR_ABS/bootstrap-kubeconfig"
"$KUBEBUILDER_DIR/bin/kubectl" config set-context bootstrap --cluster=manual --user=kubelet-bootstrap --kubeconfig="$KUBELET_DIR_ABS/bootstrap-kubeconfig"
"$KUBEBUILDER_DIR/bin/kubectl" config use-context bootstrap --kubeconfig="$KUBELET_DIR_ABS/bootstrap-kubeconfig"

# Ensure default SA and root CA configmap exist (idempotent)
"$KUBEBUILDER_DIR/bin/kubectl" create sa default --dry-run=client -o yaml | "$KUBEBUILDER_DIR/bin/kubectl" apply -f - || true
"$KUBEBUILDER_DIR/bin/kubectl" create configmap kube-root-ca.crt --from-file=ca.crt=/tmp/ca.crt -n default --dry-run=client -o yaml | "$KUBEBUILDER_DIR/bin/kubectl" apply -f - || true

# -----------------------------------------------------------------------------
# Start kubelet (needs UID 0 typically). Use sudo if available.
# -----------------------------------------------------------------------------
echo "Starting kubelet..."
# Keep admin kubeconfig for other components (controller-manager); kubelet uses bootstrap-kubeconfig
# rm -f "${KUBELET_DIR_ABS}/kubeconfig" || true

if command -v sudo >/dev/null 2>&1; then
  sudo -E bash -c "$KUBEBUILDER_DIR/bin/kubelet \
    --kubeconfig=${KUBELET_DIR_ABS}/kubeconfig \
    --config=${KUBELET_DIR_ABS}/config.yaml \
    --root-dir=${KUBELET_DIR_ABS} \
    --cert-dir=${KUBELET_DIR_ABS}/pki \
    --hostname-override=$(hostname) \
    --pod-infra-container-image=registry.k8s.io/pause:3.10 \
    --node-ip=$HOST_IP \
    --cloud-provider=external \
    --cgroup-driver=cgroupfs \
    --max-pods=4 \
    --v=2 \
    --bootstrap-kubeconfig=${KUBELET_DIR_ABS}/bootstrap-kubeconfig \
    >> ${LOG_DIR}/kubelet.log 2>&1 & echo \$! > /tmp/kubelet.pid"
else
  echo "WARNING: sudo not available; kubelet may fail (needs UID 0)."
  "$KUBEBUILDER_DIR/bin/kubelet" \
    --kubeconfig="${KUBELET_DIR_ABS}/kubeconfig" \
    --config="${KUBELET_DIR_ABS}/config.yaml" \
    --root-dir="${KUBELET_DIR_ABS}" \
    --cert-dir="${KUBELET_DIR_ABS}/pki" \
    --hostname-override="$(hostname)" \
    --pod-infra-container-image=registry.k8s.io/pause:3.10 \
    --node-ip="$HOST_IP" \
    --cloud-provider=external \
    --cgroup-driver=cgroupfs \
    --max-pods=4 \
    --v=2 \
    --bootstrap-kubeconfig="${KUBELET_DIR_ABS}/bootstrap-kubeconfig" \
    >> "${LOG_DIR}/kubelet.log" 2>&1 & echo $! > /tmp/kubelet.pid
fi

echo "Waiting for kubelet to register..."
sleep 5
# Fix relative paths in kubelet kubeconfig if present (prefix with absolute dir)
for i in {1..15}; do
  if [ -f "${KUBELET_DIR_ABS}/kubeconfig" ]; then
    sed -i -E "s#client-certificate:[[:space:]]+(\.?/)?var/lib/kubelet#client-certificate: ${KUBELET_DIR_ABS}#g" "${KUBELET_DIR_ABS}/kubeconfig" || true
    sed -i -E "s#client-key:[[:space:]]+(\.?/)?var/lib/kubelet#client-key: ${KUBELET_DIR_ABS}#g" "${KUBELET_DIR_ABS}/kubeconfig" || true
    break
  fi
  sleep 1
done

# -----------------------------------------------------------------------------
# Label node (after registration)
# -----------------------------------------------------------------------------
echo "Labeling node..."
NODE_NAME="$(hostname)"
TIMEOUT=60
COUNT=0
while ! "$KUBEBUILDER_DIR/bin/kubectl" get nodes "$NODE_NAME" >/dev/null 2>&1; do
  if [ $COUNT -ge $TIMEOUT ]; then
    echo "Timeout waiting for node $NODE_NAME to register"
    break
  fi
  sleep 2
  COUNT=$((COUNT + 2))
done
"$KUBEBUILDER_DIR/bin/kubectl" label node "$NODE_NAME" node-role.kubernetes.io/master="" --overwrite 2>/dev/null || echo "Node labeling skipped/failed (node not present yet)"

# -----------------------------------------------------------------------------
# Start kube-controller-manager (with CSR signing enabled)
# -----------------------------------------------------------------------------
echo "Starting kube-controller-manager..."
# Use admin kubeconfig (not kubelet's) to avoid accidental deletion by kubelet bootstrap flows
CM_KUBECONFIG="$HOME/.kube/config"
"$KUBEBUILDER_DIR/bin/kube-controller-manager" \
  --kubeconfig="$CM_KUBECONFIG" \
  --leader-elect=false \
  --cloud-provider=external \
  --service-cluster-ip-range=10.0.0.0/24 \
  --cluster-name=kubernetes \
  --root-ca-file="$KUBELET_DIR/ca.crt" \
  --service-account-private-key-file=/tmp/sa.key \
  --use-service-account-credentials=true \
  --cluster-signing-cert-file=/tmp/ca.crt \
  --cluster-signing-key-file=/tmp/ca.key \
  --v=2 >> "$LOG_DIR/kube-controller-manager.log" 2>&1 &
echo $! > /tmp/controller-manager.pid

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo "=== Setup Complete ==="
echo "All components started."
echo ""
echo "Verification commands:"
echo "kubectl get nodes"
echo "kubectl get componentstatuses"
echo "kubectl get --raw='/readyz?verbose'"
echo "kubectl apply -f k8s/demo-deploy.yaml"
echo ""
echo "Stop all with: ./scripts/stop-all.sh"