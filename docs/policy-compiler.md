# Policy Compiler

This document defines the policy compiler that turns a profile definition into concrete, auditable enforcement artifacts.

## Purpose

- Produce deterministic policy outputs from a single profile input.
- Minimize runtime decision-making and keep enforcement explicit.
- Emit a manifest that explains how each rule maps to policy intent.

## Inputs

- A profile definition with syscall tiers, object access rules, and network intent.
- Optional host capability flags (for example, LSM availability).

## Outputs

- Seccomp BPF program (allow/deny/broker tiers).
- LSM policy (AppArmor/SELinux or Landlock rules).
- Network policy rules (CIDR allowlists and firewall config).
- Broker rule tables (syscall numbers, argument shapes, ioctl allowlists).
- A machine-readable manifest that links rules to intent.

## Determinism and auditability

- Build inputs are hashed and recorded in the manifest.
- Output artifacts are reproducible for the same inputs.
- Profiles are immutable once published for a release line.

## Validation

- Reject profiles that request disallowed syscalls or unsafe capabilities.
- Fail builds when required enforcement layers are unavailable.
- Emit warnings when fallbacks reduce policy scope.

## Packaging

- Default: compile one binary per profile with embedded artifacts.
- Optional: a multi-profile binary that embeds multiple profiles and requires a strict selection flag.
