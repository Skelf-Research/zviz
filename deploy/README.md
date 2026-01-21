# ZViz Deployment Guide

This directory contains everything needed to deploy ZViz in production.

## Quick Start

```bash
# Install ZViz
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
│  │  RuntimeClass: zviz                                    │    │
│  │  handler: zviz                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                     Worker Node                          │    │
│  │  ┌─────────────────────────────────────────────────┐    │    │
│  │  │  containerd                                      │    │    │
│  │  │  └── ZViz runtime (/usr/local/bin/zviz)     │    │    │
│  │  │       └── Pod (runtimeClassName: zviz)        │    │    │
│  │  └─────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Step 1: Install ZViz on All Worker Nodes

```bash
# On each worker node
curl -fsSL https://zviz.io/install.sh | sudo sh

# Or using the local install script
sudo ./install.sh
```

### Step 2: Configure containerd

```bash
# Append ZViz runtime config to containerd
sudo cat containerd/config.toml >> /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd

# Verify
sudo ctr plugins ls | grep zviz
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
  runtimeClassName: zviz  # <-- Add this line
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
    zviz.io/profile: "ci-runner"     # Security profile
    zviz.io/audit: "true"            # Enable audit logging
spec:
  runtimeClassName: zviz
  containers:
  - name: build
    image: node:20
    command: ["npm", "test"]
```

### Available Annotations

| Annotation | Description | Default |
|------------|-------------|---------|
| `zviz.io/profile` | Security profile name | `default` |
| `zviz.io/audit` | Enable audit logging | `false` |
| `zviz.io/broker-timeout` | Broker timeout (ms) | `1000` |
| `zviz.io/strict-mode` | Fail on unknown syscalls | `false` |

---

## containerd

For standalone containerd (without Kubernetes):

### Step 1: Install ZViz

```bash
sudo ./install.sh
```

### Step 2: Configure containerd

Add to `/etc/containerd/config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz.options]
    BinaryName = "/usr/local/bin/zviz"
    SystemdCgroup = true
```

### Step 3: Restart containerd

```bash
sudo systemctl restart containerd
```

### Step 4: Run Containers

```bash
# Using ctr
sudo ctr run --runtime io.containerd.runc.v2.zviz \
  docker.io/library/alpine:latest test echo "Hello from ZViz"

# Using nerdctl
sudo nerdctl run --runtime zviz alpine echo "Hello"
```

---

## Docker

### Step 1: Install ZViz

```bash
sudo ./install.sh
```

### Step 2: Configure Docker

Add to `/etc/docker/daemon.json`:

```json
{
  "runtimes": {
    "zviz": {
      "path": "/usr/local/bin/zviz"
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
docker run --runtime=zviz alpine echo "Hello from ZViz"
```

---

## Standalone

Use ZViz directly without a container runtime:

### Create an OCI Bundle

```bash
# Create bundle directory
mkdir -p mycontainer/rootfs

# Extract a rootfs (using Docker)
docker export $(docker create alpine) | tar -C mycontainer/rootfs -xf -

# Generate OCI spec
cd mycontainer
zviz spec
```

### Run the Container

```bash
# Create and start
sudo zviz run my-container . /bin/sh -c "echo Hello"

# Or separate create/start
sudo zviz create my-container .
sudo zviz start my-container
sudo zviz exec my-container /bin/sh
sudo zviz kill my-container
sudo zviz delete my-container
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
zviz version
zviz validate
```

### Check Kubernetes Integration

```bash
kubectl get runtimeclass
kubectl describe runtimeclass zviz
```

### Check containerd Integration

```bash
sudo ctr plugins ls | grep zviz
```

### Run Test Pod

```bash
kubectl apply -f kubernetes/example-pod.yaml
kubectl logs zviz-example
```

## Troubleshooting

### Pod Won't Start

```bash
# Check events
kubectl describe pod <pod-name>

# Check containerd logs
journalctl -u containerd -f

# Check ZViz logs
cat /var/log/zviz/*.log
```

### "Runtime not found"

```bash
# Verify binary exists
ls -la /usr/local/bin/zviz

# Verify containerd config
grep -A5 zviz /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
```

### Permission Issues

```bash
# Check capabilities
zviz validate

# Run validation
sudo zviz audit
```

## See Also

- [User Guide](../documentation/docs/user-guide/)
- [Operator Guide](../documentation/docs/operator-guide/)
- [Profiles Reference](../documentation/docs/reference/profile-schema.md)
