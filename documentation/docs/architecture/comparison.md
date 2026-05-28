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
| Linux compatibility | Full | Limited (not all syscalls) | Near-full (130 syscalls native) | Full | Full |
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
                    ├── ALLOW (130 syscalls) → direct to kernel
                    ├── DENY  (24 syscalls) → immediate EPERM
                    └── BROKER (mediated)   → Zig broker → kernel

runc:
  Application → Kernel (all ~300+ syscalls available)
```

gVisor interposes on **every** syscall through its Sentry process, which emulates a Linux kernel in userspace. This provides strong isolation but at significant performance cost - every `read()`, `write()`, or `mmap()` pays the emulation overhead.

ZViz takes a different approach: safe syscalls (read, write, mmap, etc.) go directly to the host kernel at native speed. Only dangerous syscalls are blocked outright, and a small set requiring argument inspection are routed through the broker. The result is equivalent security policy enforcement with far less overhead.

## Measured Performance (Same Bundle, Same Binary)

Syscall latency measured by running identical benchmark inside both runtimes:

| Syscall | ZViz (ns) | gVisor (ns) | ZViz Advantage |
|---------|-----------|-------------|----------------|
| getpid | 297 | 1,209 | 4.1x faster |
| getuid | 202 | 1,125 | 5.6x faster |
| clock_gettime | 20 | 4,982 | **249x faster** |
| stat | 1,767 | 2,364 | 1.3x faster |
| open_close | 2,895 | 4,403 | 1.5x faster |
| read | 212 | 4,393 | **20.7x faster** |
| write | 211 | 1,169 | 5.5x faster |

*Measured using `demo.sh --perf` with same OCI bundle and statically-linked benchmark binary.*

**Why the difference?**

- ZViz allowed syscalls go directly to the kernel (native speed)
- gVisor emulates ALL syscalls through Sentry userspace kernel
- `clock_gettime` difference (249x) is extreme because gVisor can't use kernel vDSO

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

These attacks are tested live inside running containers (same binary, same bundle):

| Attack Vector | ZViz | gVisor | Mechanism |
|---------------|------|--------|-----------|
| `ptrace(PTRACE_TRACEME)` | BLOCKED | ALLOWED* | ZViz: seccomp deny; gVisor: emulated |
| `socket(AF_PACKET, SOCK_RAW)` | BLOCKED | BLOCKED | Both block raw sockets |
| `mount("proc", "/mnt", "proc")` | BLOCKED | BLOCKED | Both block mount syscall |
| `init_module(NULL, 0, "")` | BLOCKED | BLOCKED | Both block module loading |
| `bpf(BPF_PROG_LOAD, ...)` | BLOCKED | BLOCKED | Both block BPF |
| `kexec_load(0, 0, NULL, 0)` | BLOCKED | BLOCKED | Both block kexec |
| `open("/etc/shadow")` | BLOCKED | BLOCKED | Both block sensitive files |
| Write to host `/tmp` | BLOCKED | ALLOWED* | ZViz: Landlock; gVisor: sandboxed |

*gVisor "allows" these because they're emulated in Sentry, not executed on host kernel.

### Escape Test Comparison (19 tests, same bundle)

| Result | ZViz | gVisor |
|--------|------|--------|
| BLOCKED | **19/19 (100%)** | 11/19 (58%) |
| ALLOWED | 0/19 | 8/19 |

#### What gVisor allows that ZViz blocks:

| Test | ZViz | gVisor | Explanation |
|------|------|--------|-------------|
| unshare(NEWUSER) | BLOCKED | ALLOWED | gVisor emulates nested namespaces |
| unshare(NEWPID) | BLOCKED | ALLOWED | gVisor emulates nested namespaces |
| unshare(NEWNS) | BLOCKED | ALLOWED | gVisor emulates nested namespaces |
| capset() | BLOCKED | ALLOWED | Capabilities meaningless in Sentry |
| prctl(DUMPABLE) | BLOCKED | ALLOWED | Emulated, no host impact |
| ptrace() | BLOCKED | ALLOWED | Emulated ptrace within sandbox |
| mount() | BLOCKED | ALLOWED | Emulated via Gofer |
| /proc/1/root | BLOCKED | ALLOWED | Emulated /proc |
| AF_NETLINK | BLOCKED | ALLOWED | Emulated netlink |

#### Different Security Models

**ZViz**: Default-deny. Dangerous syscalls return EPERM immediately. The container cannot even attempt these operations.

**gVisor**: Emulation. Dangerous syscalls are intercepted and emulated safely in userspace. The container "succeeds" but the operation is sandboxed.

Both achieve strong isolation. ZViz is stricter (100% blocked), gVisor is more compatible (allows emulated operations).

#### What gVisor Emulation Actually Does

When gVisor "allows" a syscall, it returns success but operates on Sentry's virtual environment:

| Syscall | Container Sees | What Actually Happens |
|---------|---------------|----------------------|
| `ptrace()` | Returns 0 (success) | Traces processes in Sentry's emulated process table, not host |
| `mount()` | Returns 0 (success) | Mounts in Sentry's virtual filesystem via Gofer, not host |
| `unshare(NEWNS)` | Returns 0 (success) | Creates namespace in Sentry's emulated hierarchy, not host |
| `open(/proc/1/root)` | Returns fd | Opens Sentry's emulated /proc, not host /proc |

This is why Docker-in-Docker works in gVisor - the nested Docker thinks it's creating real namespaces and mounts, but they're all sandboxed within Sentry.

#### Why ZViz Blocks Instead

ZViz returns EPERM because:

1. **Defense-in-depth**: Exploit code fails at step 1, can't probe for vulnerabilities
2. **Smaller attack surface**: No emulation code paths that could have bugs
3. **Performance**: No userspace round-trip for blocked syscalls
4. **Simplicity**: Easier to audit "blocked" than "emulated correctly"

For workloads that don't need these syscalls (most web services, APIs, simple programs), blocking is strictly better.

### Escape Test Categories

| Category | Tests | Description |
|----------|-------|-------------|
| Namespace escapes | 4 | Attempts to break out of user/PID/mount namespaces |
| Capability abuse | 2 | Attempts to escalate capabilities |
| Seccomp bypasses | 6 | Attempts to execute blocked syscalls |
| Filesystem escapes | 4 | Attempts to access host filesystem |
| Network escapes | 2 | Attempts to use raw/netlink sockets |
| Resource abuse | 1 | Fork bombs |

## When to Use Each Runtime

### Use gVisor when you need compatibility

gVisor's emulation allows complex software to "just work":

| Workload | Why gVisor |
|----------|------------|
| **Docker-in-Docker** | Needs `unshare()`, `mount()` for nested containers |
| **Debugging with strace** | Needs `ptrace()` to trace processes |
| **Bazel / Nix builds** | Use namespaces for internal sandboxing |
| **Legacy apps probing capabilities** | May call blocked syscalls but handle errors gracefully |

```bash
# These work in gVisor (emulated), fail in ZViz (EPERM):
docker build -t myapp .     # Nested container build
strace ./myapp              # Process tracing
bazel build //my:target     # Sandboxed build actions
```

### Use ZViz when you need performance or strict security

| Workload | Why ZViz |
|----------|----------|
| **Untrusted code execution** | Blocks exploit chains at step 1 (EPERM) |
| **Multi-tenant with hostile users** | Smaller attack surface, no emulation code paths |
| **High-performance APIs/services** | 4-249x faster syscalls than gVisor |
| **Serverless / FaaS** | ~8ms cold start vs gVisor's ~200ms |
| **Simple workloads** | Web servers, APIs don't need ptrace/mount |

```bash
# Malicious code in ZViz:
unshare(CLONE_NEWUSER);  # EPERM - exploit fails immediately
ptrace(PTRACE_TRACEME);  # EPERM - no debugging/injection
mount("proc", ...);      # EPERM - no filesystem manipulation
```

### Decision Matrix

| Use Case | Recommended | Why |
|----------|-------------|-----|
| CI building Docker images | **gVisor** | Needs nested namespaces/mounts |
| CI running tests (no Docker) | **ZViz** | Faster, tests don't need ptrace/mount |
| Debugging/profiling | **gVisor** | Needs ptrace for strace/perf |
| Production web services | **ZViz** | Performance, simple syscall needs |
| Running student/user code | **ZViz** | Block exploit attempts outright |
| Bazel/Nix builds | **gVisor** | Internal sandboxing needs namespaces |
| Multi-tenant hostile users | **ZViz** | Strictest policy, smallest attack surface |
| Development/testing | **runc** | No overhead, full compatibility |
| Maximum isolation | **Kata/Firecracker** | Hardware VM boundary |

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

1. **Kernel vulnerability exposure**: ZViz allows 130 syscalls to reach the host kernel directly. gVisor's Sentry means only ~70 reach the host. However, ZViz's 90 are well-audited safe syscalls (read, write, mmap, etc.) with minimal kernel attack surface.

2. **No syscall argument filtering on fast-path**: Allowed syscalls in ZViz go to the kernel without argument inspection. gVisor can inspect arguments for all syscalls. For ZViz, argument inspection happens only for brokered syscalls.

3. **Kernel version dependency**: ZViz requires Linux 5.13+ for Landlock, 5.6+ for seccomp user notification. gVisor only requires 4.4+.

### gVisor Limitations vs ZViz

1. **Performance**: gVisor emulates all syscalls, adding 4-249x overhead (measured: `clock_gettime` 249x slower, `read` 20x slower).

2. **Compatibility**: Not all Linux syscalls are implemented in Sentry. Some workloads fail on gVisor that work on ZViz.

3. **Memory**: ~50MB per sandbox for the Sentry process, limiting container density.

4. **Cold start**: ~200ms vs ZViz's ~8ms, significant for serverless/FaaS.

5. **Network**: Netstack reimplements TCP/IP in userspace, adding latency and limiting to TCP/UDP only.

6. **Escape test behavior**: gVisor allows 8/19 escape attempts to "succeed" (via emulation). While safe due to Sentry sandboxing, container code can execute these paths. ZViz blocks all 19 outright with EPERM.

## See Also

- [Architecture Overview](index.md) - System architecture and enforcement layers
- [Performance](performance.md) - Detailed performance characteristics
- [Enforcement Model](enforcement-model.md) - Five-layer enforcement design
- [Threat Model](threat-model.md) - Security goals and assumptions
