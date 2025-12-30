# Policy Profiles

Profiles define the enforcement policy for a workload. Each profile compiles to concrete artifacts used by the runtime.

## Outputs per profile

- Seccomp BPF program (allow/deny/broker tiers).
- LSM policy (AppArmor/SELinux or Landlock rules).
- Network egress/ingress rules for the namespace.
- Broker rule tables (syscall- and argument-level allowlists).

## Profile selection

Profiles are intended to be explicit and deterministic. There are two deployment patterns:

- Separate binaries per profile (smallest surface area).
- A single binary with built-in profiles and a strict selection flag.

## Example: CI runner profile (high level)

- Allow: `read`, `write`, `futex`, `clock_gettime`, `epoll`, `mmap`.
- Deny: `bpf`, `kexec`, `perf_event_open`, raw sockets, module loading.
- Broker: `openat2`, select `ioctl`s, namespace-related syscalls.
- LSM: read-only rootfs, writable workspace subtree only.
- Network: allow outbound TCP/UDP to approved domains or CIDRs.

## Policy verification

Profiles should ship with:

- Rendered policy artifacts for inspection.
- A machine-readable manifest linking rules to policy intent.
- A small conformance test suite for each profile.
