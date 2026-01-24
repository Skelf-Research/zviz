# Comparison with Other Container Runtimes

ZViz achieves gVisor-equivalent security outcomes without a userspace kernel. This page provides a comprehensive comparison with other container isolation approaches.

## Approach Overview

| Aspect | runc | gVisor | ZViz | Kata Containers | Firecracker |
|--------|------|--------|------|-----------------|-------------|
| Isolation mechanism | Namespaces only | Userspace kernel (Sentry) | Layered kernel primitives | Hardware VM (QEMU/Cloud Hypervisor) | MicroVM (KVM) |
| Kernel attack surface | Full (~300+ syscalls) | Minimal (~70 syscalls to host) | Controlled (90 allowed, 22 denied) | Full guest kernel | Minimal host exposure |
| Performance overhead | Baseline | 50-100% (all syscalls emulated) | 5-10% (only brokered syscalls) | 15-30% (VM exit cost) | 10-20% (VM exit cost) |
| Memory overhead | ~0 | ~50MB (Sentry process) | ~2MB (static binary) | ~128MB (guest kernel + OS) | ~5MB (minimal guest) |
| Cold start | ~50ms | ~200ms | ~8ms | ~1s | ~125ms |
| Linux compatibility | Full | Limited (not all syscalls) | Near-full (90 syscalls native) | Full | Full |
| Rootless support | Yes | Partial | Yes | No (requires KVM) | No (requires KVM) |
| Hardware requirements | None | None | None | VT-x/AMD-V | VT-x/AMD-V |

## How ZViz Compares to gVisor

### Architecture Difference

```
gVisor:
  Application → Sentry (userspace kernel) → Host kernel (~70 syscalls)
                    ↑ emulates ~300 syscalls in userspace

ZViz:
  Application → Seccomp BPF filter
                    ├── ALLOW (90 syscalls) → direct to kernel
                    ├── DENY  (22 syscalls) → immediate EPERM
                    └── BROKER (mediated)   → Zig broker → kernel

runc:
  Application → Kernel (all ~300+ syscalls available)
```

gVisor interposes on **every** syscall through its Sentry process, which emulates a Linux kernel in userspace. This provides strong isolation but at significant performance cost - every `read()`, `write()`, or `mmap()` pays the emulation overhead.

ZViz takes a different approach: safe syscalls (read, write, mmap, etc.) go directly to the host kernel at native speed. Only dangerous syscalls are blocked outright, and a small set requiring argument inspection are routed through the broker. The result is equivalent security policy enforcement with far less overhead.

### Policy Compatibility: 98.2%

ZViz was validated against gVisor's security policy across 55 individual checks:

| Category | Checks | Matches | Details |
|----------|--------|---------|---------|
| Syscall filtering | 25 | 25/25 | Both block ptrace, mount, bpf, kexec_load, etc. |
| Namespace isolation | 8 | 8/8 | User, PID, mount, network, IPC, UTS |
| Capability restrictions | 10 | 10/10 | All 41 capabilities dropped |
| Resource limits | 6 | 6/6 | Memory, PID, CPU limits enforced |
| Network policy | 5 | 4/5 | 1 difference: egress default |
| Filesystem access | 1 | 1/1 | Read-only rootfs enforced |
| **Total** | **55** | **54/55** | **98.2% compatibility** |

### The 1.8% Difference

The single policy difference is **network egress to public internet**:

| | ZViz | gVisor |
|--|------|--------|
| Default egress policy | **DENIED** | ALLOWED |
| Rationale | Defense-in-depth: explicit allowlist | Relies on network namespace isolation |

This is a deliberate design choice. ZViz defaults to denying outbound connections to public IPs, requiring explicit allowlisting of permitted CIDRs in the profile. gVisor allows egress by default, relying on the network namespace and external network policy for control.

For environments requiring internet access (package downloads during CI), the ZViz profile's `network.allow_cidrs` field permits specific ranges.

## Security Guarantees

### Live Security Tests (8/8 blocked)

These attacks are tested live inside running ZViz containers:

| Attack Vector | ZViz | gVisor | runc (default) | Mechanism |
|---------------|------|--------|----------------|-----------|
| `ptrace(PTRACE_TRACEME)` | BLOCKED | BLOCKED | allowed | Seccomp deny list |
| `socket(AF_PACKET, SOCK_RAW)` | BLOCKED | BLOCKED | allowed | BPF socket domain filter |
| `mount("proc", "/mnt", "proc")` | BLOCKED | BLOCKED | allowed | Seccomp deny list |
| `init_module(NULL, 0, "")` | BLOCKED | BLOCKED | allowed | Seccomp deny list |
| `bpf(BPF_PROG_LOAD, ...)` | BLOCKED | BLOCKED | allowed | Seccomp deny list |
| `kexec_load(0, 0, NULL, 0)` | BLOCKED | BLOCKED | allowed | Seccomp deny list |
| `open("/etc/shadow")` | BLOCKED | BLOCKED | allowed | Landlock LSM |
| `chroot("/")` | BLOCKED | BLOCKED | allowed | Seccomp deny + capabilities |

### Escape Test Suite (19/19 blocked)

ZViz blocks all 19 escape-class attacks:

