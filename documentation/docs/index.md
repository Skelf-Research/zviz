# ZViz

**High-performance container isolation with gVisor-grade security**

ZViz is a Zig-based container isolation runtime that delivers strong security guarantees with near-native performance. It achieves gVisor-equivalent policy outcomes without a userspace kernel, using layered kernel primitives and a minimal syscall broker.

<div class="grid cards" markdown>

-   :material-rocket-launch:{ .lg .middle } __Get Started in 5 Minutes__

    ---

    Install ZViz and run your first isolated container

    [:octicons-arrow-right-24: Quick Start](getting-started/quickstart.md)

-   :material-shield-check:{ .lg .middle } __Security First__

    ---

    Five-layer enforcement model with defense in depth

    [:octicons-arrow-right-24: Security Model](architecture/threat-model.md)

-   :material-kubernetes:{ .lg .middle } __Kubernetes Native__

    ---

    Drop-in RuntimeClass for existing clusters

    [:octicons-arrow-right-24: Kubernetes Guide](operator-guide/kubernetes.md)

-   :material-speedometer:{ .lg .middle } __Near-Native Performance__

    ---

    < 5% overhead for network workloads, 2x+ density vs gVisor

    [:octicons-arrow-right-24: Performance](architecture/performance.md)

</div>

## Why ZViz?

### The Problem

Running untrusted workloads requires strong isolation. Traditional containers (runc) share the kernel attack surface with the host. gVisor provides excellent isolation but at significant performance cost—especially for network-intensive workloads.

### The Solution

ZViz reaches gVisor-equivalent security outcomes through **layered kernel enforcement** rather than syscall emulation:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| A | Namespaces + Capabilities | Resource isolation |
| B | Seccomp-BPF + Broker | Syscall mediation |
| C | AppArmor/SELinux/Landlock | Object-level policy |
| D | cgroups v2 | Resource limits |
| E | Network namespace + nftables | Network policy |

### Performance Comparison

```
Workload: HTTP throughput (requests/sec, higher is better)

runc (baseline)     ████████████████████████████████████████  100%
ZViz              ██████████████████████████████████████    95%
gVisor              ██████████████████                        45%
```

## Key Features

- **gVisor-grade policy enforcement** — Same security outcomes, different mechanism
- **Near-native performance** — Kernel networking, minimal broker overhead
- **Profile-driven security** — Declarative YAML profiles, compile-time validation
- **Kubernetes native** — RuntimeClass integration, pod annotations
- **Observable** — Prometheus metrics, structured audit logs
- **Written in Zig** — Single static binary, no runtime dependencies

## Use Cases

ZViz is designed for:

- **CI/CD runners** — Isolated build environments for untrusted code
- **Multi-tenant platforms** — Strong tenant isolation with high density
- **Plugin execution** — Safe execution of third-party extensions
- **Serverless workloads** — Fast startup, low memory overhead

## Quick Example

```bash
# Install ZViz
curl -fsSL https://zviz.io/install.sh | sh

# Run a container with the CI runner profile
zviz run --profile ci-runner my-build /bin/sh -c "npm install && npm test"
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Container                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    Application                           │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              │ syscall                           │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Seccomp-BPF Filter (Layer B)               │    │
│  │    ┌──────────┬──────────────┬─────────────────────┐    │    │
│  │    │  ALLOW   │    DENY      │  USER_NOTIF         │    │    │
│  │    │ (fast)   │  (blocked)   │  (mediated)         │    │    │
│  │    └──────────┴──────────────┴──────────┬──────────┘    │    │
│  └─────────────────────────────────────────│───────────────┘    │
└────────────────────────────────────────────│────────────────────┘
                                             │
                                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                      ZViz Broker                               │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  openat │ ioctl │ socket │ clone │ execve │ prctl       │    │
│  │         Argument validation + policy decision           │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              │ fd / result                       │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Host Kernel (trusted)                       │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Getting Help

- **Documentation**: You're reading it!
- **GitHub Issues**: [github.com/zviz/zviz/issues](https://github.com/zviz/zviz/issues)
- **Security Issues**: See [Security Policy](security/index.md)

## License

ZViz is licensed under the Apache License 2.0. See [LICENSE](https://github.com/zviz/zviz/blob/main/LICENSE) for details.
