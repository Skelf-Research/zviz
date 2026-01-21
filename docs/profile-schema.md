# Profile Schema

This document defines the logical schema for ZViz profiles. Profiles are the input to the policy compiler. For a complete, concrete example, see `docs/profile-ci-runner.md`.

## Schema Reference

### Top-level fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Unique profile identifier |
| `version` | string | yes | Profile version (semver recommended) |
| `mode` | enum | yes | `high-density` or `hostile-tenant` |
| `description` | string | no | Human-readable description |

### Requirements block

Declares host capabilities the profile requires. The policy compiler fails closed if requirements are not met.

```yaml
requirements:
  lsm: required | optional | none
  seccomp_notify: required | optional
  network_policy: required | optional
```

### Syscalls block

Defines syscall policy in three tiers:

```yaml
syscalls:
  allow:    # Fast-path allowed syscalls (no mediation)
    - read
    - write
    - ...
  deny:     # Hard-denied syscalls (always blocked)
    - bpf
    - kexec_load
    - ...
  broker:   # Routed to Zig broker via SECCOMP_RET_USER_NOTIF
    - openat
    - openat2
    - ioctl
    - socket
    - socketpair
    - clone
    - clone3
    - execve
    - execveat
    - prctl
```

**Brokered syscall notes:**
- `openat` and `openat2`: File access mediation with TOCTOU resistance
- `ioctl`: Filtered by subsystem-specific allowlists
- `socket` and `socketpair`: Domain/type restrictions (e.g., `AF_INET`, `AF_UNIX`)
- `clone` and `clone3`: Constrained to thread-like flags; new namespaces denied
- `execve` and `execveat`: Binary allowlist enforcement via LSM
- `prctl`: Capability and security flag mediation

### Ioctl block

Defines per-subsystem ioctl command allowlists:

```yaml
ioctl:
  allowlists:
    - subsystem: tty
      commands: [TIOCGWINSZ, TIOCSPGRP, TIOCGPGRP]
    - subsystem: fs
      commands: [FIONREAD, FIONBIO]
```

### Filesystem block

```yaml
filesystem:
  rootfs: readonly | readwrite
  writable:
    - /work
    - /tmp
  tmpfs:
    - /tmp
```

### LSM block

Specifies Linux Security Module configuration. ZViz supports AppArmor, SELinux, or Landlock:

```yaml
# AppArmor example
lsm:
  type: apparmor
  profile: zviz-ci

# SELinux example
lsm:
  type: selinux
  context: system_u:system_r:zviz_t:s0

# Landlock example (unprivileged, composable)
lsm:
  type: landlock
  ruleset: zviz-ci
```

The compiler generates appropriate rules for the configured LSM type.

### Network block

```yaml
network:
  mode: allow-cidr | deny-all | allow-all
  allow_cidrs:
    - 10.0.0.0/8
    - 172.16.0.0/12
  allow_domains: []  # Requires DNS-aware egress proxy
```

### Resources block

Maps to cgroups v2 controllers:

```yaml
resources:
  cpu_max: "2"        # CPU quota
  memory_max: "4G"    # Memory limit
  pids_max: 512       # Process limit
```

### Broker block

Broker runtime configuration:

```yaml
broker:
  max_inflight: 256   # Max concurrent brokered syscalls
  timeout_ms: 200     # Per-syscall timeout
```

### Audit block

```yaml
audit:
  level: none | minimal | full
```

## Validation rules

- `allow_domains` requires a DNS-aware egress proxy and is not enforced by CIDR rules alone.
- `clone` and `clone3` must be constrained to thread-like flags; new namespaces must be denied.
- `execve` and `execveat` can be brokered when strict binary allowlists are required.
- `requirements` let the compiler fail closed when host capabilities are missing.
- Profiles that request disallowed syscalls or unsafe capabilities are rejected.

## Related documents

- `docs/profile-ci-runner.md` — Concrete CI runner profile example
- `docs/policy-compiler.md` — How profiles are compiled to enforcement artifacts
- `docs/host-requirements.md` — Host capability requirements
