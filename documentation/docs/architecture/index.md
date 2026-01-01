# Architecture Overview

ZigViz is a container isolation runtime that achieves gVisor-equivalent security outcomes through layered kernel enforcement rather than syscall emulation.

## Design Philosophy

### Core Thesis

gVisor's security comes from syscall interposition via a userspace kernel. ZigViz reaches the same policy outcomes without emulating Linux by:

1. **Composing kernel primitives** — Namespaces, seccomp, LSMs, cgroups
2. **Brokering only when necessary** — Syscalls needing argument inspection
3. **Profile-driven enforcement** — Compile-time policy generation

### Trade-offs

| Aspect | gVisor | ZigViz |
|--------|--------|--------|
| Kernel exposure | Minimal (sentry) | Controlled (filtered) |
| Syscall overhead | High (all syscalls) | Low (brokered only) |
| Compatibility | Limited | Native |
| Memory overhead | ~50MB | ~5MB |
| Network performance | Emulated stack | Native stack |

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
│  │              Layer B: Seccomp-BPF Filter                       │  │
│  │    ┌──────────────────┬────────────────┬──────────────────┐   │  │
│  │    │     ALLOW        │     DENY       │   USER_NOTIF     │   │  │
│  │    │   (fast path)    │  (blocked)     │   (mediated)     │   │  │
│  │    └──────────────────┴────────────────┴────────┬─────────┘   │  │
│  └─────────────────────────────────────────────────│─────────────┘  │
│                                                    │                 │
│  ┌───────────────────────────────────────────────│───────────────┐  │
│  │ Layer A: Containment                          │                │  │
│  │ • User namespace (UID/GID mapping)            │                │  │
│  │ • PID namespace (process isolation)           │                │  │
│  │ • Mount namespace (filesystem isolation)      │                │  │
│  │ • Network namespace (network isolation)       │                │  │
│  │ • Capability drop (privilege reduction)       │                │  │
│  └───────────────────────────────────────────────│───────────────┘  │
└──────────────────────────────────────────────────│──────────────────┘
                                                   │
                                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         ZigViz Broker                                │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    Syscall Mediators                           │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │
│  │  │ openat  │ │  ioctl  │ │ socket  │ │  clone  │ │ execve  │  │  │
│  │  │ Path    │ │ Command │ │ Domain  │ │  Flag   │ │  Path   │  │  │
│  │  │ check   │ │ filter  │ │ filter  │ │ validate│ │  check  │  │  │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                               │                                      │
│                               │ allow/deny/fd                        │
│                               ▼                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                      Host Kernel                               │  │
│  │  • Layer C: LSM (AppArmor/SELinux/Landlock)                   │  │
│  │  • Layer D: cgroups v2 (resource limits)                      │  │
│  │  • Layer E: nftables (network policy)                         │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Enforcement Layers

### Layer A: Containment

Sets up resource isolation using Linux namespaces:

- **User namespace** — Maps container UID 0 to unprivileged host UID
- **PID namespace** — Isolates process tree
- **Mount namespace** — Provides isolated filesystem view
- **Network namespace** — Isolated network stack
- **IPC namespace** — Isolated System V IPC

Also drops capabilities to minimum required set.

### Layer B: Syscall Gate

Seccomp-BPF filter that classifies syscalls:

| Action | Use Case | Performance |
|--------|----------|-------------|
| `ALLOW` | Safe syscalls (read, write) | Native speed |
| `DENY` | Dangerous syscalls (bpf, mount) | Immediate EPERM |
| `USER_NOTIF` | Need inspection (openat) | Broker overhead |

### Layer C: Object Policy (LSM)

Linux Security Modules provide object-level enforcement:

- **AppArmor** — Path-based MAC
- **SELinux** — Type enforcement
- **Landlock** — Unprivileged sandbox

### Layer D: Resource Control

cgroups v2 controllers limit resource consumption:

- **memory** — Memory + swap limits
- **cpu** — CPU quota/shares
- **pids** — Process count limits
- **io** — I/O bandwidth limits

