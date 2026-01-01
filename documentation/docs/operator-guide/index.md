# Operator Guide

This guide is for operators deploying and managing ZigViz in production environments.

## Overview

Operating ZigViz involves:

1. **Installation & Configuration** — Setting up ZigViz on nodes
2. **Integration** — Connecting with containerd/Kubernetes
3. **Monitoring** — Observing performance and security events
4. **Maintenance** — Upgrades, debugging, and troubleshooting

## Deployment Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                       │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                    Control Plane                     │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  RuntimeClass: zigviz                        │    │    │
│  │  │  handler: zigviz                             │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                     Worker Node                      │    │
│  │  ┌───────────────────────────────────────────────┐  │    │
│  │  │                   containerd                   │  │    │
│  │  │  ┌─────────────────────────────────────────┐  │  │    │
│  │  │  │           ZigViz Runtime                 │  │  │    │
│  │  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  │  │  │    │
│  │  │  │  │Container│  │Container│  │Container│  │  │  │    │
│  │  │  │  │   Pod   │  │   Pod   │  │   Pod   │  │  │  │    │
│  │  │  │  └─────────┘  └─────────┘  └─────────┘  │  │  │    │
│  │  │  └─────────────────────────────────────────┘  │  │    │
│  │  └───────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## Operator Guide Contents

<div class="grid cards" markdown>

-   :material-kubernetes:{ .lg .middle } __Kubernetes Integration__

    ---

    Deploy ZigViz as a Kubernetes RuntimeClass

    [:octicons-arrow-right-24: Kubernetes](kubernetes.md)

-   :material-server:{ .lg .middle } __containerd Setup__

    ---

    Configure containerd to use ZigViz

    [:octicons-arrow-right-24: containerd](containerd.md)

-   :material-chart-line:{ .lg .middle } __Monitoring__

    ---

    Prometheus metrics and alerting

    [:octicons-arrow-right-24: Monitoring](monitoring.md)

-   :material-speedometer:{ .lg .middle } __Performance Tuning__

    ---

    Optimize for your workload

    [:octicons-arrow-right-24: Performance](performance.md)

-   :material-bug:{ .lg .middle } __Debugging__

    ---

    Troubleshoot production issues

    [:octicons-arrow-right-24: Debugging](debugging.md)

-   :material-update:{ .lg .middle } __Upgrades__

    ---

    Safely upgrade ZigViz

    [:octicons-arrow-right-24: Upgrades](upgrades.md)

</div>

## Quick Deployment

### 1. Install ZigViz on All Nodes

```bash
# On each worker node
curl -fsSL https://zigviz.io/install.sh | sh
```

### 2. Configure containerd

```bash
# Add to /etc/containerd/config.toml
cat >> /etc/containerd/config.toml << 'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz.options]
    BinaryName = "/usr/local/bin/zigviz"
EOF

systemctl restart containerd
```

### 3. Create RuntimeClass

```yaml
# zigviz-runtimeclass.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zigviz
handler: zigviz
scheduling:
  nodeSelector:
    zigviz.io/enabled: "true"
```

```bash
kubectl apply -f zigviz-runtimeclass.yaml
```

### 4. Deploy Pods with ZigViz

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  annotations:
    zigviz.io/profile: "ci-runner"
spec:
  runtimeClassName: zigviz
  containers:
  - name: app
    image: my-app:latest
```

## Host Requirements

### Kernel Configuration

Verify required kernel options:

```bash
zigviz validate
```

Required:

- `CONFIG_SECCOMP_FILTER=y`
- `CONFIG_SECCOMP_USER_NOTIFICATION=y`
- `CONFIG_USER_NS=y`
- `CONFIG_CGROUPS=y`
- `CONFIG_CGROUP_BPF=y`

Recommended:

- `CONFIG_SECURITY_APPARMOR=y` or `CONFIG_SECURITY_SELINUX=y`
- `CONFIG_SECURITY_LANDLOCK=y`

### System Limits

```bash
# /etc/sysctl.conf
kernel.unprivileged_userns_clone = 1
kernel.pid_max = 65536
fs.file-max = 1048576
```

### cgroups v2

Ensure cgroups v2 is enabled:

```bash
mount | grep cgroup2
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)
```

## Security Considerations

### Principle of Least Privilege

- Run ZigViz with minimum required capabilities
- Use read-only root filesystems
- Apply network policies

### Audit Logging

Enable audit logging for security events:

```yaml
# /etc/zigviz/config.yaml
logging:
  level: info
  format: json
  audit:
    enabled: true
    path: /var/log/zigviz/audit.json
```

### Security Updates

Subscribe to security advisories:

```bash
# Check for updates
zigviz version --check-update

# View security advisories
zigviz security advisories
```

## Capacity Planning

### Memory

| Component | Memory |
|-----------|--------|
| ZigViz broker | ~5MB per container |
| Base overhead | ~2MB |
| Profile cache | ~1MB |

### CPU

- Broker adds ~5% overhead for syscall-heavy workloads
- Network-heavy workloads see <2% overhead

### Storage

| Path | Purpose | Recommended Size |
|------|---------|------------------|
| `/var/lib/zigviz` | State directory | 1GB |
| `/var/log/zigviz` | Logs | 10GB |

## Troubleshooting

### Container Won't Start

```bash
# Check logs
journalctl -u containerd -f

# Debug mode
zigviz --log-level debug create ...
```

### Permission Denied

```bash
# Check capabilities
zigviz validate

# Check AppArmor/SELinux
aa-status
setenforce 0  # Temporarily disable SELinux
```

### Performance Issues

```bash
# Check metrics
zigviz metrics

# Run benchmarks
zigviz benchmark
```

See [Debugging Guide](debugging.md) for detailed troubleshooting.

## Support Matrix

| Kubernetes Version | Status |
|-------------------|--------|
| 1.30+ | Supported |
| 1.28-1.29 | Supported |
| 1.26-1.27 | Best effort |
| < 1.26 | Not supported |

| Linux Distribution | Status |
|-------------------|--------|
| Ubuntu 22.04+ | Supported |
| Debian 12+ | Supported |
| RHEL 9+ | Supported |
| Fedora 38+ | Supported |
| Amazon Linux 2023 | Supported |
