# Getting Started

Welcome to ZViz! This guide will help you get up and running with ZViz in just a few minutes.

## What is ZViz?

ZViz is a container isolation runtime that provides strong security guarantees with minimal performance overhead. It's designed for running untrusted workloads like:

- CI/CD pipelines
- Multi-tenant applications
- Plugin/extension execution
- Serverless functions

## How is it Different?

| Feature | runc | gVisor | ZViz |
|---------|------|--------|--------|
| Kernel shared with host | Yes | No | Yes (isolated) |
| Syscall interception | No | All | Security-relevant only |
| Performance overhead | Baseline | 30-70% | 5-10% |
| Memory per container | ~2MB | ~50MB | ~5MB |
| Network performance | Native | Emulated | Native |

## Prerequisites

Before installing ZViz, ensure your system meets these requirements:

### Minimum Requirements

- **Linux kernel**: 5.15+ (recommended: 6.1+)
- **Architecture**: x86_64 or aarch64
- **Memory**: 512MB available
- **Disk**: 50MB for binary and profiles

### Required Kernel Features

- `CONFIG_SECCOMP_FILTER=y`
- `CONFIG_USER_NS=y`
- `CONFIG_CGROUPS=y` (cgroups v2)

### Optional Features

For full functionality, these are recommended:

- **AppArmor** or **SELinux** for LSM enforcement
- **Landlock** (kernel 5.13+) as LSM fallback
- **nftables** for network policy

You can check your system compatibility:

```bash
zviz validate
```

## Quick Links

<div class="grid cards" markdown>

-   :material-download:{ .lg .middle } __Installation__

    ---

    Install ZViz on your system

    [:octicons-arrow-right-24: Install](installation.md)

-   :material-play:{ .lg .middle } __Quick Start__

    ---

    Run your first isolated container

    [:octicons-arrow-right-24: Quick Start](quickstart.md)

-   :material-school:{ .lg .middle } __Tutorial__

    ---

    Step-by-step guide to container isolation

    [:octicons-arrow-right-24: First Container](first-container.md)

</div>

## Next Steps

1. [Install ZViz](installation.md)
2. [Run your first container](quickstart.md)
3. [Learn about profiles](../user-guide/profiles.md)
4. [Set up Kubernetes integration](../operator-guide/kubernetes.md)
