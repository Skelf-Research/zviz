# ZViz Implementation Roadmap

This document defines the implementation roadmap for ZViz, translating the design documents into actionable phases with clear success criteria.

## Overview

The roadmap is organized into six phases, progressing from foundational infrastructure to production readiness. Each phase has defined exit criteria that must be met before proceeding.

| Phase | Name | Focus |
|-------|------|-------|
| 0 | Foundation | Build system, testing infrastructure, CI |
| 1 | Core Broker | Zig broker with seccomp user notification |
| 2 | Enforcement Layers | Implement layers A-E from enforcement model |
| 3 | Policy System | Profile schema, compiler, and validation |
| 4 | Integration | containerd/Kubernetes integration |
| 5 | Validation | Benchmarks, security testing, hardening |
| 6 | Production | Documentation, packaging, release |

---

## Phase 0: Foundation

**Goal**: Establish build infrastructure, testing framework, and development workflow.

### Tasks

- [ ] Initialize Zig project structure with build.zig
- [ ] Set up cross-compilation targets (x86_64, aarch64)
- [ ] Configure CI pipeline (build, test, lint)
- [ ] Create unit test framework and conventions
- [ ] Set up integration test harness (containers, namespaces)
- [ ] Establish code review and contribution guidelines
- [ ] Define logging and error handling conventions

### Dependencies

- None (entry phase)

### Success Criteria

- [ ] `zig build` produces static binaries for x86_64 and aarch64
- [ ] CI runs on every PR with build + test gates
- [ ] Unit tests can be run with `zig build test`
- [ ] Integration tests can spawn namespaced processes
- [ ] Build is reproducible (same inputs → same binary hash)

### Deliverables

- `build.zig` with release and debug targets
- `.github/workflows/` or equivalent CI configuration
- `src/` directory structure with module organization
- `tests/` directory with unit and integration test scaffolding

---

## Phase 1: Core Broker

**Goal**: Implement the Zig broker that receives seccomp user notifications and makes policy decisions.

### Tasks

- [ ] Implement seccomp user notification listener (`SECCOMP_RET_USER_NOTIF`)
- [ ] Build syscall argument parser for brokered syscalls
- [ ] Implement `openat`/`openat2` mediation with `RESOLVE_*` flags
- [ ] Implement `ioctl` filtering with subsystem allowlists
- [ ] Implement `socket`/`socketpair` domain restrictions
- [ ] Implement `clone`/`clone3` flag validation (deny new namespaces)
- [ ] Implement `execve`/`execveat` path validation hooks
- [ ] Implement `prctl` capability mediation
- [ ] Build file descriptor passing via `SCM_RIGHTS`
- [ ] Implement broker timeout and max-inflight limits
- [ ] Create audit log output (JSON format)

### Dependencies

- Phase 0 complete

### Success Criteria

- [ ] Broker receives seccomp notifications and responds correctly
- [ ] `openat2` mediation prevents path traversal attacks
- [ ] `ioctl` blocks unlisted commands, allows listed ones
- [ ] `clone` with `CLONE_NEWNS` (or similar) is denied
- [ ] `socket(AF_NETLINK, ...)` is denied when not in allowlist
- [ ] Broker handles 256 concurrent syscalls without deadlock
- [ ] Decision latency p99 < 1ms for simple allow/deny
- [ ] Audit logs contain syscall, args, decision, and latency

### Deliverables

- `src/broker/` module with notification handling
- `src/syscalls/` module with per-syscall mediators
- `src/audit/` module with structured logging
- Unit tests for each brokered syscall
- Integration test: broker + seccomp filter + test process

---

## Phase 2: Enforcement Layers

**Goal**: Implement the five-layer enforcement model (A-E) from `docs/enforcement-model.md`.

### Layer A: Containment

#### Tasks

- [ ] Namespace setup (user, PID, mount, network, IPC)
- [ ] Capability dropping (deny all, add back minimal set)
- [ ] Filesystem baseline (read-only rootfs, no device nodes)
- [ ] Mount namespace configuration (bind mounts, tmpfs)

#### Success Criteria

- [ ] Container runs in isolated namespace set
- [ ] `capsh --print` shows minimal capabilities
- [ ] `/dev` contains only safe device nodes (null, zero, urandom)
- [ ] Writes to rootfs fail with EROFS

### Layer B: Syscall Gate

#### Tasks

- [ ] Generate seccomp-bpf program from profile
- [ ] Implement three-tier syscall handling (allow/deny/broker)
- [ ] Load seccomp filter before exec
- [ ] Handle seccomp filter inheritance for child processes

#### Success Criteria

- [ ] `bpf()` syscall returns EPERM
- [ ] `read()` syscall succeeds without broker involvement
- [ ] `openat()` routes to broker and returns fd
- [ ] Child processes inherit the seccomp filter

