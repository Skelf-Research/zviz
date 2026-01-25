# Getting Started

Welcome to ZViz - container isolation for code you can't trust but have to run.

## What is ZViz?

ZViz is a container isolation runtime that provides strong security guarantees with minimal performance overhead. It's designed for running untrusted workloads like:

- **AI agents** executing LLM-generated code
- **CI/CD pipelines** with untrusted dependencies
- **Third-party plugins** and extensions
- **Multi-tenant applications**
- **Serverless functions**

## The Problem It Solves

Traditional containers (runc) share the kernel attack surface with the host. Every container escape CVE is a reminder that "containerized" isn't a security strategy.

gVisor provides strong isolation by emulating syscalls in userspace, but at a cost: 5-250x syscall overhead and ~200ms cold starts.

ZViz achieves gVisor-grade security with native performance by using layered kernel primitives instead of syscall emulation.

## How is it Different?

| Feature | runc | gVisor | ZViz |
|---------|------|--------|------|
| Kernel shared with host | Yes | No | Yes (isolated) |
| Syscall interception | No | All | Security-relevant only |
| Performance overhead | Baseline | 30-70% | <5% |
| Memory per container | ~2MB | ~50MB | ~2MB |
| Cold start | ~50ms | ~200ms | ~8ms |
| Network performance | Native | Emulated | Native |

## Prerequisites

Before installing ZViz, ensure your system meets these requirements:

### Minimum Requirements

- **Linux kernel**: 5.13+ (Landlock LSM support)
- **Architecture**: x86_64 or aarch64
- **cgroups v2**: Enabled

### Required Kernel Features

- `CONFIG_SECCOMP_FILTER=y`
- `CONFIG_USER_NS=y`
- `CONFIG_CGROUPS=y` (cgroups v2)
- `CONFIG_SECURITY_LANDLOCK=y`

You can check your system compatibility:

```bash
zviz validate
```

## Quick Links

<div class="grid cards" markdown>

-   :material-download:{ .lg .middle } __Installation__

    ---

    Build ZViz from source

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
