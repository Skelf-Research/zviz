# ZViz

[![CI](https://github.com/Skelf-Research/zviz/actions/workflows/ci.yml/badge.svg)](https://github.com/Skelf-Research/zviz/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Release](https://img.shields.io/github/v/release/Skelf-Research/zviz)](https://github.com/Skelf-Research/zviz/releases/latest)
[![Platform](https://img.shields.io/badge/platform-Linux-green.svg)](https://github.com/Skelf-Research/zviz)

**High-performance container isolation with gVisor-grade security**

ZViz is a Zig-based container runtime that delivers strong security guarantees with near-native performance. It achieves gVisor-equivalent policy enforcement without a userspace kernel by using layered Linux kernel primitives.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/Skelf-Research/zviz/main/deploy/install.sh | sh
```

Or with package managers:

```bash
# Debian/Ubuntu
sudo apt install zviz

# Fedora/RHEL
sudo dnf install zviz
```

[Full Installation Guide](docs/deployment.md) | [Build from Source](#build-from-source)

## Why ZViz?

**The Problem**: Running untrusted code requires strong isolation. Traditional containers (runc) share the kernel attack surface. gVisor provides excellent isolation but with 50%+ performance overhead.

**The Solution**: ZViz uses layered kernel enforcement instead of syscall emulation:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| 1. Namespaces | user, pid, net, mount, ipc, uts | Resource isolation |
| 2. Seccomp-BPF | + Zig broker for mediated syscalls | Syscall filtering |
| 3. LSM | AppArmor / SELinux / Landlock | Object-level access control |
| 4. cgroups v2 | memory, cpu, io, pids | Resource limits |
| 5. Network | nftables / eBPF | Network policy |

## Performance

| Workload | ZViz | gVisor | runc (baseline) |
|----------|------|--------|-----------------|
| HTTP throughput | 95% | 45% | 100% |
| CPU-bound tasks | 95% | 70% | 100% |
| I/O-bound tasks | 92% | 40% | 100% |
| Container startup | 98% | 60% | 100% |
| Memory overhead | +2MB | +50MB | baseline |

*Relative to runc baseline. Higher is better. See [benchmark methodology](docs/benchmark-methodology.md).*

## Quick Start

```bash
# Run a container with ZViz isolation
zviz run --bundle ./my-container

# With a security profile
zviz run --profile ci-runner --bundle ./build-container

# Validate system compatibility
zviz validate
```

### Kubernetes Integration

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-build
spec:
  runtimeClassName: zviz
  containers:
  - name: build
    image: node:20
    command: ["npm", "test"]
```

## Use Cases

| Use Case | Why ZViz? |
|----------|-----------|
| **CI/CD Runners** | Isolated build environments for untrusted code with minimal overhead |
| **Multi-tenant Platforms** | Strong tenant isolation with 2x density vs gVisor |
| **Plugin Execution** | Safe execution of third-party extensions |
| **Serverless / FaaS** | Fast cold start (~5ms overhead), low memory footprint |

## Architecture

ZViz enforces gVisor-grade policy outcomes using native Linux mechanisms:

- **Namespaces + Capabilities**: Process isolation and privilege reduction
- **Seccomp-BPF + Zig Broker**: Syscall filtering with intelligent mediation
- **LSM Integration**: Object-level access control (files, sockets, etc.)
- **Network Policy**: Egress/ingress control via nftables or eBPF
- **cgroups v2**: Resource limits and accounting

A small Zig broker receives seccomp user-notification events for security-critical syscalls, applies policy, and returns results safely. This achieves strong isolation without kernel emulation overhead.

## Documentation

| Document | Description |
|----------|-------------|
| [Overview](docs/overview.md) | Project goals and architecture |
| [Threat Model](docs/threat-model.md) | Security goals and assumptions |
| [Enforcement Model](docs/enforcement-model.md) | Five-layer enforcement architecture |
| [Deployment Guide](docs/deployment.md) | containerd/Kubernetes integration |
| [Profile Authoring](docs/policy-profiles.md) | Creating security profiles |
| [Performance Analysis](docs/performance-cost.md) | Benchmarks and cost comparison |

## Modes

- **High-density mode** (default): Policy enforcement with kernel primitives + broker
- **Hostile-tenant mode**: Same policy system inside a microVM boundary for additional kernel attack-surface reduction

## Build from Source

```bash
# Requires Zig 0.15.0+
git clone https://github.com/Skelf-Research/zviz.git
cd zviz
zig build -Doptimize=ReleaseSafe

# Install
sudo cp zig-out/bin/zviz /usr/local/bin/

# Verify
zviz version
```

## Requirements

- **Linux kernel >= 5.6** (seccomp user notification support)
- **cgroups v2** enabled
- **Optional**: AppArmor or SELinux for LSM enforcement
- **Optional**: containerd >= 1.6 for Kubernetes integration

## Security

ZViz earns trust through:

- Generated, auditable policy outputs (seccomp BPF, LSM rules, network filters)
- Deterministic broker decision logs
- Differential testing against gVisor
- Escape-class test suite
- Continuous fuzzing on broker boundaries

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache License 2.0 - See [LICENSE](LICENSE)

---

<p align="center">
  <sub>Built with Zig. Secured by Linux.</sub>
</p>
