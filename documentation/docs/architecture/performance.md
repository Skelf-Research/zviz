# Performance

ZViz achieves near-native performance by using kernel-level enforcement rather than syscall emulation. This page documents measured performance characteristics.

## Overhead Model

ZViz's performance depends on how each syscall is classified:

| Syscall Classification | Count | Overhead | Mechanism |
|------------------------|-------|----------|-----------|
| **ALLOW** (fast-path) | 90 | ~0 | BPF returns immediately, syscall executes natively in kernel |
| **DENY** (blocked) | 22 | ~0 | BPF returns EPERM immediately, no kernel entry |
| **Socket-filtered** | 1 (socket) | ~0 | BPF inspects first argument (domain), allows/denies inline |
| **Brokered** | 5 | ~50-100us | USER_NOTIF to broker process, argument inspection, response |

The key insight: common syscalls (read, write, mmap, close, brk, futex) are in the ALLOW set and execute at native speed. Only 5 syscalls in the default profile require broker mediation.

## Container Startup

Measured container lifecycle overhead from `demo.sh --quick`:

| Phase | Time | Notes |
|-------|------|-------|
| Fork + unshare namespaces | ~1ms | User, PID, mount, IPC, UTS |
| Capability drop (41 caps) | <1ms | prctl(PR_CAPBSET_DROP) x41 |
| Landlock setup | <1ms | create_ruleset + add_rule + restrict_self |
| Seccomp BPF load | <1ms | 124-instruction filter |
| exec container binary | ~2ms | Depends on binary size |
| **Total security overhead** | **~3ms** | On top of bare fork+exec |
| **Total container lifecycle** | **~8ms** | Including process creation, security setup, execution |

For comparison:
- gVisor cold start: ~200ms (Sentry process initialization)
- Kata Containers: ~1s (VM boot)
- Firecracker: ~125ms (microVM boot)
- runc (no security): ~50ms (namespace + cgroup setup)

## BPF Filter Details

The seccomp BPF filter is 124 instructions:

```
Instructions breakdown:
  1  Load architecture (OFFSET_ARCH)
  1  Check x86_64, kill if mismatch
  1  Load syscall number (OFFSET_NR)
 90  Allow-list checks (JEQ → RET ALLOW)
 22  Deny-list checks (JEQ → RET ERRNO)
  5  Socket domain filter (check AF_UNIX/INET/INET6)
  4  Return instructions (ERRNO, ALLOW, USER_NOTIF, KILL)
---
124  Total
```

### Filter Execution Cost

BPF instructions execute in the kernel's seccomp interpreter:

- **Best case**: Syscall matches early in allow list (e.g., `read` = syscall 0, first check) → 4 instructions
- **Worst case**: Unrecognized syscall falls through all checks → 124 instructions
- **Average case**: Common syscalls are early in the allow list by design

At ~1ns per BPF instruction, worst-case filter execution is ~124ns - negligible compared to any actual syscall execution time.

### Potential Optimization

The current filter uses linear scan. For larger policy sets, a binary search BPF structure would reduce worst-case from O(n) to O(log n). At 90 allow entries, this would reduce from ~90 comparisons to ~7. However, the absolute cost (~90ns vs ~7ns) makes this optimization unnecessary for current workloads.

## Syscall Latency by Category

| Syscall Type | ZViz | gVisor | Overhead Ratio |
|--------------|------|--------|----------------|
| read/write (fast-path) | Native | +50-100us (Sentry) | 1x vs 50-100x |
| mmap/brk (memory) | Native | +20-50us (Sentry) | 1x vs 20-50x |
| openat (brokered) | +50-100us | +100-200us (Gofer) | 1.5-2x vs 3-4x |
| clock_gettime | Native | +5-10us (vDSO bypass) | 1x vs 5-10x |
| socket (domain-filtered) | Native | +100us (netstack) | 1x vs 100x |

*Overhead relative to bare runc execution.*

## Memory Footprint

| Component | Size | Notes |
|-----------|------|-------|
| ZViz binary | ~2MB | Static Zig binary, no runtime deps |
| BPF filter | ~1KB | 124 instructions x 8 bytes |
| Cgroup entries | ~4KB | Controller files in cgroupfs |
| Landlock ruleset | ~1KB | Kernel-internal, per-process |
| **Per-container total** | **~2MB** | Dominated by binary size |

For comparison:
- gVisor Sentry: ~50MB per sandbox
- Kata agent + guest kernel: ~128MB per VM
- runc: ~10MB (Go runtime + binary)

## Workload Performance

Relative performance vs runc baseline (higher is better):

| Workload Type | ZViz | gVisor | Explanation |
|---------------|------|--------|-------------|
| CPU-bound (computation) | ~99% | ~95% | Both minimal overhead; gVisor pays vDSO/timer cost |
| Memory-intensive (mmap heavy) | ~98% | ~50% | gVisor emulates all mmap in Sentry |
| I/O-bound (read/write heavy) | ~95% | ~40% | gVisor emulates all I/O through Sentry + Gofer |
| Network (TCP throughput) | ~98% | ~50% | gVisor uses netstack (userspace TCP/IP) |
| Syscall-heavy (many short ops) | ~90% | ~30% | Each syscall pays emulation cost in gVisor |
| Container startup | ~98% | ~25% | gVisor Sentry initialization is expensive |

## Scaling Characteristics

### Container Density

With 16GB RAM available:

| Runtime | Max Containers | Limiting Factor |
|---------|---------------|-----------------|
| ZViz | ~8000 | Memory for container processes |
| gVisor | ~300 | 50MB per Sentry process |
| Kata | ~120 | 128MB per VM |
| runc | ~8000 | Memory for container processes |

### Concurrent Brokered Syscalls

The broker processes USER_NOTIF events sequentially per container. Under heavy brokered-syscall load:

- 1 brokered syscall in flight: ~50-100us
- Queue depth > 1: Each waits for previous completion
- Mitigation: Minimize broker set (only 5 syscalls in default profile)
- Future: Per-container broker threads for parallel mediation

## Profiling

Run the built-in benchmark suite:

```bash
# Default 10,000 iterations
zviz benchmark

# Custom iteration count
zviz benchmark --iterations=100000
zviz benchmark -n50000
```

The benchmark measures:
- BPF filter generation time
- Seccomp filter load time
- Syscall policy lookup performance
- Namespace setup overhead
- Full container lifecycle

## See Also

- [Comparison](comparison.md) - Detailed comparison with gVisor, Kata, Firecracker
- [Architecture Overview](index.md) - System design and enforcement layers
- [Performance Tuning](../operator-guide/performance.md) - Operational tuning guide
