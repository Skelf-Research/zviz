# Performance Tuning

Optimize ZigViz for your workload.

## Benchmarking

```bash
zigviz benchmark
```

## Tuning Options

### Reduce Brokered Syscalls

Move syscalls from `broker` to `allow` when safe:

```yaml
syscalls:
  allow:
    - openat  # If path validation not needed
```

### Increase Broker Concurrency

```yaml
# /etc/zigviz/config.yaml
broker:
  max_inflight: 512
```

### Disable Audit Logging

```yaml
logging:
  audit:
    enabled: false
```

## See Also

- [Monitoring](monitoring.md)
- [Architecture](../architecture/performance.md)
