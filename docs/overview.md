# Overview

ZigViz is a Zig-based isolation runtime design that aims to deliver gVisor-grade policy enforcement with near-native performance by combining kernel primitives with a small policy broker.

## Core thesis

gVisor’s advantage is syscall interposition via a userspace kernel. ZigViz reaches the same policy outcomes without emulating Linux by composing strict kernel mechanisms and brokering only the syscalls that need mediation.

## Differentiation

- No userspace kernel or runtime.
- Minimal broker surface area.
- Policy outcomes enforced by layered kernel controls.
- Profile-driven specialization for predictable behavior.

## Target use cases

- CI runners
- Untrusted plugin execution
- Multi-tenant developer platforms
- Serverless-style workloads

## Non-goals

- Full Linux emulation.
- Replacing a general-purpose container runtime.
- A blanket solution for hostile kernel-level attackers without a microVM boundary.
