# Architecture Overview

ZViz is a container isolation runtime that achieves gVisor-equivalent security outcomes through layered kernel enforcement rather than syscall emulation.

## Design Philosophy

### The Problem

You need to run code you can't trust: AI agents, CI/CD pipelines, third-party plugins, multi-tenant workloads. Traditional containers (runc) share the kernel attack surface with the host. gVisor solves this with a userspace kernel, but at significant performance cost.

### The Solution

ZViz reaches the same security outcomes without emulating Linux by:

1. **Composing kernel primitives** - Namespaces, seccomp, LSMs, cgroups
2. **Brokering only when necessary** - Syscalls needing argument inspection
3. **Profile-driven enforcement** - Workload-specific policies

### Trade-offs

| Aspect | gVisor | ZViz |
|--------|--------|------|
| Kernel exposure | Minimal (sentry) | Controlled (filtered) |
| Syscall overhead | High (all syscalls) | Low (brokered only) |
| Compatibility | Limited | Native for allowed syscalls |
| Memory overhead | ~50MB | ~2MB |
| Cold start | ~200ms | ~8ms |
| Network performance | Emulated stack | Native stack |
| Nested containers | Emulated (works) | Blocked (use gVisor) |

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Container                                   │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                       Application                              │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                               │                                      │
│                               │ syscall                              │
│                               ▼                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                   Seccomp-BPF Filter                           │  │
│  │    ┌──────────────────┬────────────────┬──────────────────┐   │  │
│  │    │     ALLOW        │     DENY       │   USER_NOTIF     │   │  │
│  │    │   (native)       │  (EPERM)       │   (mediated)     │   │  │
│  │    │   90 syscalls    │  22 syscalls   │   5 syscalls     │   │  │
│  │    └──────────────────┴────────────────┴────────┬─────────┘   │  │
│  └─────────────────────────────────────────────────│─────────────┘  │
│                                                    │                 │
│  ┌───────────────────────────────────────────────│───────────────┐  │
│  │ Containment Layer                             │                │  │
│  │ • User namespace (UID/GID mapping)            │                │  │
│  │ • PID namespace (process isolation)           │                │  │
│  │ • Mount namespace (filesystem isolation)      │                │  │
│  │ • Network namespace (network isolation)       │                │  │
│  │ • All 41 capabilities dropped                 │                │  │
│  └───────────────────────────────────────────────│───────────────┘  │
└──────────────────────────────────────────────────│──────────────────┘
                                                   │
                                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ZViz Broker                                  │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    Syscall Mediators                           │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │
│  │  │ openat  │ │  ioctl  │ │ socket  │ │  clone  │ │ execve  │  │  │
│  │  │  Path   │ │ Command │ │ Domain  │ │  Flag   │ │  Path   │  │  │
│  │  │  check  │ │ filter  │ │ filter  │ │ validate│ │  check  │  │  │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                               │                                      │
│                               │ allow/deny/fd                        │
│                               ▼                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                      Host Kernel                               │  │
│  │  • Landlock LSM (filesystem access control)                   │  │
│  │  • cgroups v2 (resource limits)                               │  │
│  │  • nftables (network policy)                                  │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Enforcement Layers

ZViz applies five enforcement layers in order:

### Layer 1: Namespaces

Isolation using Linux namespaces:

- **User namespace** - Maps container UID 0 to unprivileged host UID
- **PID namespace** - Isolates process tree
- **Mount namespace** - Isolated filesystem view
- **Network namespace** - Isolated network stack
- **IPC namespace** - Isolated System V IPC
- **UTS namespace** - Isolated hostname

### Layer 2: Capabilities

All 41 Linux capabilities are dropped via `prctl(PR_CAPBSET_DROP)`. Even if the container runs as "root", it has no privileged capabilities.

### Layer 3: Landlock LSM

Filesystem access control:

- Read-only rootfs
- Writable only: `/tmp`, `/work`
- No access to host paths

### Layer 4: Seccomp-BPF

124-instruction BPF filter classifying syscalls:

| Action | Use Case | Performance |
|--------|----------|-------------|
| `ALLOW` | Safe syscalls (read, write, mmap) | Native kernel speed |
| `DENY` | Dangerous syscalls (ptrace, mount, bpf) | Immediate EPERM |
| `USER_NOTIF` | Need inspection (openat, socket, execve) | Broker overhead |

### Layer 5: cgroups v2

Resource limits via cgroups v2 controllers:

- **memory** - Memory + swap limits
- **cpu** - CPU quota/shares
- **pids** - Process count limits
- **io** - I/O bandwidth limits

## The Broker

The broker is the central policy decision point for mediated syscalls:

```
┌─────────────────────────────────────────┐
│              ZViz Broker                │
│                                         │
│  ┌────────────────────────────────────┐ │
│  │         Notification Listener      │ │
│  │   • SECCOMP_RET_USER_NOTIF        │ │
│  │   • epoll-based event loop        │ │
│  └────────────────────────────────────┘ │
│                    │                    │
│                    ▼                    │
│  ┌────────────────────────────────────┐ │
│  │           Mediators                │ │
│  │                                    │ │
│  │  openat:  Path traversal check    │ │
│  │  ioctl:   Command allowlist       │ │
│  │  socket:  Domain/type filter      │ │
│  │  clone:   Flag validation         │ │
│  │  execve:  Path check              │ │
│  │  prctl:   Operation filter        │ │
│  └────────────────────────────────────┘ │
│                    │                    │
│                    ▼                    │
│  ┌────────────────────────────────────┐ │
│  │          Response Handler          │ │
│  │   • SECCOMP_ADDFD for fds         │ │
│  │   • Error injection               │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## Profile System

Profiles are workload-specific security policies:

| Profile | Description |
|---------|-------------|
| `ci-runner` | CI/CD workloads (default) |
| `web-server` | HTTP servers, APIs |
| `batch-job` | Data processing (no network) |
| `hostile-tenant` | Maximum security |
| `development` | Debugging (allows ptrace) |

Profiles compile to enforcement artifacts:

```
Profile YAML → Policy Compiler → Seccomp BPF + Landlock rules + cgroup limits
```

## Performance Characteristics

### Overhead Model

| Syscall Type | Overhead |
|--------------|----------|
| Allowed (fast path) | ~0 |
| Denied | ~0 |
| Brokered (allow) | ~50-100μs |
| Brokered (fd return) | ~100-200μs |

### Why ZViz is Fast

1. **Minimal brokered set** - Only 5 syscalls go through the broker
2. **BPF fast path** - 90 common syscalls execute at native speed
3. **No emulation** - Allowed syscalls hit the kernel directly

## When to Use gVisor Instead

ZViz blocks dangerous syscalls with EPERM. gVisor emulates them safely. For some workloads, emulation is required:

- **Docker-in-Docker** - Needs `mount`, `unshare`
- **Bazel / Nix builds** - Internal sandboxing creates namespaces
- **strace / debuggers** - Needs `ptrace`

For these workloads, use gVisor. For everything else, ZViz is faster and stricter.

## See Also

- [Enforcement Model](enforcement-model.md)
- [Broker Design](broker-design.md)
- [Threat Model](threat-model.md)
- [Performance](performance.md)
- [Comparison with gVisor](comparison.md)
