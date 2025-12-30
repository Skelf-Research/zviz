# Threat Model

This document defines the security goals and assumptions that guide ZigViz.

## Goals

- Prevent untrusted workloads from escaping their container boundary.
- Enforce strict syscall and object-access policies.
- Provide deterministic auditability of policy decisions.

## Assumptions

- The host Linux kernel is trusted in high-density mode.
- The host is configured with modern kernel features (namespaces, seccomp, cgroups v2, and an LSM).
- Container images are untrusted, but the runtime host is trusted.

## In-scope threats

- Attempts to access files, sockets, or processes outside the allowed policy scope.
- Use of dangerous syscalls or ioctls to expand privileges.
- Resource exhaustion attacks within declared limits.

## Out-of-scope threats (high-density mode)

- Active exploitation of kernel vulnerabilities to escape to the host.
- Attacks that require a full kernel surface reduction without a VM boundary.

## Modes

- High-density mode (default): uses layered kernel controls and a broker to enforce policy. This is intended for strong policy enforcement with near-native performance.
- Hostile-tenant mode (optional): runs the same policy system inside a microVM boundary (KVM) to reduce kernel attack surface. This mode trades density for stronger kernel isolation.

## Security posture statement

ZigViz aims to match gVisor-level policy outcomes for syscall and object access control. For kernel exploit resistance, ZigViz relies on an optional microVM boundary rather than a userspace kernel.
