# Troubleshooting

Common issues and solutions when using ZViz.

## Container Won't Start

### Permission Denied

**Symptom:**
```
Error: PermissionDenied
```

**Solutions:**

1. Run as root:
   ```bash
   sudo zviz run ...
   ```

2. Check user namespaces are enabled:
   ```bash
   cat /proc/sys/kernel/unprivileged_userns_clone
   # Should be 1
   ```

3. Check seccomp is available:
   ```bash
   zviz validate
   ```

### Missing Rootfs

**Symptom:**
```
Error: FileNotFound: rootfs
```

**Solution:**

Ensure the bundle directory contains `rootfs/`:
```bash
ls my-bundle/
# Should show: config.json  rootfs/
```

## Syscall Blocked

### Finding Blocked Syscalls

**Enable audit mode:**
```bash
sudo zviz run --audit my-container . /bin/my-app
```

**Check audit log:**
```bash
jq '.[] | select(.decision == "denied")' /var/log/zviz/audit.json
```

### Adding Syscall Permissions

**Update your profile:**
```yaml
syscalls:
  allow:
    - needed_syscall
```

## Network Issues

### No Network Access

**Symptom:**
```
Network unreachable
```

**Check profile network settings:**
```yaml
network:
  egress:
    allow:
      - 10.0.0.0/8    # Add allowed networks
```

### DNS Not Working

**Add DNS egress:**
```yaml
network:
  dns:
    allow: true
```

## Performance Issues

### High Latency

**Check broker metrics:**
```bash
zviz metrics | grep latency
```

**Reduce brokered syscalls:**
```yaml
syscalls:
  allow:
    - openat  # Move from broker to allow
```

### High Memory Usage

**Check container limits:**
```bash
cat /sys/fs/cgroup/zviz/*/memory.current
```

## Debug Mode

**Enable verbose logging:**
```bash
sudo zviz --log-level debug run my-container . /bin/sh
```

## Getting Help

- Check [GitHub Issues](https://github.com/zviz/zviz/issues)
- Review [Architecture docs](../architecture/index.md)
- Email: support@zviz.io
