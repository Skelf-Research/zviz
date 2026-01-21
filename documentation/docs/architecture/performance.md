# Performance

ZViz performance characteristics and benchmarks.

## Overhead

| Workload | Overhead vs runc |
|----------|------------------|
| CPU-bound | ~5% |
| I/O-bound | ~8% |
| Network | <2% |
| Syscall-heavy | ~10% |

## Benchmarks

```bash
zviz benchmark
```

See [Performance Tuning](../operator-guide/performance.md).