### Layer C: Object Policy (LSM)

#### Tasks

- [ ] AppArmor profile generation from ZViz profile
- [ ] SELinux policy module generation (alternative)
- [ ] Landlock ruleset setup (unprivileged fallback)
- [ ] LSM profile loading and enforcement

#### Success Criteria

- [ ] Write to `/etc/passwd` denied by LSM
- [ ] Write to `/work/` allowed by LSM
- [ ] Binary execution restricted to allowed paths
- [ ] LSM denials logged with profile context

### Layer D: Resource Control

#### Tasks

- [ ] cgroups v2 controller setup (cpu, memory, pids, io)
- [ ] Resource limit application from profile
- [ ] OOM handling and reporting
- [ ] I/O bandwidth limiting

#### Success Criteria

- [ ] Process exceeding memory limit is OOM-killed
- [ ] Fork bomb is stopped by pids limit
- [ ] CPU-bound process is throttled to cpu_max
- [ ] Resource metrics are exposed for monitoring

### Layer E: Network Policy

#### Tasks

- [ ] Network namespace setup with veth pair
- [ ] iptables/nftables rule generation from CIDR allowlist
- [ ] eBPF-based enforcement (optional, for performance)
- [ ] Egress filtering with connection tracking
- [ ] Ingress policy (deny by default)

#### Success Criteria

- [ ] Connections to 10.0.0.0/8 succeed (when allowed)
- [ ] Connections to public internet fail (when not allowed)
- [ ] Raw socket creation fails
- [ ] DNS egress works when proxy is configured

### Phase 2 Overall Success Criteria

- [ ] All five layers are independently testable
- [ ] Layers compose correctly (A+B+C+D+E)
- [ ] Policy denials are traceable to specific layer
- [ ] Escape test suite passes (see Phase 5)

### Deliverables

- `src/containment/` — namespace and capability setup
- `src/seccomp/` — BPF program generation and loading
- `src/lsm/` — AppArmor/SELinux/Landlock generators
- `src/cgroup/` — cgroups v2 controller interface
- `src/network/` — network namespace and firewall setup
- Integration tests for each layer in isolation and combined

---

## Phase 3: Policy System

**Goal**: Implement the profile schema, policy compiler, and validation pipeline.

### Tasks

- [ ] YAML profile parser (based on `docs/profile-schema.md`)
- [ ] Schema validation with error reporting
- [ ] Seccomp BPF code generator
- [ ] LSM policy generator (AppArmor/SELinux/Landlock)
- [ ] Network rule generator (iptables/nftables)
- [ ] Broker rule table generator
- [ ] Manifest generator (input hash, rule-to-intent mapping)
- [ ] Profile requirements checker (LSM, seccomp_notify, network)
- [ ] Compiler CLI with deterministic output
- [ ] Profile embedding in static binary

### Dependencies

- Phase 1 (broker rule table format)
- Phase 2 (enforcement artifact formats)

### Success Criteria

- [ ] Valid profile compiles without errors
- [ ] Invalid profile produces actionable error messages
- [ ] Same profile input produces identical output (reproducible)
- [ ] Compiled artifacts pass schema validation
- [ ] Manifest correctly maps rules to profile intent
- [ ] Missing host capabilities produce clear failure message
- [ ] CI runner profile (`docs/profile-ci-runner.md`) compiles successfully

### Deliverables

- `src/compiler/` — policy compiler module
- `src/schema/` — YAML parser and validator
- `zviz compile` CLI command
- Generated artifacts: `.bpf`, `.apparmor`, `.nft`, `.broker`
- Manifest format documentation

---

## Phase 4: Integration

**Goal**: Integrate ZViz with containerd and Kubernetes as described in `docs/deployment.md`.

### Tasks

- [ ] Implement OCI runtime spec interface
- [ ] Handle container lifecycle (create, start, kill, delete)
- [ ] Implement state reporting for containerd
- [ ] Support containerd runtime registration
- [ ] Create Kubernetes RuntimeClass examples
- [ ] Handle pod annotations for profile selection
- [ ] Implement container stdio handling
- [ ] Support exec into running containers
- [ ] Expose metrics endpoint (Prometheus format)

### Dependencies

- Phase 2 (enforcement layers)
- Phase 3 (compiled profiles)

### Success Criteria

- [ ] `zviz create/start/kill/delete` works as OCI runtime
- [ ] containerd can spawn containers with ZViz runtime
- [ ] Kubernetes pods with `runtimeClassName: zviz` run correctly
- [ ] `kubectl exec` into ZViz container works
- [ ] Container logs are accessible via containerd
- [ ] Metrics endpoint exposes broker latency and denial counts
- [ ] Profile selection works via pod annotation

### Deliverables

