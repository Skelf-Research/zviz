# ZigViz Deployment Guide

This directory contains everything needed to deploy ZigViz in production.

## Quick Start

```bash
# Install ZigViz
sudo ./install.sh

# For Kubernetes
kubectl apply -f kubernetes/runtime-class.yaml
```

## Deployment Options

| Environment | Guide |
|-------------|-------|
| Kubernetes | [kubernetes/](#kubernetes) |
| containerd (standalone) | [containerd/](#containerd) |
| Docker | [docker/](#docker) |
| Standalone | [standalone/](#standalone) |

---

## Kubernetes

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                           │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  RuntimeClass: zigviz                                    │    │
│  │  handler: zigviz                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                     Worker Node                          │    │
│  │  ┌─────────────────────────────────────────────────┐    │    │
│  │  │  containerd                                      │    │    │
│  │  │  └── ZigViz runtime (/usr/local/bin/zigviz)     │    │    │
│  │  │       └── Pod (runtimeClassName: zigviz)        │    │    │
│  │  └─────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Step 1: Install ZigViz on All Worker Nodes

```bash
# On each worker node
curl -fsSL https://zigviz.io/install.sh | sudo sh

# Or using the local install script
sudo ./install.sh
```

### Step 2: Configure containerd

```bash
# Append ZigViz runtime config to containerd
sudo cat containerd/config.toml >> /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd

# Verify
sudo ctr plugins ls | grep zigviz
```

### Step 3: Create RuntimeClass

```bash
kubectl apply -f kubernetes/runtime-class.yaml
```

### Step 4: Deploy Workloads

```yaml
# Your pod spec
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  runtimeClassName: zigviz  # <-- Add this line
  containers:
  - name: app
    image: my-app:latest
```

### Step 5: Use Security Profiles

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ci-job
  annotations:
    zigviz.io/profile: "ci-runner"     # Security profile
    zigviz.io/audit: "true"            # Enable audit logging
spec:
  runtimeClassName: zigviz
  containers:
  - name: build
    image: node:20
    command: ["npm", "test"]
```

### Available Annotations

| Annotation | Description | Default |
|------------|-------------|---------|
| `zigviz.io/profile` | Security profile name | `default` |
| `zigviz.io/audit` | Enable audit logging | `false` |
| `zigviz.io/broker-timeout` | Broker timeout (ms) | `1000` |
| `zigviz.io/strict-mode` | Fail on unknown syscalls | `false` |

---

## containerd

For standalone containerd (without Kubernetes):

### Step 1: Install ZigViz

```bash
sudo ./install.sh
```

### Step 2: Configure containerd

Add to `/etc/containerd/config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz.options]
    BinaryName = "/usr/local/bin/zigviz"
    SystemdCgroup = true
```

### Step 3: Restart containerd

```bash
sudo systemctl restart containerd
```

### Step 4: Run Containers

```bash
# Using ctr
sudo ctr run --runtime io.containerd.runc.v2.zigviz \
  docker.io/library/alpine:latest test echo "Hello from ZigViz"

# Using nerdctl
sudo nerdctl run --runtime zigviz alpine echo "Hello"
```

---

## Docker

### Step 1: Install ZigViz

```bash
sudo ./install.sh
```

### Step 2: Configure Docker

Add to `/etc/docker/daemon.json`:

```json
{
  "runtimes": {
    "zigviz": {
      "path": "/usr/local/bin/zigviz"
    }
  }
}
```

### Step 3: Restart Docker

```bash
sudo systemctl restart docker
```

### Step 4: Run Containers

```bash
docker run --runtime=zigviz alpine echo "Hello from ZigViz"
```

---

## Standalone

Use ZigViz directly without a container runtime:

### Create an OCI Bundle

```bash
# Create bundle directory
mkdir -p mycontainer/rootfs

# Extract a rootfs (using Docker)
docker export $(docker create alpine) | tar -C mycontainer/rootfs -xf -

# Generate OCI spec
cd mycontainer
zigviz spec
```

### Run the Container

```bash
# Create and start
sudo zigviz run my-container . /bin/sh -c "echo Hello"

# Or separate create/start
sudo zigviz create my-container .
sudo zigviz start my-container
sudo zigviz exec my-container /bin/sh
sudo zigviz kill my-container
sudo zigviz delete my-container
```

---

## Directory Structure

```
deploy/
├── README.md              # This file
├── install.sh             # Installation script
├── containerd/
│   └── config.toml        # containerd runtime config
└── kubernetes/
    ├── runtime-class.yaml # RuntimeClass definitions
    ├── example-pod.yaml   # Basic pod example
    └── pod-with-profile.yaml # Pod with annotations
```

## Verification

### Check Installation

```bash
zigviz version
zigviz validate
```

### Check Kubernetes Integration

```bash
kubectl get runtimeclass
kubectl describe runtimeclass zigviz
```

### Check containerd Integration

```bash
sudo ctr plugins ls | grep zigviz
```

### Run Test Pod

```bash
kubectl apply -f kubernetes/example-pod.yaml
kubectl logs zigviz-example
```

## Troubleshooting

### Pod Won't Start

```bash
# Check events
kubectl describe pod <pod-name>

# Check containerd logs
journalctl -u containerd -f

# Check ZigViz logs
cat /var/log/zigviz/*.log
```

### "Runtime not found"

```bash
# Verify binary exists
ls -la /usr/local/bin/zigviz

# Verify containerd config
grep -A5 zigviz /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
```

### Permission Issues

```bash
# Check capabilities
zigviz validate

# Run validation
sudo zigviz audit
```

## See Also

- [User Guide](../documentation/docs/user-guide/)
- [Operator Guide](../documentation/docs/operator-guide/)
- [Profiles Reference](../documentation/docs/reference/profile-schema.md)
