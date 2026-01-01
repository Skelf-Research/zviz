# Profile Authoring Guide

This guide walks you through creating custom security profiles for your workloads.

## Getting Started

### Analyze Your Application

Before writing a profile, understand what your application needs:

```bash
# Run with audit mode to discover syscalls
sudo zigviz run --audit --profile minimal my-container . /bin/my-app

# Review audit log
jq '.[] | select(.decision == "denied")' /var/log/zigviz/audit.json
```

### Start with a Base Profile

Choose a base profile closest to your needs:

```yaml
name: my-app
version: "1.0"
extends: ci-runner  # Start from built-in profile
```

## Profile Structure

```yaml
name: my-app
version: "1.0"
description: "Custom profile for my application"

syscalls:
  allow: [...]
  deny: [...]
  broker: [...]

filesystem:
  readonly: [...]
  writable: [...]

network:
  egress:
    allow: [...]
  ingress:
    deny_all: true

resources:
  memory_max: "256M"
  pids_max: 50

capabilities:
  drop_all: true
  keep: [...]
```

## Step-by-Step Example

### 1. Define Syscalls

```yaml
syscalls:
  # Start minimal
  allow:
    - read
    - write
    - close
    - exit_group
    - brk
    - mmap
    - munmap

  # Block dangerous syscalls
  deny:
    - mount
    - bpf
    - init_module
    - ptrace

  # Mediate file/network access
  broker:
    - openat
    - socket
    - clone
```

### 2. Configure Filesystem

```yaml
filesystem:
  readonly:
    - /usr
    - /lib
    - /etc

  writable:
    - /tmp
    - /var/log/my-app

  hidden:
    - /etc/shadow
    - /root
```

### 3. Set Network Policy

```yaml
network:
  egress:
    allow:
      - 10.0.0.0/8      # Internal network
      - 169.254.169.254/32  # Cloud metadata
    deny:
      - 0.0.0.0/0       # Block internet

  sockets:
    allow: [tcp, udp]
    deny: [raw]
```

### 4. Set Resource Limits

```yaml
resources:
  memory_max: "256M"
  cpu_max: "50000 100000"  # 50% CPU
  pids_max: 50
```

### 5. Compile and Test

```bash
# Validate
zigviz compile --validate my-profile.yaml

# Test
sudo zigviz run --profile my-profile test . /bin/my-app
```

## Best Practices

1. **Start restrictive** — Begin with minimal permissions
2. **Use audit mode** — Discover required syscalls
3. **Test thoroughly** — Run your full test suite
4. **Document intent** — Explain why permissions are needed
5. **Version control** — Track profile changes

## Debugging

```bash
# Enable debug logging
sudo zigviz --log-level debug run --profile my-profile ...

# Check broker decisions
jq '.syscall' /var/log/zigviz/audit.json | sort | uniq -c
```

## See Also

- [Profile Schema Reference](../reference/profile-schema.md)
- [Built-in Profiles](builtin-profiles.md)
- [Troubleshooting](troubleshooting.md)
