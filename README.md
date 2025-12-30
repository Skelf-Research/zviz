# ZigViz

ZigViz is a Zig-based isolation runtime design that aims to deliver gVisor-grade policy enforcement with near-native performance. The core idea is simple: rely on Linux kernel primitives for containment and resource control, and add a tiny Zig policy kernel that mediates only the syscalls that matter.

This repository contains the design documents that define the threat model, enforcement model, and broker contract. It is a design-first project; implementation details will follow the architecture described here.

## What ZigViz is

- A container sandbox runtime that targets containerd/Kubernetes integration.
- A layered policy enforcement system built from namespaces, seccomp, LSMs, and cgroups.
- A small Zig broker that handles security-relevant syscalls via seccomp user notification.
- A profile-driven system that produces deterministic, auditable policies.
- Default packaging is per-profile binaries; a multi-profile binary is optional.

## What ZigViz is not

- A userspace Linux kernel.
- A full gVisor clone.
- A microVM replacement; it can integrate with external microVM runtimes in hostile-tenant mode.

## Design goals

- Match gVisor-level policy outcomes (syscall, object, network, resource) without emulating Linux.
- Keep the trusted computing base small and auditable.
- Preserve Linux compatibility for common workloads.
- Provide deterministic policy outcomes and audit trails.

## Architecture in one paragraph

ZigViz uses Linux namespaces and capabilities for containment, seccomp-bpf for syscall gating, LSMs (AppArmor/SELinux or Landlock) for object-level access control, network policy (iptables/nftables or eBPF), and cgroups v2 for resource isolation. A small Zig broker receives seccomp user-notification events for a tight set of “brokered” syscalls (for example, `openat2` and specific `ioctl`s), applies policy, and returns results safely (preferably via file descriptors, not paths). This is how ZigViz achieves gVisor-grade enforcement outcomes without a userspace kernel.

## Modes

- High-density mode (default): policy enforcement with kernel primitives + broker.
- Hostile-tenant mode (optional): same policy system inside a microVM boundary for kernel attack-surface reduction.

## Documents

- docs/overview.md
- docs/threat-model.md
- docs/enforcement-model.md
- docs/broker-design.md
- docs/policy-profiles.md
- docs/policy-compiler.md
- docs/deployment.md
- docs/performance-cost.md
- docs/benchmark-methodology.md

## Proof of equivalence strategy

ZigViz will earn trust by shipping concrete artifacts:

- Generated policy outputs (seccomp BPF, LSM rules, network filters).
- Deterministic broker decision logs (“why was this denied”).
- Differential testing against gVisor for the same workload.
- A curated escape-class test suite.
- Fuzzing on broker boundaries and syscall arguments.

## Status

Design in progress. Contributions and critique are welcome.
