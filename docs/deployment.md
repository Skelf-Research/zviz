# Deployment Model

ZViz is designed to integrate with containerd and Kubernetes as a drop-in sandbox runtime. This document describes the intended operational model.

## Artifact

- Static binary per platform per profile (default).
- No daemon required.
- Runs as the runtime helper per container.

## containerd integration (target)

ZViz implements the OCI runtime spec and uses containerd's runc v2 shim interface for compatibility. This allows drop-in integration without custom shim development.

Example runtime registration:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz]
  runtime_type = "io.containerd.runc.v2"  # Uses runc v2 shim interface
  privileged_without_host_devices = false
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz.options]
    BinaryName = "/usr/local/bin/zviz"
```

Note: `runtime_type = "io.containerd.runc.v2"` specifies the shim interface, not the runtime binary. The actual runtime is set via `BinaryName`.

## Kubernetes usage (target)

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: zviz
handler: zviz  # Matches the runtime name in containerd config
```

Workloads opt in via:

```yaml
spec:
  runtimeClassName: zviz
```

## Profile selection

Profiles are selected explicitly at deployment time by the host. The default is a dedicated binary per profile. A multi-profile binary is optional and must use a strict selection flag. Each selection maps to a concrete policy artifact set.

## Day-2 operations

- Standard Linux debugging tools should work (`strace`, `/proc`, `perf`).
- Policy denials are explicit and auditable.
- Metrics include syscall denials, broker latency, and per-container policy hits.

## Related documents

- `docs/host-requirements.md` — Required kernel capabilities for deployment
- `docs/policy-profiles.md` — Profile selection and packaging options
- `docs/benchmark-methodology.md` — How to measure and validate performance
