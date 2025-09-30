# Kubernetes Control Plane Components

## Overview

The Kubernetes control plane consists of several components that work together to manage the cluster state, schedule workloads, and maintain desired configurations. This manual setup includes the core components needed for a functional single-node cluster.

## Core Components

### 1. etcd

**Purpose:** Distributed key-value store that stores all cluster data
- Stores configuration data, state, and metadata
- Provides consistency and reliability for cluster operations
- Uses RAFT consensus algorithm for fault tolerance

**Configuration:**
- **Data Directory:** `./etcd` (relative to working directory)
- **Client Port:** 2379 (for API server communication)
- **Peer Port:** 2380 (for etcd cluster communication)
- **Initial Cluster:** Single-node setup with `default=http://$HOST_IP:2380`

**Key Parameters:**
```bash
--advertise-client-urls http://$HOST_IP:2379  # Where clients should connect
--listen-client-urls http://0.0.0.0:2379     # Listen on all interfaces
--initial-cluster-state new                   # New cluster initialization
--initial-cluster-token test-token           # Unique cluster identifier
```

**Health Check:**
```bash
# Check etcd health
curl http://$HOST_IP:2379/health
# Should return: {"health":"true","reason":""}
```

### 2. kube-apiserver

**Purpose:** Central management component that exposes the Kubernetes API
- Validates and processes API requests
- Updates etcd with cluster state changes
- Serves as the frontend for the cluster's shared state
- Handles authentication, authorization, and admission control

**Configuration:**
- **Secure Port:** 6443 (HTTPS API endpoint)
- **Service Cluster IP Range:** 10.0.0.0/24 (for service IPs)
- **Etcd Servers:** http://$HOST_IP:2379
- **Token Auth File:** /tmp/token.csv (for authentication)

**Key Parameters:**
```bash
--etcd-servers=http://$HOST_IP:2379           # Backend data store
--service-cluster-ip-range=10.0.0.0/24       # Service virtual IPs
--advertise-address=$HOST_IP                 # IP for other components
--authorization-mode=AlwaysAllow             # Development mode
--token-auth-file=/tmp/token.csv            # Simple token auth
--allow-privileged=true                      # Allow privileged containers
```

**Health Check:**
```bash
# Check API server readiness
curl -k https://127.0.0.1:6443/readyz?verbose
# Should return ok checks for etcd, log, and poststarthook
```

### 3. kube-controller-manager

**Purpose:** Runs controller processes that regulate the cluster state
- Node Controller: Monitors node health and responds to failures
- Replication Controller: Maintains correct number of pod replicas
- Service Account & Token Controllers: Manage service accounts and tokens
- Endpoint Controller: Manages endpoint objects

**Configuration:**
- **Kubeconfig:** /var/lib/kubelet/kubeconfig (for API server access)
- **Leader Election:** Disabled (`--leader-elect=false`) for single-node
- **Service Cluster IP Range:** 10.0.0.0/24 (matches API server)
- **Cloud Provider:** external (no cloud provider integration)

**Key Parameters:**
```bash
--leader-elect=false                         # Disable for single-node
--cloud-provider=external                    # No cloud provider
--service-cluster-ip-range=10.0.0.0/24      # Service IP range
--root-ca-file=/var/lib/kubelet/ca.crt      # CA certificate
--service-account-private-key-file=/tmp/sa.key  # Service account key
```

**Health Check:**
```bash
# Check controller manager logs for errors
# Should show "Starting controllers" and successful leader election skip
```

### 4. kube-scheduler

**Purpose:** Watches for newly created pods and assigns them to nodes
- Evaluates resource requirements, constraints, and policies
- Considers node resources, pod affinity/anti-affinity rules
- Implements scheduling algorithms (priority, preemption)
- Updates pod specifications with assigned node

**Configuration:**
- **Kubeconfig:** /root/.kube/config (for API server access)
- **Leader Election:** Disabled for single-node setup
- **Bind Address:** 0.0.0.0 (listen on all interfaces)
- **Log Level:** v=2 (moderate verbosity)

**Key Parameters:**
```bash
--leader-elect=false                         # Disable for single-node
--kubeconfig=/root/.kube/config             # API server access
--bind-address=0.0.0.0                      # Listen on all interfaces
--v=2                                       # Log level
```

**Health Check:**
```bash
# Check scheduler logs for "Successfully bound pod" messages
# Should show active scheduling decisions
```

### 5. kubelet

**Purpose:** Agent that runs on each node to ensure containers are running in pods
- Receives pod specifications from API server
- Starts, stops, and manages containers via CRI (Container Runtime Interface)
- Reports node and pod status back to API server
- Executes health checks and readiness probes