### Layer E: Network Policy

Network isolation and filtering:

- **Network namespace** — Isolated network stack
- **veth pair** — Controlled connectivity
- **nftables** — Egress/ingress filtering

## Component Details

### The Broker

The broker is the central policy decision point for mediated syscalls.

```
┌─────────────────────────────────────────┐
│              ZigViz Broker               │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │         Notification Listener       │ │
│  │   • SECCOMP_RET_USER_NOTIF         │ │
│  │   • epoll-based event loop         │ │
│  │   • Max 256 concurrent syscalls    │ │
│  └────────────────────────────────────┘ │
│                    │                     │
│                    ▼                     │
│  ┌────────────────────────────────────┐ │
│  │          Syscall Dispatch           │ │
│  │   • Argument extraction            │ │
│  │   • Profile lookup                 │ │
│  │   • Mediator selection             │ │
│  └────────────────────────────────────┘ │
│                    │                     │
│                    ▼                     │
│  ┌────────────────────────────────────┐ │
│  │           Mediators                 │ │
│  │                                     │ │
│  │  openat:  Path traversal check     │ │
│  │  ioctl:   Command allowlist        │ │
│  │  socket:  Domain/type filter       │ │
│  │  clone:   Flag validation          │ │
│  │  execve:  Path check               │ │
│  │  prctl:   Operation filter         │ │
│  └────────────────────────────────────┘ │
│                    │                     │
│                    ▼                     │
│  ┌────────────────────────────────────┐ │
│  │          Response Handler           │ │
│  │   • SECCOMP_ADDFD for fds          │ │
│  │   • SECCOMP_USER_NOTIF_FLAG_CONTINUE│ │
│  │   • Error injection                 │ │
│  └────────────────────────────────────┘ │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │          Audit Logger               │ │
│  │   • Syscall, args, decision        │ │
│  │   • Latency tracking               │ │
│  │   • JSON structured output         │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

### Profile System

Profiles are compiled to enforcement artifacts:

```
┌─────────────────────────────────────────┐
│           Profile YAML                   │
│  • syscalls, filesystem, network        │
│  • resources, capabilities              │
└────────────────────┬────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────┐
│           Policy Compiler                │
│  • Schema validation                    │
│  • Rule generation                      │
│  • Optimization                         │
└────────────────────┬────────────────────┘
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
    ┌─────────┐ ┌─────────┐ ┌─────────┐
    │Seccomp  │ │AppArmor │ │nftables │
    │ BPF     │ │ Profile │ │ Rules   │
    └─────────┘ └─────────┘ └─────────┘
```

## Data Flow

### Container Startup

```
1. Parse OCI spec
2. Load security profile
3. Set up namespaces (Layer A)
4. Configure cgroups (Layer D)
5. Load LSM policy (Layer C)
6. Set up network (Layer E)
7. Install seccomp filter (Layer B)
8. Fork broker process
9. exec container entrypoint
```

### Syscall Mediation

```
1. Container makes syscall
2. Seccomp filter intercepts
3. If USER_NOTIF → notify broker
4. Broker receives notification
5. Extract syscall arguments
6. Evaluate against profile
7. Allow: perform on behalf / continue
8. Deny: inject error
9. Log decision
```

## Performance Characteristics

### Overhead Model

| Syscall Type | Overhead |
|--------------|----------|
| Allowed (fast path) | ~0 |
| Denied | ~0 |
| Brokered (allow) | ~50-100μs |
| Brokered (fd return) | ~100-200μs |

### Optimization Techniques

1. **Minimal brokered set** — Only syscalls needing inspection
2. **BPF fast path** — Common syscalls skip broker
3. **Connection pooling** — Reuse broker connections
4. **Batch processing** — Group multiple notifications

## See Also

- [Enforcement Model](enforcement-model.md)
- [Broker Design](broker-design.md)
- [Threat Model](threat-model.md)
- [Performance](performance.md)
