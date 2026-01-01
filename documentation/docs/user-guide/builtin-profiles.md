# Built-in Profiles

ZigViz includes pre-configured profiles for common use cases.

## Available Profiles

| Profile | Use Case | Security Level |
|---------|----------|----------------|
| `minimal` | Maximum security | Very High |
| `ci-runner` | CI/CD builds | High |
| `web-server` | Web applications | Medium-High |
| `database` | Database servers | Medium-High |
| `default` | General purpose | Medium |

## Profile Details

### minimal

Maximum security profile with minimal permissions.

```bash
zigviz run --profile minimal container . /bin/sh
```

**Allows:**
- Basic I/O (read, write, close)
- Memory operations (mmap, brk)
- Process exit

**Denies:**
- All network access
- File creation
- Process spawning

### ci-runner

Optimized for CI/CD build workloads.

```bash
zigviz run --profile ci-runner build . /bin/sh -c "npm install && npm test"
```

**Allows:**
- File operations (needed for builds)
- Network access to internal registries
- Process spawning (for build tools)

**Denies:**
- Raw network sockets
- Kernel module loading
- Host filesystem access

### web-server

For web application containers.

```bash
zigviz run --profile web-server web . /usr/bin/nginx
```

**Allows:**
- Network bind to ports 80, 443, 8080
- File serving
- Logging

**Denies:**
- Outbound internet (except DNS)
- Privileged operations

### database

For database containers.

```bash
zigviz run --profile database db . /usr/bin/postgres
```

**Allows:**
- Persistent storage access
- Network for client connections
- Memory operations

**Denies:**
- Internet access
- Code execution

## Using Profiles

```bash
# List available profiles
zigviz compile --list

# Show profile details
zigviz compile --show ci-runner

# Use a profile
sudo zigviz run --profile ci-runner my-container . /bin/sh
```

## Customizing Built-in Profiles

Extend a built-in profile:

```yaml
name: my-ci-runner
version: "1.0"
extends: ci-runner

# Add permissions
syscalls:
  allow:
    - ptrace  # For debugging

# Restrict network further
network:
  egress:
    allow:
      - 10.0.0.0/8
    deny:
      - 0.0.0.0/0
```

## See Also

- [Profiles Guide](profiles.md)
- [Profile Authoring](profile-authoring.md)
- [Profile Schema](../reference/profile-schema.md)