| Category | Tests | Description |
|----------|-------|-------------|
| Namespace escapes | 5 | Attempts to break out of user/PID/mount/network/IPC namespaces |
| Capability abuse | 4 | Attempts to use CAP_SYS_ADMIN, CAP_NET_RAW, CAP_SYS_PTRACE, CAP_DAC_OVERRIDE |
| Seccomp bypasses | 3 | Attempts to bypass the BPF filter via architecture tricks, x32 ABI, indirect syscalls |
| Filesystem escapes | 3 | Attempts to access host filesystem via /proc, symlinks, or path traversal |
| Network escapes | 2 | Attempts to use raw sockets or access host network |
| Resource abuse | 2 | Fork bombs, memory exhaustion |

## When to Use Each Runtime

| Use Case | Recommended | Why |
|----------|-------------|-----|
| CI/CD with untrusted code | **ZViz** | Fast cold start (~8ms), strong isolation, low overhead |
| Multi-tenant SaaS | gVisor or ZViz | Both strong isolation; ZViz offers 2x density (less memory per container) |
| Legacy workloads requiring full syscall compat | Kata Containers | Full guest kernel, no syscall restrictions |
| AWS Lambda-style FaaS | Firecracker | Proven at hyperscale, hardware isolation boundary |
| Development/testing | runc | No overhead, full compatibility, no security needed |
| High-performance computing | **ZViz** | Near-zero overhead on allowed syscalls (native kernel execution) |
| Air-gapped / network-restricted | **ZViz** | Default-deny egress is a feature, not a limitation |
| Maximum security (hostile tenants) | gVisor + ZViz (hostile mode) | Belt-and-suspenders: ZViz inside a microVM or gVisor boundary |

## Detailed Technical Comparison

### Syscall Handling

| | runc | gVisor | ZViz |
|--|------|--------|------|
| `read()`/`write()` | Native | Emulated in Sentry | Native (ALLOW fast-path) |
| `openat()` | Native | Emulated + Gofer | Native or Brokered (path check) |
| `mount()` | Filtered by profile | Emulated (restricted) | DENY (immediate EPERM) |
| `ptrace()` | Allowed (default) | Blocked | DENY (immediate EPERM) |
| `socket()` | Native | Emulated (netstack) | Domain-filtered (AF_UNIX/INET/INET6 only) |
| `clone()`/`fork()` | Native | Emulated | ALLOW (PID namespace limits scope) |
| `bpf()` | Allowed (default) | Blocked | DENY (immediate EPERM) |

### Filesystem Isolation

| | runc | gVisor | ZViz |
|--|------|--------|------|
| Mechanism | Mount namespace + bind mounts | Gofer process (9P) | Landlock LSM + chdir fallback |
| Read-only rootfs | Optional | Default | Default (enforced by Landlock) |
| Host path access | Via volume mounts | Via Gofer (restricted) | Denied (Landlock rules) |
| /proc visibility | Configurable | Emulated (restricted) | Blocked (Seccomp + Landlock) |
| Performance | Native | ~50% overhead (9P) | Native (Landlock is kernel-internal) |

### Network Isolation

| | runc | gVisor | ZViz |
|--|------|--------|------|
| Default connectivity | Host network or bridge | Netstack (emulated) or host | Denied (explicit allowlist) |
| Raw sockets | Allowed | Blocked (netstack limitation) | Blocked (socket domain filter) |
| Socket types | All | TCP/UDP only | AF_UNIX, AF_INET, AF_INET6 only |
| Performance | Native | ~50% (netstack) | Native (kernel network stack) |
| Egress control | External (iptables) | Built-in (netstack) | Built-in (profile allowlist) |

## Limitations

### ZViz Limitations vs gVisor

1. **Kernel vulnerability exposure**: ZViz allows 90 syscalls to reach the host kernel directly. gVisor's Sentry means only ~70 reach the host. However, ZViz's 90 are well-audited safe syscalls (read, write, mmap, etc.) with minimal kernel attack surface.

2. **No syscall argument filtering on fast-path**: Allowed syscalls in ZViz go to the kernel without argument inspection. gVisor can inspect arguments for all syscalls. For ZViz, argument inspection happens only for brokered syscalls.

3. **Kernel version dependency**: ZViz requires Linux 5.13+ for Landlock, 5.6+ for seccomp user notification. gVisor only requires 4.4+.

### gVisor Limitations vs ZViz

1. **Performance**: gVisor emulates all syscalls, adding 50-100% overhead for I/O-heavy workloads.

2. **Compatibility**: Not all Linux syscalls are implemented in Sentry. Some workloads fail on gVisor that work on ZViz.

3. **Memory**: ~50MB per sandbox for the Sentry process, limiting container density.

4. **Cold start**: ~200ms vs ZViz's ~8ms, significant for serverless/FaaS.

5. **Network**: Netstack reimplements TCP/IP in userspace, adding latency and limiting to TCP/UDP only.

## See Also

- [Architecture Overview](index.md) - System architecture and enforcement layers
- [Performance](performance.md) - Detailed performance characteristics
- [Enforcement Model](enforcement-model.md) - Five-layer enforcement design
- [Threat Model](threat-model.md) - Security goals and assumptions