**Configuration:**
- **Kubeconfig:** /var/lib/kubelet/kubeconfig (for API server access)
- **Config File:** /var/lib/kubelet/config.yaml (detailed configuration)
- **Container Runtime:** unix:///run/containerd/containerd.sock
- **Pod Infra Image:** registry.k8s.io/pause:3.10 (pause container)
- **Max Pods:** 4 (limited for Codespaces resource constraints)

**Key Parameters:**
```bash
--kubeconfig=/var/lib/kubelet/kubeconfig    # API server access
--config=/var/lib/kubelet/config.yaml       # Detailed configuration
--containerRuntimeEndpoint=unix:///run/containerd/containerd.sock
--pod-infra-container-image=registry.k8s.io/pause:3.10
--hostname-override=$(hostname)             # Node name
--node-ip=$HOST_IP                         # Node IP address
--cgroup-driver=cgroupfs                   # Cgroup driver
--max-pods=4                              # Resource-constrained limit
```

**Health Check:**
```bash
# Check kubelet logs for "Starting kubelet" and pod management
# Should show successful node registration and pod lifecycle events
```

## Infrastructure Components

### 6. containerd

**Purpose:** Container runtime that manages the complete container lifecycle
- Implements Kubernetes Container Runtime Interface (CRI)
- Manages container images, storage, and network namespaces
- Provides runtime environment for containers
- Handles low-level container operations

**Configuration:**
- **Socket:** /run/containerd/containerd.sock (CRI endpoint)
- **CNI Configuration:** /etc/cni/net.d (network plugins)
- **CNI Binaries:** /opt/cni/bin (CNI plugin executables)
- **Runtime:** runc (Open Container Initiative runtime)

**Key Configuration (config.toml):**
```toml
[grpc]
  address = "/run/containerd/containerd.sock"

[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = false  # Use cgroupfs for compatibility
```

**Health Check:**
```bash
# Check containerd socket
ls -la /run/containerd/containerd.sock

# Check containerd info
ctr version

# List containers
crictl ps
```

### 7. CNI (Container Network Interface)

**Purpose:** Provides network connectivity for containers
- Creates network interfaces for pods
- Assigns IP addresses to containers
- Sets up networking rules and routes
- Enables pod-to-pod communication

**Plugins Used:**
- **bridge:** Creates a Linux bridge for pod networking
- **host-local:** Provides IP address management using local filesystem

**Configuration (10-mynet.conf):**
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
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
```

**Network Setup:**
- **Bridge Interface:** cni0 (connects all pods)
- **Pod Subnet:** 10.22.0.0/16 (pod IP addresses)
- **Gateway:** Automatic gateway configuration
- **IP Masquerading:** Enabled for external connectivity

**Health Check:**
```bash
# Check bridge interface
ip addr show cni0

# Check IP routes
ip route | grep 10.22

# Check iptables rules
iptables -t nat -L | grep 10.22
```

## Component Interaction

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   kubectl       │───▶│  kube-apiserver  │───▶│      etcd       │
│   (client)      │    │   (API server)   │    │  (data store)   │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                                │
                ┌───────────────┼───────────────┐
                │               │               │
        ┌───────▼───────┐ ┌─────▼──────┐ ┌─────▼──────┐
        │kube-controller│ │ kube-      │ │  kubelet   │
        │   manager     │ │ scheduler  │ │  (node)    │
        └───────────────┘ └────────────┘ └────────────┘
                                │
                ┌───────────────▼───────────────┐
                │         containerd            │
                │     (CRI runtime)             │
                └───────────────────────────────┘
                                │
                ┌───────────────▼───────────────┐
                │             CNI               │
                │    (network plugins)          │
                └───────────────────────────────┘
```

## Startup Order

1. **etcd** - Must start first as data store
2. **kube-apiserver** - Depends on etcd
3. **containerd** - Container runtime for CRI
4. **kube-scheduler** - Watches API server for pods
5. **kubelet** - Node agent, registers with API server
6. **kube-controller-manager** - Controllers manage cluster state

## Ports Used

| Component | Port | Purpose |
|-----------|------|---------|
| etcd | 2379 | Client API |
| etcd | 2380 | Peer communication |
| kube-apiserver | 6443 | Secure API endpoint |
| kubelet | 10250 | Health check endpoint |
| containerd | unix socket | CRI communication |

## Resource Considerations

**For Codespaces:**
- **max-pods=4:** Limited due to container resource constraints
- **SystemdCgroup = false:** Uses cgroupfs for compatibility
- **Pause image:** Minimal resource footprint for pod infrastructure
- **Self-signed certificates:** Development-only security

**Production Considerations:**
- Enable leader election for HA setups
- Use proper certificate management
- Configure resource limits and requests
- Implement proper authentication and authorization
- Use external etcd cluster for HA