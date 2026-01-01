# containerd Setup

Configure containerd to use ZigViz as a runtime.

## Prerequisites

- containerd 1.6+
- ZigViz installed

## Configuration

Add to `/etc/containerd/config.toml`:

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.zigviz.options]
    BinaryName = "/usr/local/bin/zigviz"
```

Restart containerd:

```bash
systemctl restart containerd
```

## Verification

```bash
ctr run --runtime io.containerd.runc.v2.zigviz docker.io/library/alpine:latest test echo hello
```

## See Also

- [Kubernetes Integration](kubernetes.md)
- [Monitoring](monitoring.md)
