# Deployment Model

ZigViz is designed to integrate with containerd and Kubernetes as a drop-in sandbox runtime. This document describes the intended operational model.

## Artifact

- Static binary per platform, either per profile or multi-profile.
- No daemon required.
- Runs as the runtime helper per container.

## containerd integration (target)

Example runtime registration:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zig]
  runtime_type = "io.containerd.runc.v2"
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zig.options]
    BinaryName = "/usr/local/bin/zigviz"
```

## Kubernetes usage (target)

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zigviz
handler: zig
```

Workloads opt in via:

```yaml
spec:
  runtimeClassName: zigviz
```

## Profile selection

Profiles are selected explicitly at deployment time. Depending on the packaging model, this is either:

- a dedicated binary per profile, or
- a multi-profile binary with a strict selection flag.

Each selection maps to a concrete policy artifact set.

## Day-2 operations

- Standard Linux debugging tools should work (`strace`, `/proc`, `perf`).
- Policy denials are explicit and auditable.
- Metrics include syscall denials, broker latency, and per-container policy hits.
