# User Guide

This guide covers everything you need to know to use ZigViz effectively.

## Overview

ZigViz uses **security profiles** to define what containers can and cannot do. Profiles are declarative YAML files that get compiled into enforcement rules for the kernel.

## Key Concepts

### Profiles

A profile defines the security policy for a container:

```yaml
name: my-profile
version: 1.0

syscalls:
  allow:
    - read
    - write
    - exit
  deny:
    - mount
    - bpf

filesystem:
  readonly: ["/usr", "/lib", "/etc"]
  writable: ["/tmp", "/work"]

network:
  egress:
    allow: ["10.0.0.0/8"]
    deny: ["0.0.0.0/0"]

resources:
  memory_max: "256M"
  pids_max: 100
```

### Enforcement Layers

ZigViz applies five enforcement layers:

| Layer | Mechanism | What it Controls |
|-------|-----------|------------------|
| A | Namespaces + Capabilities | Resource visibility |
| B | Seccomp-BPF + Broker | Syscall access |
| C | LSM (AppArmor/SELinux/Landlock) | File/object access |
| D | cgroups v2 | Resource limits |
| E | Network namespace + nftables | Network access |

### The Broker

For syscalls that need argument inspection (like `openat`), ZigViz uses a broker process that:

1. Receives the syscall via `SECCOMP_RET_USER_NOTIF`
2. Validates arguments against the profile
3. Either performs the operation on behalf of the container or denies it

## User Guide Contents

<div class="grid cards" markdown>

-   :material-file-document:{ .lg .middle } __Profiles__

    ---

    Understanding and using security profiles

    [:octicons-arrow-right-24: Profiles](profiles.md)

-   :material-pencil:{ .lg .middle } __Profile Authoring__

    ---

    Create custom profiles for your workloads

    [:octicons-arrow-right-24: Profile Authoring](profile-authoring.md)

-   :material-package:{ .lg .middle } __Built-in Profiles__

    ---

    Pre-configured profiles for common use cases

    [:octicons-arrow-right-24: Built-in Profiles](builtin-profiles.md)

-   :material-console:{ .lg .middle } __CLI Reference__

    ---

    Complete command-line interface reference

    [:octicons-arrow-right-24: CLI Reference](cli-reference.md)

-   :material-bug:{ .lg .middle } __Troubleshooting__

    ---

    Diagnose and fix common issues

    [:octicons-arrow-right-24: Troubleshooting](troubleshooting.md)

</div>

## Quick Examples

### Run with a Built-in Profile

```bash
# CI runner profile - optimized for build workloads
sudo zigviz run --profile ci-runner build-job . /bin/sh -c "npm install && npm test"

# Minimal profile - maximum security
sudo zigviz run --profile minimal restricted-job . /bin/sh -c "cat /etc/passwd"
```

### Run with Custom Profile

```bash
# Compile your profile
zigviz compile my-profile.yaml

# Run with the profile
sudo zigviz run --profile my-profile custom-job . /bin/sh -c "my-app"
```

### Run with Inline Options

```bash
# Resource limits
sudo zigviz run --memory 256M --cpus 0.5 limited-job . /bin/sh

# Network restrictions
sudo zigviz run --network-allow 10.0.0.0/8 internal-job . /bin/sh

# Read-only filesystem with specific writable paths
sudo zigviz run --readonly --writable /tmp job . /bin/sh
```

## Common Workflows

### Development

```bash
# Quick iteration with debug logging
sudo zigviz --log-level debug run dev-container . /bin/sh

# With audit mode to see what's being blocked
sudo zigviz run --audit dev-container . /bin/sh
```

### CI/CD

```bash
# Run a build with strict isolation
sudo zigviz run \
  --profile ci-runner \
  --memory 2G \
  --timeout 30m \
  build-$BUILD_ID . /bin/sh -c "make build && make test"
```

### Production

```bash
# Multi-container workload
for i in $(seq 1 10); do
  sudo zigviz run \
    --profile web-server \
    --detach \
    web-$i . /bin/sh -c "nginx -g 'daemon off;'"
done
```

## Best Practices

### 1. Start Restrictive, Add Permissions

Begin with a minimal profile and add permissions as needed:

```yaml
# Start with nothing allowed
syscalls:
  allow: []
  deny: ["*"]

# Then add what you need
syscalls:
  allow:
    - read
    - write
    - openat
    - close
```

### 2. Use Built-in Profiles When Possible

Built-in profiles are tested and optimized:

```bash
zigviz compile --list  # See available profiles
```

### 3. Enable Audit Mode During Development

```bash
sudo zigviz run --audit my-container . /bin/sh
# Review /var/log/zigviz/audit.json
```

### 4. Validate Profiles Before Deployment

```bash
zigviz compile --validate my-profile.yaml
```

### 5. Monitor Resource Usage

```bash
zigviz metrics
# Or via Prometheus endpoint
curl http://localhost:9090/metrics
```

## Getting Help

- [Troubleshooting Guide](troubleshooting.md)
- [GitHub Issues](https://github.com/zigviz/zigviz/issues)
- [Architecture Overview](../architecture/index.md)
