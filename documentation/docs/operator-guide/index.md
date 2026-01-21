# Operator Guide

This guide is for operators deploying and managing ZViz in production environments.

## Overview

Operating ZViz involves:

1. **Installation & Configuration** — Setting up ZViz on nodes
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
│  │  │  RuntimeClass: zviz                        │    │    │
│  │  │  handler: zviz                             │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                     Worker Node                      │    │
│  │  ┌───────────────────────────────────────────────┐  │    │
│  │  │                   containerd                   │  │    │
│  │  │  ┌─────────────────────────────────────────┐  │  │    │
│  │  │  │           ZViz Runtime                 │  │  │    │
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

    Deploy ZViz as a Kubernetes RuntimeClass

    [:octicons-arrow-right-24: Kubernetes](kubernetes.md)

-   :material-server:{ .lg .middle } __containerd Setup__

    ---

    Configure containerd to use ZViz

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

    Safely upgrade ZViz

    [:octicons-arrow-right-24: Upgrades](upgrades.md)

</div>

## Quick Deployment

### 1. Install ZViz on All Nodes

```bash
# On each worker node
curl -fsSL https://zviz.io/install.sh | sh
```

### 2. Configure containerd

```bash
# Add to /etc/containerd/config.toml
cat >> /etc/containerd/config.toml << 'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz.options]
    BinaryName = "/usr/local/bin/zviz"
EOF

systemctl restart containerd
```

### 3. Create RuntimeClass

```yaml
# zviz-runtimeclass.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zviz
handler: zviz
scheduling:
  nodeSelector:
    zviz.io/enabled: "true"
```

```bash
kubectl apply -f zviz-runtimeclass.yaml
```

### 4. Deploy Pods with ZViz

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-workload
  annotations:
    zviz.io/profile: "ci-runner"
spec:
  runtimeClassName: zviz
  containers:
  - name: app
    image: my-app:latest
```

## Host Requirements

### Kernel Configuration

Verify required kernel options:

```bash
zviz validate
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

- Run ZViz with minimum required capabilities
- Use read-only root filesystems
- Apply network policies

### Audit Logging

Enable audit logging for security events:

```yaml
# /etc/zviz/config.yaml
logging:
  level: info
  format: json
  audit:
    enabled: true
    path: /var/log/zviz/audit.json
```

### Security Updates

Subscribe to security advisories:

```bash
# Check for updates
zviz version --check-update

# View security advisories
zviz security advisories
```

## Capacity Planning

### Memory

| Component | Memory |
|-----------|--------|
| ZViz broker | ~5MB per container |
| Base overhead | ~2MB |
| Profile cache | ~1MB |

### CPU

- Broker adds ~5% overhead for syscall-heavy workloads
- Network-heavy workloads see <2% overhead

### Storage

| Path | Purpose | Recommended Size |
|------|---------|------------------|
| `/var/lib/zviz` | State directory | 1GB |
| `/var/log/zviz` | Logs | 10GB |

## Troubleshooting

### Container Won't Start

```bash
# Check logs
journalctl -u containerd -f

# Debug mode
zviz --log-level debug create ...
```

### Permission Denied

```bash
# Check capabilities
zviz validate

# Check AppArmor/SELinux
aa-status
setenforce 0  # Temporarily disable SELinux
```

### Performance Issues

```bash
# Check metrics
zviz metrics

# Run benchmarks
zviz benchmark
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
