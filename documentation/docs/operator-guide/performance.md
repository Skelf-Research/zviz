# Performance Tuning

Optimize ZViz for your workload.

## Benchmarking

```bash
zviz benchmark
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
# /etc/zviz/config.yaml
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
