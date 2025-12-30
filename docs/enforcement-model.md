# Enforcement Model

ZigViz enforces policy by composing multiple kernel mechanisms with a minimal Zig broker. The objective is deny-by-default at every layer. Policy outcomes are defined in `docs/threat-model.md`.

## Layer A: Containment

- Namespaces: user, PID, mount, network, IPC.
- Capabilities: drop aggressively; deny privileged operations by default.
- Filesystem baseline: read-only rootfs, no device nodes, no module loading.

## Layer B: Syscall gate (seccomp-bpf)

Each profile compiles to a seccomp policy with three syscall tiers:

1. Fast allow: safe, high-frequency syscalls (for example, `read`, `write`, `futex`, `clock_gettime`).
2. Hard deny: never permitted (`bpf`, `kexec`, `perf_event_open`, module loading, raw sockets).
3. Brokered: routed to the Zig broker via `SECCOMP_RET_USER_NOTIF` (`openat`, `openat2`, sensitive `ioctl`s, and other policy-relevant syscalls).

## Layer C: Object policy (LSM)

Seccomp answers “can you call this syscall.” LSMs answer “can you touch this object.”

- Prefer AppArmor or SELinux where available.
- Use Landlock for unprivileged, composable filesystem restrictions when feasible.
- LSMs are required for gVisor-level object policy outcomes; without them, object controls fall back to mount namespace and brokered syscalls only.

## Layer D: Resource control (cgroups v2)

- CPU, memory, PIDs, and I/O limits.
- Consistent OOM behavior.
- Prevents resource-based policy bypass.

## Layer E: Network policy

- Namespace-level firewalling (iptables/nftables or eBPF).
- Egress allowlists aligned to profile intent (CIDR-based in-kernel enforcement).
- Domain allowlists require a DNS-aware policy layer or controlled egress proxy.
- Deny raw sockets and unsafe socket options by default.

## Outcome equivalence

By combining these layers, ZigViz can reach the same policy outcomes that gVisor enforces through userspace syscall interposition, without emulating Linux.
