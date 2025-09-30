#!/bin/bash

# Kubernetes Manual Control Plane Stop Script
# Gracefully stops all components and cleans up resources

echo "=== Stopping Kubernetes Control Plane ==="

# Function to kill process by PID file
kill_pidfile() {
    local pidfile=$1
    local component=$(basename $pidfile .pid)

    if [ -f "$pidfile" ]; then
        local pid=$(cat "$pidfile" 2>/dev/null)
        if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
            echo "Stopping $component (PID: $pid)..."
            kill -TERM $pid 2>/dev/null || true

            # Wait up to 10 seconds for graceful shutdown
            local count=0
            while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt 10 ]; do
                sleep 1
                count=$((count + 1))
            done

            # Force kill if still running
            if ps -p "$pid" > /dev/null 2>&1; then
                echo "Force killing $component..."
                kill -KILL $pid 2>/dev/null || true
            fi

            rm -f "$pidfile"
            echo "$component stopped"
        else
            echo "$component not running or PID file invalid"
            rm -f "$pidfile"
        fi
    else
        echo "No PID file for $component"
    fi
}

# Function to kill process by name
kill_by_name() {
    local name=$1
    local pids=$(ps aux | grep "$name" | grep -v grep | awk '{print $2}' | tr '\n' ' ')

    if [ -n "$pids" ]; then
        echo "Stopping $name processes: $pids"
        kill -TERM $pids 2>/dev/null || true

        # Wait a bit for graceful shutdown
        sleep 2

        # Check if still running and force kill if needed
        local remaining_pids=$(ps aux | grep "$name" | grep -v grep | awk '{print $2}')
        if [ -n "$remaining_pids" ]; then
            kill -KILL $remaining_pids 2>/dev/null || true
        fi
        echo "$name processes stopped"
    else
        echo "No $name processes found"
    fi
}

# Stop components in reverse order

echo "1. Stopping kube-controller-manager..."
kill_pidfile "/tmp/controller-manager.pid"

echo "2. Stopping kubelet..."
kill_pidfile "/tmp/kubelet.pid"

echo "3. Stopping kube-scheduler..."
kill_pidfile "/tmp/scheduler.pid"

echo "4. Stopping containerd..."
kill_pidfile "/tmp/containerd.pid"

echo "5. Stopping kube-apiserver..."
kill_pidfile "/tmp/apiserver.pid"

echo "6. Stopping etcd..."
kill_pidfile "/tmp/etcd.pid"

# Additional cleanup - kill any remaining processes by name
echo "7. Additional cleanup..."

kill_by_name "kube-controller-manager"
kill_by_name "kubelet"
kill_by_name "kube-scheduler"
kill_by_name "containerd"
kill_by_name "kube-apiserver"
kill_by_name "etcd"

# Clean up temporary files
echo "8. Cleaning up temporary files..."
rm -f /tmp/etcd.pid
rm -f /tmp/apiserver.pid
rm -f /tmp/containerd.pid
rm -f /tmp/scheduler.pid
rm -f /tmp/kubelet.pid
rm -f /tmp/controller-manager.pid

# Clean up generated certificates and tokens (optional, for security)
# Uncomment the following lines if you want to clean up certificates
# rm -f /tmp/sa.key /tmp/sa.pub /tmp/token.csv /tmp/ca.key /tmp/ca.crt
# rm -f /var/lib/kubelet/ca.crt /var/lib/kubelet/pki/ca.crt

# Clean up downloaded files (optional, for space)
# Uncomment the following lines if you want to clean up binaries
# rm -f /tmp/kubebuilder-tools.tar.gz /tmp/containerd.tar.gz /tmp/cni-plugins.tgz

# Clean up CNI interfaces (optional, for clean restart)
# Uncomment the following lines if you want to remove network interfaces
# ip link del cni0 2>/dev/null || true
# ip link del flannel.1 2>/dev/null || true

# Clean up iptables rules (optional, for clean restart)
# Uncomment the following lines if you want to flush iptables
# iptables -t nat -F 2>/dev/null || true
# iptables -t filter -F 2>/dev/null || true

echo "=== Kubernetes Control Plane Stopped ==="
echo ""
echo "Cleanup completed!"
echo ""
echo "To start again, run: ./scripts/start-all.sh"
echo "To check if any processes are still running: ps aux | grep kube"

# Final check for any remaining processes
echo ""
echo "=== Final Process Check ==="
remaining=$(ps aux | grep -E "(etcd|kube-apiserver|containerd|kubelet|kube-scheduler|kube-controller-manager)" | grep -v grep)
if [ -n "$remaining" ]; then
    echo "WARNING: Some processes may still be running:"
    echo "$remaining"
else
    echo "All processes stopped successfully"
fi