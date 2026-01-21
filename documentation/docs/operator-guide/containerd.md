# containerd Setup

Configure containerd to use ZViz as a runtime.

## Prerequisites

- containerd 1.6+
- ZViz installed

## Configuration

Add to `/etc/containerd/config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zviz.options]
    BinaryName = "/usr/local/bin/zviz"
```

Restart containerd:

```bash
systemctl restart containerd
```

## Verification

```bash
ctr run --runtime io.containerd.runc.v2.zviz docker.io/library/alpine:latest test echo hello
```

## See Also

- [Kubernetes Integration](kubernetes.md)
- [Monitoring](monitoring.md)