- `zviz` binary with OCI runtime commands
- containerd configuration examples
- Kubernetes RuntimeClass and Pod manifests
- Metrics documentation
- Troubleshooting guide

---

## Phase 5: Validation

**Goal**: Validate security properties, performance targets, and policy equivalence.

### Security Testing

#### Tasks

- [ ] Build escape-class test suite
- [ ] Test namespace breakout attempts
- [ ] Test capability escalation paths
- [ ] Test seccomp bypass attempts
- [ ] Test broker TOCTOU attacks
- [ ] Test resource exhaustion attacks
- [ ] Fuzz broker syscall argument parsing
- [ ] Fuzz profile compiler
- [ ] Third-party security review (optional)

#### Success Criteria

- [ ] All escape tests fail (attacks are blocked)
- [ ] Fuzzing finds no crashes or policy bypasses
- [ ] No known CVE patterns succeed
- [ ] Broker handles malformed input gracefully

### Performance Testing

#### Tasks

- [ ] Implement benchmark suite per `docs/benchmark-methodology.md`
- [ ] Measure CPU overhead vs runc baseline
- [ ] Measure memory overhead per pod
- [ ] Measure syscall latency (p50/p95/p99)
- [ ] Measure network throughput
- [ ] Measure pod density at target SLOs
- [ ] Compare results against gVisor

#### Success Criteria

- [ ] CPU overhead <= 10% on syscall-heavy workloads
- [ ] CPU overhead <= 5% on network-heavy workloads
- [ ] Memory overhead <= 3 MB per pod
- [ ] p99 latency <= gVisor p99 for same workload
- [ ] Network throughput >= 2x gVisor

### Policy Equivalence Testing

#### Tasks

- [ ] Define policy outcome test cases
- [ ] Run same workload on gVisor and ZViz
- [ ] Compare syscall allow/deny decisions
- [ ] Compare file access outcomes
- [ ] Compare network policy outcomes
- [ ] Document any intentional divergences

#### Success Criteria

- [ ] Policy outcomes match gVisor for defined scope
- [ ] Divergences are documented and justified
- [ ] No unintended policy gaps

### Deliverables

- `tests/escape/` — escape-class test suite
- `tests/bench/` — benchmark harness and workloads
- Benchmark results (CSV + narrative)
- Security test report
- Policy equivalence report

---

## Phase 6: Production Readiness

**Goal**: Prepare ZViz for production deployment with documentation, packaging, and release process.

### Tasks

- [ ] Write user documentation (installation, configuration)
- [ ] Write operator documentation (monitoring, debugging)
- [ ] Create profile authoring guide
- [ ] Package for common distributions (deb, rpm, container image)
- [ ] Set up release automation (tags, changelogs, binaries)
- [ ] Create upgrade/migration guide
- [ ] Establish security disclosure process
- [ ] Define support policy and versioning scheme

### Dependencies

- Phase 5 complete with passing criteria

### Success Criteria

- [ ] New user can install and run ZViz in < 30 minutes
- [ ] All documentation reviewed and tested
- [ ] Release binaries are signed and reproducible
- [ ] SECURITY.md with disclosure process exists
- [ ] Changelog follows consistent format
- [ ] Example profiles work out of the box

### Deliverables

- `docs/user-guide.md`
- `docs/operator-guide.md`
- `docs/profile-authoring.md`
- Distribution packages
- Container images (ghcr.io or similar)
- Release automation (GitHub Actions or similar)
- SECURITY.md, CHANGELOG.md, CONTRIBUTING.md

---

## Phase Dependencies

```
Phase 0 ──────┐
              ▼
         Phase 1 (Broker)
              │
              ▼
         Phase 2 (Layers) ◄──────┐
              │                  │
              ▼                  │
         Phase 3 (Policy) ───────┘
              │
              ▼
         Phase 4 (Integration)
              │
              ▼
         Phase 5 (Validation)
              │
              ▼
         Phase 6 (Production)
```

## Risk Areas

| Risk | Mitigation |
|------|------------|
| seccomp user notification latency | Early benchmarking in Phase 1; fallback to sync-only for latency-critical paths |
| LSM availability varies by host | Implement Landlock fallback; clear capability detection in Phase 3 |
| Kernel version compatibility | Define minimum kernel version; test on LTS kernels (5.15, 6.1) |
| gVisor policy equivalence gaps | Document scope clearly; accept reduced guarantees without LSM |
| Broker complexity creep | Limit brokered syscall set; prefer kernel-enforced policies |

## Related Documents

- `docs/overview.md` — Project goals and architecture
- `docs/threat-model.md` — Security assumptions and scope
- `docs/enforcement-model.md` — Five-layer enforcement design
- `docs/broker-design.md` — Broker architecture
- `docs/profile-schema.md` — Profile definition format
- `docs/benchmark-methodology.md` — Performance testing approach
- `docs/deployment.md` — Integration model
