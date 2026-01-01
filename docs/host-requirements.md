# Host Requirements

This document defines the minimum host capabilities required to achieve gVisor-level policy outcomes.

## Required capabilities (high-density mode)

- Linux namespaces: user, PID, mount, network, IPC.
- seccomp-bpf with `SECCOMP_RET_USER_NOTIF` support.
- cgroups v2 for CPU, memory, PIDs, and I/O control.
- An LSM: AppArmor or SELinux; Landlock is acceptable where available.
- Network policy enforcement: iptables/nftables or eBPF.

## Optional capabilities

- KVM or an external microVM runtime for hostile-tenant mode.
- A DNS-aware egress proxy to enforce domain allowlists (CIDR allowlists are enforced in-kernel).

## Fallback behavior

- If LSM is unavailable, object-level policy outcomes are reduced and do not match gVisor-level controls.
- If seccomp user notification is unavailable, brokered syscalls must be denied or removed from the profile.
- If network policy enforcement is unavailable, only syscall-level network restrictions apply.

## Profile gating

Profiles declare required host capabilities. The policy compiler fails closed if requirements are not met and can emit a compatibility report for degraded environments.

## Related documents

- `docs/enforcement-model.md` — How each host capability maps to an enforcement layer
- `docs/profile-schema.md` — How to declare requirements in profiles
- `docs/policy-compiler.md` — Compiler behavior when requirements are not met
