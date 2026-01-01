# Profile Schema Reference

Complete reference for the ZigViz security profile schema.

## Schema Version

```yaml
schema_version: "1.0"
```

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Profile identifier |
| `version` | string | Yes | Profile version |
| `description` | string | No | Human-readable description |
| `extends` | string | No | Base profile to inherit from |
| `syscalls` | object | No | Syscall control rules |
| `filesystem` | object | No | Filesystem access rules |
| `network` | object | No | Network access rules |
| `resources` | object | No | Resource limits |
| `capabilities` | object | No | Linux capabilities |

## Syscalls

```yaml
syscalls:
  # Syscalls allowed without mediation (fast path)
  allow:
    - read
    - write
    - close
    - exit_group

  # Syscalls blocked immediately
  deny:
    - mount
    - umount2
    - bpf
    - init_module

  # Syscalls mediated by broker
  broker:
    - openat
    - socket
    - clone
    - ioctl
    - execve
```

### Syscall Categories

For convenience, you can use categories:

```yaml
syscalls:
  allow:
    - "@basic-io"      # read, write, close, etc.
    - "@memory"        # mmap, munmap, brk, etc.
    - "@process"       # fork, exit, wait, etc.
  deny:
    - "@dangerous"     # mount, bpf, ptrace, etc.
```

Available categories:

| Category | Syscalls |
|----------|----------|
| `@basic-io` | read, write, close, dup, dup2, dup3, pipe, pipe2 |
| `@memory` | mmap, munmap, mprotect, brk, mremap |
| `@process` | fork, vfork, exit, exit_group, wait4, waitid |
| `@network` | socket, bind, listen, accept, connect, send, recv |
| `@signal` | rt_sigaction, rt_sigprocmask, kill, tgkill |
| `@filesystem` | openat, stat, fstat, lstat, access, readlink |
| `@dangerous` | mount, ptrace, bpf, init_module, kexec_load |

## Filesystem

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

  # Hidden paths (inaccessible)
  hidden:
    - /etc/shadow
    - /etc/gshadow
    - /root

  # Executable paths (for execve)
  executable:
    - /usr/bin
    - /bin
    - /usr/local/bin

  # Glob patterns
  patterns:
    allow_read:
      - "*.so"
      - "*.so.*"
    deny_write:
      - "*.conf"
      - "*.cfg"
```

### Path Patterns

Paths support glob patterns:

| Pattern | Meaning |
|---------|---------|
| `/path` | Exact match |
| `/path/*` | Direct children |
| `/path/**` | All descendants |
| `*.ext` | Files with extension |

## Network

```yaml
network:
  # Outbound connections
  egress:
    allow:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
    deny:
      - 0.0.0.0/0

  # Inbound connections
  ingress:
    deny_all: true
    # Or specific rules:
    # allow:
    #   - 10.0.0.0/8

  # DNS configuration
  dns:
    allow: true
    proxy:
      enabled: true
      upstream: "10.0.0.53:53"

  # Socket types
  sockets:
    allow:
      - tcp
      - udp
      - unix
    deny:
      - raw
      - netlink
      - packet

  # Port restrictions
  ports:
    allow_bind:
      - 8080
      - 8443
    deny_connect:
      - 22
      - 23
```

## Resources

```yaml
resources:
  # Memory limit (bytes or human-readable)
  memory_max: "512M"

  # Memory + swap limit
  memory_swap_max: "1G"

  # High memory watermark
  memory_high: "400M"

  # CPU quota: "quota period" in microseconds
  cpu_max: "100000 100000"  # 100% of one CPU

  # CPU shares (relative weight)
  cpu_weight: 100

  # Maximum processes/threads
  pids_max: 100

  # I/O limits
  io_max:
    - device: "8:0"
      rbps: 10485760    # Read bytes/sec
      wbps: 5242880     # Write bytes/sec
      riops: 1000       # Read IOPS
      wiops: 500        # Write IOPS
```

### Memory Units

| Unit | Bytes |
|------|-------|
| `K` | 1024 |
| `M` | 1024² |
| `G` | 1024³ |
| `T` | 1024⁴ |

## Capabilities

```yaml
capabilities:
  # Drop all capabilities first
  drop_all: true

  # Keep specific capabilities
  keep:
    - CAP_NET_BIND_SERVICE
    - CAP_DAC_OVERRIDE

  # Ambient capabilities
  ambient:
    - CAP_NET_BIND_SERVICE

  # Bounding set
  bounding:
    drop:
      - CAP_SYS_ADMIN
      - CAP_SYS_PTRACE
```

### Capability List

| Capability | Description |
|------------|-------------|
| `CAP_CHOWN` | Change file ownership |
| `CAP_DAC_OVERRIDE` | Bypass file permissions |
| `CAP_DAC_READ_SEARCH` | Bypass read/search permissions |
| `CAP_FOWNER` | Bypass permission checks for file owner |
| `CAP_FSETID` | Don't clear setuid/setgid bits |
| `CAP_KILL` | Send signals to any process |
| `CAP_SETGID` | Change GID |
| `CAP_SETUID` | Change UID |
| `CAP_SETPCAP` | Modify process capabilities |
| `CAP_NET_BIND_SERVICE` | Bind to ports < 1024 |
| `CAP_NET_RAW` | Use raw sockets |
| `CAP_SYS_CHROOT` | Use chroot |
| `CAP_SYS_PTRACE` | Use ptrace |
| `CAP_SYS_ADMIN` | Many admin operations |

## Complete Example

```yaml
name: web-server
version: "1.0"
description: "Profile for web server applications"

extends: minimal

syscalls:
  allow:
    - "@basic-io"
    - "@network"
    - "@memory"
    - epoll_create1
    - epoll_ctl
    - epoll_wait
  deny:
    - "@dangerous"
  broker:
    - openat
    - socket

filesystem:
  readonly:
    - /usr
    - /lib
    - /etc
  writable:
    - /tmp
    - /var/log
  executable:
    - /usr/bin
    - /bin

network:
  egress:
    allow:
      - 10.0.0.0/8
    deny:
      - 0.0.0.0/0
  ingress:
    deny_all: false
  sockets:
    allow: [tcp, udp]
    deny: [raw]
  ports:
    allow_bind: [80, 443, 8080]

resources:
  memory_max: "256M"
  cpu_max: "50000 100000"
  pids_max: 50

capabilities:
  drop_all: true
  keep:
    - CAP_NET_BIND_SERVICE
```

## Validation

```bash
# Validate profile syntax
zigviz compile --validate my-profile.yaml

# Check host compatibility
zigviz compile --check-host my-profile.yaml

# Show compiled rules
zigviz compile --show my-profile.yaml
```

## See Also

- [Profiles Guide](../user-guide/profiles.md)
- [Profile Authoring](../user-guide/profile-authoring.md)
- [Built-in Profiles](../user-guide/builtin-profiles.md)
