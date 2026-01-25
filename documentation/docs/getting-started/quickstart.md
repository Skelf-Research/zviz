# Quick Start

Get ZViz running in under 5 minutes.

## 1. Build from Source

```bash
# Clone the repository
git clone https://github.com/AIntheSky/zviz.git
cd zviz

# Build (requires Zig 0.15.0+)
zig build -Doptimize=ReleaseSafe

# Verify installation
./zig-out/bin/zviz version
```

## 2. Run Your First Isolated Container

Create a simple container bundle:

```bash
# Create a minimal rootfs
mkdir -p mycontainer/rootfs
docker export $(docker create alpine:latest) | tar -C mycontainer/rootfs -xf -

# Generate OCI spec
cd mycontainer
../zig-out/bin/zviz spec
```

Run the container:

```bash
# Create and start the container
sudo ../zig-out/bin/zviz run test-container . /bin/sh -c "echo 'Hello from ZViz!' && id"
```

Expected output:
```
Hello from ZViz!
uid=0(root) gid=0(root) groups=0(root)
```

## 3. Test Security Isolation

Try some operations that should be blocked:

```bash
# This should fail - mounting is not allowed
sudo zviz run test2 . /bin/sh -c "mount -t tmpfs none /mnt"
# Output: mount: permission denied

# This should fail - ptrace is blocked
sudo zviz run test3 . /bin/sh -c "strace ls"
# Output: strace: ptrace(PTRACE_TRACEME, ...): Operation not permitted

# This should work - basic file operations are allowed
sudo zviz run test4 . /bin/sh -c "echo test > /tmp/test && cat /tmp/test"
# Output: test
```

## 4. Use Verbose Mode

See exactly which syscalls are being blocked:

```bash
sudo zviz --verbose run test-verbose . /bin/sh -c "ls"
```

Output shows blocked syscalls:
```
[WILL BLOCK] syscall=ptrace (nr=101) → EPERM
[WILL BLOCK] syscall=mount (nr=165) → EPERM
[WILL BLOCK] syscall=unshare (nr=272) → EPERM
...
```

This is essential for debugging workloads that fail with mysterious permission errors.

## 5. Use Security Profiles

ZViz includes built-in profiles for common workloads:

```bash
# Use the CI runner profile (default, balanced security)
sudo zviz --profile=ci-runner run build-job . /bin/sh -c "npm install && npm test"

# Use the web server profile (network optimized)
sudo zviz --profile=web-server run my-api . /bin/sh -c "node server.js"

# Use the batch job profile (no network, high memory)
sudo zviz --profile=batch-job run etl-job . /bin/sh -c "python process.py"

# Use development profile (allows ptrace - NOT for production)
sudo zviz --profile=development run debug . /bin/sh -c "strace ls"
```

Available profiles:

| Profile | Use Case | Notes |
|---------|----------|-------|
| `ci-runner` | CI/CD, builds | Default, balanced security |
| `web-server` | HTTP APIs | Network allowed |
| `batch-job` | Data processing | No network, 8G memory |
| `hostile-tenant` | Untrusted users | Maximum restrictions |
| `development` | Debugging | Allows ptrace - **NOT for production** |

## 6. View Container State

```bash
# List running containers
zviz list

# Get container state
zviz state test-container
```

## 7. Clean Up

```bash
# Delete the container
sudo zviz delete test-container

# Clean up the bundle
cd ..
rm -rf mycontainer
```

## What's Happening?

When you run a container with ZViz, five security layers are applied:

```
┌─────────────────────────────────────────────┐
│           Your Application                   │
├─────────────────────────────────────────────┤
│  1. Namespaces (user, pid, mount, ipc, uts) │ ← Isolation
├─────────────────────────────────────────────┤
│  2. Capabilities (all 41 dropped)           │ ← Privilege reduction
├─────────────────────────────────────────────┤
│  3. Landlock LSM                            │ ← Filesystem policy
├─────────────────────────────────────────────┤
│  4. Seccomp-BPF (124 instructions)          │ ← Syscall filtering
├─────────────────────────────────────────────┤
│  5. cgroups v2                              │ ← Resource limits
└─────────────────────────────────────────────┘
```

## Common Tasks

### Run with Resource Limits

```bash
# Memory and PID limits are set via cgroups
sudo zviz run limited-job . /bin/sh -c "stress --cpu 4"
```

### Run the Security Test Suite

```bash
# Run all security and escape tests
./demo.sh --all

# Run just escape tests
./demo.sh --escape

# Run performance benchmarks
./demo.sh --perf
```

## Next Steps

- [First Container Tutorial](first-container.md) - Detailed walkthrough
- [Profile Authoring](../user-guide/profile-authoring.md) - Create custom profiles
- [Kubernetes Integration](../operator-guide/kubernetes.md) - Use with K8s
- [Architecture](../architecture/index.md) - Understand how it works

## Troubleshooting

### "Permission denied" Errors

Ensure you're running as root or have appropriate capabilities:

```bash
sudo zviz run ...
```

### Workload Fails with EPERM

Use `--verbose` to see which syscall is being blocked:

```bash
sudo zviz --verbose run debug-container . /bin/sh -c "your-command"
```

If a safe syscall is being blocked, consider using a different profile or creating a custom one.

### "Seccomp not available"

Check kernel configuration:

```bash
grep CONFIG_SECCOMP /boot/config-$(uname -r)
```

See [Troubleshooting Guide](../user-guide/troubleshooting.md) for more help.
