# Quick Start

Get ZViz running in under 5 minutes.

## 1. Install ZViz

```bash
curl -fsSL https://zviz.io/install.sh | sh
```

## 2. Verify Installation

```bash
zviz version
```

## 3. Run Your First Isolated Container

Create a simple container bundle:

```bash
# Create a minimal rootfs
mkdir -p mycontainer/rootfs
docker export $(docker create alpine:latest) | tar -C mycontainer/rootfs -xf -

# Generate OCI spec
cd mycontainer
zviz spec
```

Run the container:

```bash
# Create and start the container
sudo zviz run test-container . /bin/sh -c "echo 'Hello from ZViz!' && id"
```

Expected output:
```
Hello from ZViz!
uid=0(root) gid=0(root) groups=0(root)
```

## 4. Test Security Isolation

Try some operations that should be blocked:

```bash
# This should fail - mounting is not allowed
sudo zviz run test2 . /bin/sh -c "mount -t tmpfs none /mnt"
# Output: mount: permission denied

# This should fail - loading kernel modules is blocked
sudo zviz run test3 . /bin/sh -c "insmod /nonexistent.ko"
# Output: insmod: can't insert '/nonexistent.ko': Operation not permitted

# This should work - basic file operations are allowed
sudo zviz run test4 . /bin/sh -c "echo test > /tmp/test && cat /tmp/test"
# Output: test
```

## 5. Use a Security Profile

ZViz includes built-in profiles for common use cases:

```bash
# List available profiles
zviz compile --list

# Use the CI runner profile
sudo zviz run --profile ci-runner build-job . /bin/sh -c "npm install && npm test"
```

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

When you run a container with ZViz, several security layers are applied:

```
┌─────────────────────────────────────────────┐
│           Your Application                   │
├─────────────────────────────────────────────┤
│  Layer A: Namespaces + Capabilities         │ ← Resource isolation
├─────────────────────────────────────────────┤
│  Layer B: Seccomp Filter + Broker           │ ← Syscall mediation
├─────────────────────────────────────────────┤
│  Layer C: AppArmor/SELinux/Landlock         │ ← File/object policy
├─────────────────────────────────────────────┤
│  Layer D: cgroups v2                        │ ← Resource limits
├─────────────────────────────────────────────┤
│  Layer E: Network namespace + nftables      │ ← Network policy
└─────────────────────────────────────────────┘
```

## Common Tasks

### Run with Resource Limits

```bash
sudo zviz run --memory 256M --cpus 0.5 limited-job . /bin/sh -c "stress --cpu 4"
```

### Run with Network Isolation

```bash
# Block all network access
sudo zviz run --network none isolated . /bin/sh -c "curl google.com"
# Output: Network is unreachable

# Allow only internal network
sudo zviz run --network-allow 10.0.0.0/8 internal . /bin/sh -c "curl 10.0.0.1"
```

### Run with Audit Logging

```bash
sudo zviz run --audit audit-test . /bin/sh -c "ls /etc"
# Check audit log
cat /var/log/zviz/audit.json
```

## Next Steps

- [First Container Tutorial](first-container.md) — Detailed walkthrough
- [Profile Authoring](../user-guide/profile-authoring.md) — Create custom profiles
- [Kubernetes Integration](../operator-guide/kubernetes.md) — Use with K8s
- [Architecture](../architecture/index.md) — Understand how it works

## Troubleshooting

### "Permission denied" Errors

Ensure you're running as root or have appropriate capabilities:

```bash
sudo zviz run ...
```

### "Seccomp not available"

Check kernel configuration:

```bash
grep CONFIG_SECCOMP /boot/config-$(uname -r)
```

### Container Won't Start

Check for detailed errors:

```bash
zviz --log-level debug run ...
```

See [Troubleshooting Guide](../user-guide/troubleshooting.md) for more help.
