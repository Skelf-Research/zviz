# Overview

ZigViz is a Zig-based isolation runtime design that aims to deliver gVisor-grade policy enforcement with near-native performance by combining kernel primitives with a small policy broker.

## Core thesis

gVisor’s advantage is syscall interposition via a userspace kernel. ZigViz reaches the same policy outcomes without emulating Linux by composing strict kernel mechanisms and brokering only the syscalls that need mediation.

## Differentiation

- No userspace kernel or runtime.
- Minimal broker surface area.
- Policy outcomes enforced by layered kernel controls.
- Profile-driven specialization for predictable behavior.

## Cost and performance posture

ZigViz targets near-native performance by mediating only security-relevant syscalls and using the host kernel networking stack. The expected result is materially higher pod density, lower per-pod memory overhead, and tighter tail latency compared to gVisor. See `docs/performance-cost.md` for quantified assumptions and targets.

## Target use cases

- CI runners
- Untrusted plugin execution
- Multi-tenant developer platforms
- Serverless-style workloads

## Operational modes

ZigViz supports two operational modes:

- **High-density mode** (default): Uses layered kernel controls (namespaces, seccomp, LSM, cgroups) plus the Zig broker to enforce policy. Delivers near-native performance for strong policy enforcement. The host kernel is trusted.

- **Hostile-tenant mode** (optional): Runs the same policy system inside an external microVM boundary (e.g., KVM) to reduce kernel attack surface. Trades density for stronger kernel isolation when tenants are not trusted at the kernel level.

See `docs/threat-model.md` for the security posture of each mode.

## Non-goals

- Full Linux emulation.
- Replacing a general-purpose container runtime.
- A blanket solution for hostile kernel-level attackers without a microVM boundary.

## Related documents

- `docs/threat-model.md` — Security goals, assumptions, and mode definitions
- `docs/enforcement-model.md` — Layered enforcement architecture
- `docs/performance-cost.md` — Performance targets and cost comparison
- `docs/deployment.md` — Kubernetes and containerd integration
