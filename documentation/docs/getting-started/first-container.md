# Your First Container

This tutorial walks you through creating and running an isolated container step by step, explaining what happens at each stage.

## Prerequisites

- ZigViz installed ([Installation Guide](installation.md))
- Root access or appropriate capabilities
- Basic familiarity with containers

## Step 1: Create a Container Bundle

A container bundle is a directory containing:

- `rootfs/` — The container's filesystem
- `config.json` — OCI runtime specification

### Create the Directory Structure

```bash
mkdir -p tutorial/rootfs
cd tutorial
```

### Populate the Rootfs

We'll use Alpine Linux as a minimal base:

```bash
# Using Docker to export a rootfs
docker export $(docker create alpine:latest) | tar -C rootfs -xf -

# Verify the rootfs
ls rootfs/
# bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
```

### Generate the OCI Spec

```bash
zigviz spec
```

This creates `config.json` with secure defaults:

```json
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": true,
    "user": { "uid": 0, "gid": 0 },
    "args": ["/bin/sh"],
    "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "cwd": "/"
  },
  "root": {
    "path": "rootfs",
    "readonly": true
  },
  ...
}
```

## Step 2: Create the Container

```bash
sudo zigviz create my-first-container .
```

This command:

1. **Sets up namespaces** (user, PID, mount, network, IPC)
2. **Applies seccomp filter** with the default profile
3. **Configures cgroups** for resource limits
4. **Loads LSM policy** (AppArmor/SELinux if available)
5. **Prepares the rootfs** with bind mounts

Check the container state:

```bash
zigviz state my-first-container
```

Output:
```json
{
  "ociVersion": "1.0.2",
  "id": "my-first-container",
  "status": "created",
  "pid": 0,
  "bundle": "/home/user/tutorial"
}
```

## Step 3: Start the Container

```bash
sudo zigviz start my-first-container
```

The container is now running. Check its state:

```bash
zigviz state my-first-container
```

Output:
```json
{
  "ociVersion": "1.0.2",
  "id": "my-first-container",
  "status": "running",
  "pid": 12345,
  "bundle": "/home/user/tutorial"
}
```

## Step 4: Execute Commands

Run commands inside the container:

```bash
# Interactive shell
sudo zigviz exec my-first-container /bin/sh

# Single command
sudo zigviz exec my-first-container /bin/cat /etc/os-release
```

## Step 5: Explore Security Isolation

### Test Namespace Isolation

```bash
# Inside the container, check PID namespace
sudo zigviz exec my-first-container /bin/ps aux
# Only sees processes in this container

# Check user namespace
sudo zigviz exec my-first-container /bin/id
# uid=0(root) gid=0(root) - but this is NOT host root!
```

### Test Syscall Filtering

```bash
# Try to mount (should fail)
sudo zigviz exec my-first-container /bin/mount -t proc proc /proc
# mount: permission denied

# Try to load a kernel module (should fail)
sudo zigviz exec my-first-container /bin/sh -c "insmod /tmp/evil.ko"
# Operation not permitted

# Try to reboot (should fail)
sudo zigviz exec my-first-container /bin/reboot
# Operation not permitted
```

### Test Filesystem Isolation

```bash
# Rootfs is read-only by default
sudo zigviz exec my-first-container /bin/touch /test
# touch: /test: Read-only file system

# /tmp is writable
sudo zigviz exec my-first-container /bin/sh -c "echo hello > /tmp/test && cat /tmp/test"
# hello

# Can't access host files
sudo zigviz exec my-first-container /bin/ls /host
# ls: /host: No such file or directory
```

### Test Network Isolation

```bash
# By default, network is isolated
sudo zigviz exec my-first-container /bin/ping -c 1 8.8.8.8
# Network is unreachable (by default)

# Local loopback works
sudo zigviz exec my-first-container /bin/ping -c 1 127.0.0.1
# PING 127.0.0.1: 64 bytes from 127.0.0.1
```

## Step 6: Monitor Resources

View container resource usage:

```bash
# Using cgroups
cat /sys/fs/cgroup/zigviz/my-first-container/memory.current
cat /sys/fs/cgroup/zigviz/my-first-container/cpu.stat

# Using zigviz metrics
zigviz metrics
```

## Step 7: Stop and Delete

```bash
# Stop the container
sudo zigviz kill my-first-container

# Check state
zigviz state my-first-container
# status: "stopped"

# Delete the container
sudo zigviz delete my-first-container

# Verify deletion
zigviz list
# (empty)
```

## Understanding the Security Layers

Let's see what each layer contributed:

### Layer A: Containment

```bash
# Namespaces isolated the container
ls -la /proc/self/ns/
# user -> user:[4026532456]  (different from host)
# pid -> pid:[4026532458]
# mnt -> mnt:[4026532459]
# net -> net:[4026532461]
# ipc -> ipc:[4026532460]

# Capabilities were dropped
capsh --print
# Current: = (empty - no capabilities)
```

### Layer B: Syscall Gate

The seccomp filter classified syscalls into three categories:

| Category | Example | Action |
|----------|---------|--------|
| **Allow** | `read`, `write`, `exit` | Pass through |
| **Deny** | `mount`, `bpf`, `reboot` | Return EPERM |
| **Broker** | `openat`, `socket`, `clone` | Mediate via broker |

### Layer C: Object Policy

AppArmor/SELinux/Landlock restricted file access:

```
# Example Landlock rules applied
allow read: /usr/**, /lib/**, /etc/**
allow write: /tmp/**, /var/tmp/**
deny: /proc/sys/**, /sys/**
```

### Layer D: Resource Control

cgroups limited resources:

```bash
cat /sys/fs/cgroup/zigviz/my-first-container/memory.max
# 268435456 (256MB)

cat /sys/fs/cgroup/zigviz/my-first-container/pids.max
# 100
```

### Layer E: Network Policy

nftables rules controlled network access:

```bash
# Example rules
nft list ruleset | grep zigviz
# chain zigviz_my-first-container { type filter hook output priority 0; policy drop; }
```

## Next Steps

Now that you understand the basics:

- [Create custom profiles](../user-guide/profile-authoring.md)
- [Use built-in profiles](../user-guide/builtin-profiles.md)
- [Set up Kubernetes integration](../operator-guide/kubernetes.md)
- [Learn about the architecture](../architecture/index.md)

## Clean Up

```bash
cd ..
rm -rf tutorial
```
