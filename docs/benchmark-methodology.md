# Benchmark Methodology

This document defines how to measure ZViz against runc and gVisor. The goal is to produce repeatable, customer-trustworthy numbers.

## Objectives

- Measure CPU overhead, latency impact, memory overhead, and network throughput.
- Compare outcomes across runc, gVisor, and ZViz under the same workload.
- Ensure results are reproducible and explainable.

## Test matrix

Runtimes:

- runc (baseline)
- gVisor (systrap and, if relevant, KVM)
- ZViz (high-density mode)

Workloads:

- CI build workloads (syscall-heavy)
- Network services (network-heavy)
- Mixed application stacks

Profiles:

- Use a defined policy profile per workload.
- Document any differences in policy strictness.

## Metrics

- CPU: total CPU time, CPU utilization, and overhead vs runc
- Memory: per-pod RSS and total node memory pressure
- Latency: p50/p95/p99 and tail stability under load
- Throughput: request/s, bandwidth, and connection setup latency
- Density: pods per node at target SLOs
- Policy: syscall denials and broker decision latency

## Methodology

- Pin runtime and kernel versions; record exact versions.
- Run each workload with fixed inputs and warm-up phases.
- Execute 30-minute steady-state runs and three independent repetitions.
- Collect host-level metrics (node exporter, perf, cgroup stats).
- Collect runtime metrics (broker latency, syscall counts, denials).

## Fairness rules

- Same hardware, kernel, and container image across all runtimes.
- Same resource limits and cgroup settings.
- Same network policies and LSM configuration.
- Same application configuration and input data.

## Output artifacts

- A summary table with overhead vs runc.
- Raw data CSVs for CPU, memory, latency, and throughput.
- A policy manifest for each runtime configuration.
- A short narrative explaining deviations or anomalies.

## Success criteria (initial targets)

- ZViz CPU overhead <= 10% on syscall-heavy workloads.
- ZViz CPU overhead <= 5% on network-heavy workloads.
- ZViz memory overhead <= 3 MB per pod.
- ZViz p99 latency <= gVisor p99 for the same workload.
- Policy outcomes match or exceed the defined policy scope.

## Related documents

- `docs/performance-cost.md` — Customer-facing performance comparison
- `docs/profile-ci-runner.md` — CI runner profile for benchmark workloads
- `docs/threat-model.md` — Policy outcome definitions for validation
