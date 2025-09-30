# Kubernetes Manual Control Plane Setup - Acceptance Criteria Checklist

## Environment Information
- **Setup Type:** Manual single-node control plane (no kubeadm/kind/minikube)
- **Environment:** GitHub Codespaces (containerized, no systemd)
- **Kubernetes Version:** v1.30.0
- **Container Runtime:** containerd v2.0.5
- **CNI:** bridge + host-local (v1.6.2)
- **Max Pods per Node:** 4 (resource-constrained setting)

## ✅ Acceptance Criteria Verification

### 1. Node Status Check
**Criterion:** `kubectl get nodes` shows exactly 1 Ready node

**Verification Commands:**
```bash
# Set environment variables
export KUBEBUILDER_DIR="./kubebuilder"
export KUBECONFIG="$HOME/.kube/config"

# Check node status
$KUBEBUILDER_DIR/bin/kubectl get nodes

# Expected output:
# NAME      STATUS   ROLES           AGE   VERSION
# <hostname> Ready    master          <time> v1.30.0
```

**Status:** ⏳ PENDING

**Troubleshooting:** See [troubleshooting.md](docs/troubleshooting.md) - "Kubelet NotReady" section

---

### 2. Component Status Check
**Criterion:** `kubectl get componentstatuses` shows healthy core components

**Verification Commands:**
```bash
# Check component status
$KUBEBUILDER_DIR/bin/kubectl get componentstatuses

# Expected output (all Healthy):
# COMPONENT             STATUS   MESSAGE              ERROR
# controller-manager    Healthy  ok
# scheduler            Healthy  ok
# etcd-0               Healthy  {"health":"true"}
```

**Alternative Modern Check:**
```bash
# Modern equivalent (if componentstatuses deprecated)
$KUBEBUILDER_DIR/bin/kubectl get --raw='/readyz?verbose'

# Should return ok for: etcd, log, poststarthook
```

**Status:** ⏳ PENDING

**Troubleshooting:** See [troubleshooting.md](docs/troubleshooting.md) - "API Server Unreachable" section

---

### 3. API Server Health Check
**Criterion:** `kubectl get --raw '/readyz?verbose'` returns ok checks

**Verification Commands:**
```bash
# Check API server readiness
$KUBEBUILDER_DIR/bin/kubectl get --raw='/readyz?verbose'

# Expected output includes:
# [+] etcd ready
# [+] log ready
# [+] poststarthook/start-kube-apiserver-admission-initializer ready
```

**Status:** ⏳ PENDING

**Troubleshooting:** See [troubleshooting.md](docs/troubleshooting.md) - "API Server Unreachable" section

---

### 4. Demo Deployment Status
**Criterion:** `kubectl apply -f k8s/demo-deploy.yaml` reaches Available within reasonable time

**Verification Commands:**
```bash
# Apply demo deployment
$KUBEBUILDER_DIR/bin/kubectl apply -f k8s/demo-deploy.yaml

# Check deployment status
$KUBEBUILDER_DIR/bin/kubectl get deployment demo-nginx

# Expected output:
# NAME        READY   UP-TO-DATE   AVAILABLE   AGE
# demo-nginx  2/2     2            2           <time>

# Check pods status
$KUBEBUILDER_DIR/bin/kubectl get pods -l app=demo-nginx

# Expected output (both Running):
# NAME                         READY   STATUS    RESTARTS   AGE
# demo-nginx-<pod1>           1/1     Running   0          <time>
# demo-nginx-<pod2>           1/1     Running   0          <time>

# Check service and ingress
$KUBEBUILDER_DIR/bin/kubectl get service,ingress

# Test service connectivity (if curl available)
$KUBEBUILDER_DIR/bin/kubectl exec deployment/demo-nginx -- curl -s http://demo-nginx-service
```

**Status:** ⏳ PENDING

**Troubleshooting:** See [troubleshooting.md](docs/troubleshooting.md) - "Pods Stuck in Pending State" section

---

### 5. Codespaces Compatibility Check
**Criterion:** All commands work in fresh Codespace without systemd or snap

**Verification Commands:**
```bash
# Check no systemd dependency
ps aux | grep systemd || echo "No systemd processes found ✓"

# Verify all binaries are statically linked or work without systemd
ls -la $KUBEBUILDER_DIR/bin/
ls -la /opt/cni/bin/

# Check resource constraints are appropriate
echo "Max pods setting: $($KUBEBUILDER_DIR/bin/kubectl get node $(hostname) -o jsonpath='{.status.capacity.pods}')"
```

**Status:** ⏳ PENDING

---

## 📋 Complete Verification Script

Run this script to verify all criteria at once:

