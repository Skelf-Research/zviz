# Performance and Cost Comparison

This document presents a customer-facing comparison of expected performance and cost outcomes versus gVisor. It focuses on measurable metrics that show up in cloud bills and SRE dashboards. The numbers are targets and illustrative examples, not measured results.

## Scope and assumptions

- These are realistic targets based on public benchmarks, operator reports, and the architecture described in this repository.
- Actual results depend on workload mix, kernel version, profile strictness, and host configuration.
- Numbers are intended for planning and evaluation, not as contractual guarantees.

## Where gVisor costs money

gVisor interposes on most syscalls via a userspace kernel. That introduces:

- extra context switches
- syscall decoding and emulation overhead
- runtime scheduler and GC activity

Observed CPU overhead ranges reported for gVisor systrap (indicative):

| Workload type              | Typical gVisor overhead |
| -------------------------- | ----------------------- |
| Syscall-heavy (CI, builds) | 30-70% CPU              |
| Network-heavy services     | 20-50% CPU              |
| Mixed workloads            | 15-30% CPU              |

This often translates to 20-40% fewer pods per node.

gVisor KVM mode can change these numbers and should be measured separately.

## ZigViz performance profile

ZigViz avoids syscall emulation and only mediates security-relevant syscalls. Performance targets:

| Workload type | ZigViz overhead target |
| ------------- | ---------------------- |
| Syscall-heavy | 5-10% CPU              |
| Network-heavy | ~0-5% CPU              |
| Mixed         | <10% CPU               |

This is intended to be close to runc-level performance while enforcing strong policy outcomes.

## Cost impact example

Assume a typical Kubernetes node:

- 32 vCPUs
- $0.04 per vCPU-hour
- 24/7 utilization

### Density comparison

- gVisor: effective 22-25 vCPUs, about 110 pods per node
- ZigViz: effective 29-30 vCPUs, about 140-150 pods per node

That is roughly 25-35% higher density. For the same workload, node count can be reduced by a similar percentage.

### Monthly cost impact (per 100 nodes)

| Runtime     | Monthly compute cost (illustrative) |
| ----------- | ----------------------------------- |
| gVisor      | ~92,000 USD                         |
| ZigViz      | ~68,000 USD                         |

Approximate savings: 24,000 USD per month per 100 nodes (about 288,000 USD per year) when the node count is reduced to match workload demand.

## Memory overhead

Per-pod RSS ranges:

- gVisor: 20-50 MB (runtime + userspace kernel + netstack buffers)
- ZigViz: 1-3 MB (target, static binary, no runtime, no netstack)

At 150 pods per node:

| Runtime     | Memory used |
| ----------- | ----------- |
| gVisor      | 3-7.5 GB    |
| ZigViz      | ~300 MB     |

This can reduce OOM pressure, enable smaller instance types, and improve bin-packing efficiency.

## Latency and tail behavior

Expected advantages from reduced mediation and no runtime GC:

- lower p99 latency
- tighter latency distribution
- fewer performance regressions under load spikes

These effects are most visible in CI systems, serverless platforms, and multi-tenant APIs.

## Networking performance

gVisor runs a userspace TCP/IP stack. ZigViz uses the host kernel networking stack with namespace isolation and BPF controls. Target deltas:

- 2-4x higher throughput
- lower connection setup latency
- fewer compatibility issues with TCP edge cases

## Operational cost savings

- Debugging: standard Linux tools and semantics reduce investigation time.
- Maintenance: fewer semantic surface areas to track versus a userspace kernel.

## Summary table

| Dimension      | gVisor        | ZigViz        |
| -------------- | ------------- | ------------ |
| CPU overhead   | High          | Low          |
| Pod density    | Lower         | +25-35%      |
| Memory per pod | 20-50 MB      | 1-3 MB       |
| Network perf   | Medium        | Near-native (target) |
| Tail latency   | Unpredictable | More predictable (target) |
| Debuggability  | Hard          | Easy         |
| Cloud bill     | Higher        | Lower (target) |

## Next steps for validation

- Choose a benchmark suite (CI builds are a good starting point).
- Define measurement methodology and success criteria in `docs/benchmark-methodology.md`.
- Publish side-by-side results: runc vs gVisor vs ZigViz.

## Related documents

- `docs/benchmark-methodology.md` — Detailed testing methodology and success criteria
- `docs/overview.md` — Performance posture and design rationale
- `docs/deployment.md` — Operational metrics and monitoring
