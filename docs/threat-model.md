# Threat Model

This document defines the security goals and assumptions that guide ZViz.

## Goals

- Prevent policy-level escape from the defined container boundary.
- Enforce strict syscall, object-access, and resource policies.
- Provide deterministic auditability of policy decisions.

## Assumptions

- The host Linux kernel is trusted in high-density mode.
- The host is configured with modern kernel features (namespaces, seccomp, cgroups v2, and an LSM).
- Container images are untrusted, but the runtime host is trusted.

## In-scope threats

- Attempts to access files, sockets, or processes outside the allowed policy scope.
- Use of dangerous syscalls or ioctls to expand privileges.
- Resource exhaustion attacks within declared limits.

## Definition: policy outcomes

Policy outcomes are the enforceable decisions around:

- which syscalls can be executed
- which objects can be accessed (files, sockets, processes)
- which network flows are allowed
- which resource limits apply

Policy outcomes do not include kernel exploit resistance in high-density mode.

Policy outcome equivalence assumes LSM availability and network policy enforcement. Without them, object-level and network controls are reduced and do not match gVisor-level policy outcomes.

## Out-of-scope threats (high-density mode)

- Active exploitation of kernel vulnerabilities to escape to the host.
- Attacks that require a full kernel surface reduction without a VM boundary.

## Modes

- High-density mode (default): uses layered kernel controls and a broker to enforce policy. This is intended for strong policy enforcement with near-native performance.
- Hostile-tenant mode (optional): runs the same policy system inside an external microVM boundary (KVM) to reduce kernel attack surface. This mode trades density for stronger kernel isolation.

## Security posture statement

ZViz aims to match gVisor-level policy outcomes for syscall, object, and network access control. For kernel exploit resistance, ZViz relies on an optional microVM boundary rather than a userspace kernel.

## Related documents

- `docs/enforcement-model.md` — How policy outcomes are enforced at each layer
- `docs/broker-design.md` — Broker architecture and TOCTOU resistance
- `docs/host-requirements.md` — Required host capabilities for policy equivalence
