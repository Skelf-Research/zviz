# ZViz

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Platform](https://img.shields.io/badge/platform-Linux-green.svg)](https://github.com/Skelf-Research/zviz)

**High-performance container isolation with gVisor-grade security**

ZViz is a Zig-based container runtime that delivers strong security guarantees with near-native performance. It achieves 98.2% policy compatibility with gVisor without a userspace kernel, using layered Linux kernel primitives instead.

## Security Results

Validated security enforcement with live testing:

| Metric | Result |
|--------|--------|
| Security attacks blocked | 8/8 (ptrace, raw sockets, mount, bpf, kexec, module loading, shadow access, chroot) |
| Escape tests blocked | 19/19 (namespace, capability, seccomp, filesystem, network, resource) |
| gVisor policy compatibility | 98.2% (54/55 checks match) |
| Policy difference | 1: Network egress default-deny (deliberate design choice) |

## Why ZViz?

**The Problem**: Running untrusted code requires strong isolation. Traditional containers (runc) share the kernel attack surface. gVisor provides excellent isolation but with significant performance overhead from syscall emulation.

**The Solution**: ZViz uses layered kernel enforcement instead of syscall emulation:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| 1. Namespaces | user, pid, mount, ipc, uts | Resource isolation |
| 2. Seccomp-BPF | 124-instruction filter (90 allow, 22 deny) | Syscall filtering |
| 3. Capabilities | All 41 capabilities dropped | Privilege reduction |
| 4. Landlock LSM | Filesystem access rules | Object-level access control |
| 5. cgroups v2 | memory, cpu, pids | Resource limits |

## Performance

| Metric | ZViz | gVisor | runc (baseline) |
|--------|------|--------|-----------------|
| Cold start | ~8ms | ~200ms | ~50ms |
| Allowed syscall overhead | ~0 | +50-100us | ~0 |
| Memory per container | ~2MB | ~50MB | ~0 |
| I/O throughput | ~95% native | ~40% native | 100% |
| CPU-bound workload | ~99% native | ~95% native | 100% |

ZViz's allowed syscalls (read, write, mmap, etc.) execute at native kernel speed. Only 5 brokered syscalls pay mediation overhead (~50-100us). gVisor emulates all ~300 syscalls through its userspace Sentry.

## Comparison with gVisor

ZViz achieves gVisor-equivalent security outcomes through a fundamentally different architecture:

```
gVisor:  App → Sentry (emulates ~300 syscalls) → Host kernel (~70 syscalls)
ZViz:    App → BPF filter → ALLOW (90, native) / DENY (22) / BROKER (5, mediated)
```

The 1.8% policy gap is a single difference: ZViz defaults to **denying** egress to public internet (requiring explicit CIDR allowlisting), while gVisor allows it by default. This is a deliberate defense-in-depth choice.

See [full comparison](documentation/docs/architecture/comparison.md) for detailed analysis including Kata Containers and Firecracker.

## Quick Start

```bash
# Build from source (requires Zig 0.15.0+)
git clone https://github.com/Skelf-Research/zviz.git
cd zviz
zig build -Doptimize=ReleaseSafe

# Run a container
./zig-out/bin/zviz run my-container /path/to/bundle

# Run the demo (security tests + escape tests + performance)
./demo.sh --all

# Validate system compatibility
./zig-out/bin/zviz validate
```

## Use Cases

| Use Case | Why ZViz? |
|----------|-----------|
| **CI/CD Runners** | Isolated build environments for untrusted code, ~8ms cold start |
| **Multi-tenant Platforms** | Strong isolation with 25x better density than gVisor |
| **Plugin Execution** | Safe execution of third-party extensions |
| **High-Performance Computing** | Near-zero overhead on allowed syscalls |

## Architecture

ZViz enforces security through five layers applied in the container child process:

1. **Namespaces**: User, PID, mount, IPC, UTS isolation via `unshare()`
2. **Capabilities**: All 41 Linux capabilities dropped via `prctl(PR_CAPBSET_DROP)`
3. **Landlock**: Filesystem access rules (read-only rootfs, writable /tmp and /work only)
4. **Seccomp-BPF**: 124-instruction filter classifying all syscalls into allow/deny/broker
5. **cgroups v2**: Memory, PID, and CPU limits

The ordering matters: capabilities are dropped before seccomp loads, and Landlock is applied before seccomp to ensure the security setup syscalls themselves aren't blocked.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](documentation/docs/architecture/index.md) | System design and enforcement layers |
| [Comparison](documentation/docs/architecture/comparison.md) | Detailed comparison with gVisor, runc, Kata, Firecracker |
| [Performance](documentation/docs/architecture/performance.md) | Measured benchmarks and overhead analysis |
| [Threat Model](documentation/docs/architecture/threat-model.md) | Security goals and assumptions |
| [Enforcement Model](documentation/docs/architecture/enforcement-model.md) | Five-layer enforcement architecture |

## Requirements

- **Linux kernel >= 5.13** (Landlock LSM support)
- **cgroups v2** enabled
- **Zig 0.15.0+** for building from source

## Security

ZViz earns trust through:

- Live security testing (8 attack vectors verified blocked in every demo run)
- 19-point escape test suite (namespace, capability, seccomp, filesystem, network, resource)
- 98.2% policy compatibility with gVisor (validated via `zviz compare`)
- Generated, auditable BPF filters (124 instructions, fully deterministic)
- Layered enforcement (no single point of failure)

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache License 2.0 - See [LICENSE](LICENSE)
