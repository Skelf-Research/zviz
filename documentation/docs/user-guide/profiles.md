# Security Profiles

Profiles are the core configuration mechanism in ZViz. They define what a container can and cannot do, and how resources are limited.

## What is a Profile?

A profile is a YAML file that specifies:

- **Syscalls**: Which system calls are allowed, denied, or brokered
- **Filesystem**: What paths can be read/written
- **Network**: What network destinations are reachable
- **Resources**: CPU, memory, and process limits
- **Capabilities**: Which Linux capabilities are retained

## Profile Structure

```yaml
name: my-profile
version: 1.0
description: "Description of this profile's purpose"

# Syscall control
syscalls:
  allow:
    - read
    - write
    - exit_group
  deny:
    - mount
    - bpf
    - init_module
  broker:
    - openat
    - socket
    - clone

# Filesystem access
filesystem:
  readonly:
    - /usr
    - /lib
    - /etc
  writable:
    - /tmp
    - /work
  hidden:
    - /etc/shadow
    - /root

# Network policy
network:
  egress:
    allow:
      - 10.0.0.0/8
      - 172.16.0.0/12
    deny:
      - 0.0.0.0/0
  ingress:
    deny_all: true

# Resource limits
resources:
  memory_max: "512M"
  cpu_max: "100000 100000"  # quota period (100%)
  pids_max: 100
  io_max:
    - device: "8:0"
      rbps: 10485760  # 10MB/s

# Linux capabilities
capabilities:
  keep:
    - CAP_NET_BIND_SERVICE
  drop_all: true
```

## Profile Categories

### Syscalls

Syscalls are divided into three categories:

| Category | Action | Use Case |
|----------|--------|----------|
| `allow` | Execute directly | Safe syscalls (read, write, exit) |
| `deny` | Return EPERM | Dangerous syscalls (mount, bpf) |
| `broker` | Mediate via broker | Syscalls needing arg inspection |

```yaml
syscalls:
  # Fast path - no broker overhead
  allow:
    - read
    - write
    - close
    - mmap
    - munmap
    - brk

  # Blocked immediately
  deny:
    - mount
    - umount2
    - bpf
    - init_module
    - delete_module
    - reboot
    - kexec_load

  # Inspected by broker
  broker:
    - openat      # Path validation
    - socket      # Domain/type filtering
    - clone       # Flag validation
    - ioctl       # Command filtering
    - prctl       # Operation filtering
```

### Filesystem

Control file and directory access:

```yaml
filesystem:
  # Read-only paths
  readonly:
    - /usr
    - /lib
    - /lib64
    - /etc
    - /bin
    - /sbin

  # Writable paths
  writable:
    - /tmp
    - /var/tmp
    - /work

  # Hidden from container
  hidden:
    - /etc/shadow
    - /etc/gshadow
    - /root/.ssh

  # Executable paths (for execve)
  executable:
    - /usr/bin
    - /bin
    - /usr/local/bin
```

### Network

Define network access rules:

```yaml
network:
  # Outbound connections
  egress:
    allow:
      - 10.0.0.0/8       # Private networks
      - 172.16.0.0/12
      - 192.168.0.0/16
      - 169.254.169.254/32  # Cloud metadata
    deny:
      - 0.0.0.0/0        # Block public internet

  # Inbound connections
  ingress:
    deny_all: true       # No incoming connections

  # DNS proxy (optional)
  dns_proxy:
    enabled: true
    upstream: "10.0.0.53:53"

  # Socket types allowed
  sockets:
    allow:
      - tcp
      - udp
      - unix
    deny:
      - raw
      - netlink
```

### Resources

Set resource limits via cgroups v2:

```yaml
resources:
  # Memory limit (bytes or human-readable)
  memory_max: "256M"

  # Memory + swap limit
  memory_swap_max: "512M"

  # CPU quota: "quota period" in microseconds
  # 50000 100000 = 50% of one CPU
  cpu_max: "50000 100000"

  # Maximum number of processes
  pids_max: 50

  # I/O limits per device
  io_max:
    - device: "8:0"
      rbps: 10485760   # Read bytes/sec
      wbps: 5242880    # Write bytes/sec
      riops: 1000      # Read IOPS
      wiops: 500       # Write IOPS
```

### Capabilities

Control Linux capabilities:

```yaml
capabilities:
  # Drop all capabilities first
  drop_all: true

  # Then add back specific ones
  keep:
    - CAP_NET_BIND_SERVICE  # Bind to ports < 1024
    - CAP_DAC_OVERRIDE      # Bypass file permissions
```

Available capabilities:

| Capability | Purpose |
|------------|---------|
| `CAP_NET_BIND_SERVICE` | Bind to privileged ports |
| `CAP_SYS_PTRACE` | Use ptrace |
| `CAP_SETUID` | Change UID |
| `CAP_SETGID` | Change GID |
| `CAP_CHOWN` | Change file ownership |
| `CAP_DAC_OVERRIDE` | Bypass file permissions |

!!! warning "Security Risk"
    Adding capabilities increases attack surface. Only add what's absolutely necessary.

## Profile Inheritance

Profiles can extend other profiles:

```yaml
name: my-extended-profile
extends: ci-runner

# Add additional permissions
syscalls:
  allow:
    - ptrace  # For debugging

filesystem:
  writable:
    - /custom/path
```

## Profile Compilation

Profiles are compiled into enforcement artifacts:

```bash
# Compile a profile
zviz compile my-profile.yaml

# Output files
my-profile.bpf       # Seccomp BPF program
my-profile.apparmor  # AppArmor profile
my-profile.nft       # nftables rules
my-profile.broker    # Broker rule table
my-profile.manifest  # Compilation manifest
```

## Validation

Validate profiles before use:

```bash
# Check syntax and semantics
zviz compile --validate my-profile.yaml

# Check against host capabilities
zviz compile --check-host my-profile.yaml
```

## Best Practices

### 1. Principle of Least Privilege

Start with minimal permissions and add only what's needed:

```yaml
# Bad - too permissive
syscalls:
  deny: [mount, bpf]  # Implicit allow for everything else

# Good - explicit allowlist
syscalls:
  allow: [read, write, openat, close, exit_group]
  deny: ["*"]
```

### 2. Use Wildcards Carefully

```yaml
# Dangerous - blocks all syscalls
syscalls:
  deny: ["*"]

# Better - explicit lists
syscalls:
  deny:
    - mount
    - bpf
    - init_module
```

### 3. Test in Audit Mode

```bash
# Run with audit mode to discover required syscalls
sudo zviz run --audit --profile my-profile container . /bin/my-app

# Review audit log
jq '.[] | select(.decision == "denied")' /var/log/zviz/audit.json
```

### 4. Document Your Profile

```yaml
name: my-profile
description: |
  Profile for Node.js web applications.
  Allows network access to internal services only.
  Requires /work mount for application code.

# ... rest of profile
```

## See Also

- [Profile Authoring Guide](profile-authoring.md)
- [Built-in Profiles](builtin-profiles.md)
- [Profile Schema Reference](../reference/profile-schema.md)