```bash
#!/bin/bash
# complete-verification.sh

export KUBEBUILDER_DIR="./kubebuilder"
export KUBECONFIG="$HOME/.kube/config"

echo "=== Kubernetes Manual Setup Verification ==="
echo

# 1. Node Status
echo "1. Checking node status..."
NODE_OUTPUT=$($KUBEBUILDER_DIR/bin/kubectl get nodes 2>/dev/null)
if echo "$NODE_OUTPUT" | grep -q "Ready.*master"; then
    echo "✅ PASS: Node is Ready"
else
    echo "❌ FAIL: Node not Ready"
    echo "Output: $NODE_OUTPUT"
fi
echo

# 2. Component Status
echo "2. Checking component status..."
CS_OUTPUT=$($KUBEBUILDER_DIR/bin/kubectl get componentstatuses 2>/dev/null)
if echo "$CS_OUTPUT" | grep -q "Healthy"; then
    echo "✅ PASS: Components are Healthy"
else
    echo "❌ FAIL: Some components unhealthy"
    echo "Output: $CS_OUTPUT"
fi
echo

# 3. API Server Health
echo "3. Checking API server health..."
HEALTH_OUTPUT=$($KUBEBUILDER_DIR/bin/kubectl get --raw='/readyz?verbose' 2>/dev/null)
if echo "$HEALTH_OUTPUT" | grep -q "ok"; then
    echo "✅ PASS: API server is healthy"
else
    echo "❌ FAIL: API server not healthy"
    echo "Output: $HEALTH_OUTPUT"
fi
echo

# 4. Demo Deployment
echo "4. Testing demo deployment..."
$KUBEBUILDER_DIR/bin/kubectl apply -f k8s/demo-deploy.yaml >/dev/null 2>&1
sleep 10
DEPLOY_OUTPUT=$($KUBEBUILDER_DIR/bin/kubectl get deployment demo-nginx -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
if [ "$DEPLOY_OUTPUT" = "2" ]; then
    echo "✅ PASS: Demo deployment is Available"
else
    echo "❌ FAIL: Demo deployment not Available"
    echo "Available replicas: $DEPLOY_OUTPUT"
fi
echo

# 5. Process Check
echo "5. Checking running processes..."
PROCESS_COUNT=$(ps aux | grep -E "(etcd|kube-apiserver|containerd|kubelet|kube-scheduler|kube-controller-manager)" | grep -v grep | wc -l)
if [ "$PROCESS_COUNT" -ge 6 ]; then
    echo "✅ PASS: All components running ($PROCESS_COUNT processes)"
else
    echo "❌ FAIL: Missing components ($PROCESS_COUNT/6 running)"
fi
echo

echo "=== Verification Complete ==="
```

## 🚨 Known Limitations & Caveats

### Codespaces-Specific Constraints
- **Resource Limits:** max-pods=4 due to container resource constraints
- **No systemd:** All processes run as background processes with manual PID management
- **Self-signed certificates:** Development-only security (acceptable per requirements)
- **Token auth:** Hardcoded token for simplicity (development-only)

### Performance Characteristics
- **Cold Start Time:** ~30-60 seconds for initial setup
- **Memory Usage:** ~200-300MB for all components combined
- **Network:** Pod network uses 10.22.0.0/16 subnet

### Not Included (Out of Scope)
- **Ingress Controller:** Demo includes ingress resource but no controller implementation
- **CoreDNS:** No DNS service configuration (uses host DNS)
- **Metrics Server:** No metrics collection setup
- **High Availability:** Single-node setup only

## 🔧 Quick Fix Commands

If verification fails, try these in order:

```bash
# 1. Check if all processes are running
./scripts/stop-all.sh
./scripts/start-all.sh

# 2. Check logs for errors
echo "=== Recent etcd logs ==="
PID=$(cat /tmp/etcd.pid 2>/dev/null)
ps -p $PID >/dev/null && echo "etcd running" || echo "etcd not running"

echo "=== Recent API server logs ==="
PID=$(cat /tmp/apiserver.pid 2>/dev/null)
ps -p $PID >/dev/null && echo "apiserver running" || echo "apiserver not running"

# 3. Verify network setup
ip addr show cni0 || echo "CNI bridge not created"
ip route | grep 10.22 || echo "Pod subnet route missing"

# 4. Check containerd
ls -la /run/containerd/containerd.sock || echo "containerd socket missing"
```

## 📊 Status Summary

| Criterion | Status | Last Checked | Notes |
|-----------|--------|--------------|-------|
| Node Ready | ⏳ PENDING | - | Must show 1 Ready node |
| Component Health | ⏳ PENDING | - | All components Healthy |
| API Server | ⏳ PENDING | - | /readyz returns ok |
| Demo Deployment | ⏳ PENDING | - | nginx deployment Available |
| Codespaces Compatible | ⏳ PENDING | - | No systemd dependencies |

**Overall Status:** ⏳ IN PROGRESS

**Next Steps:**
1. Run `./scripts/start-all.sh` to start the cluster
2. Execute verification script above
3. Update status in this checklist
4. If issues arise, consult [troubleshooting.md](docs/troubleshooting.md)

---

*Last Updated:* $(date -u +"%Y-%m-%dT%H:%M:%SZ")
*Setup Version:* v1.30.0-manual-codespaces