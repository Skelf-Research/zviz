# ZViz Examples

Ready-to-use examples for common deployment scenarios.

## Quick Start

```bash
# Kubernetes - Deploy a CI runner
kubectl apply -f kubernetes/ci-runner-job.yaml

# Docker - Run with security profile
docker run --runtime=zviz alpine sh

# Standalone - Run with custom profile
zviz run --profile ci-runner my-container . /bin/sh
```

## Examples by Use Case

### CI/CD Runners

| File | Description |
|------|-------------|
| `kubernetes/ci-runner-job.yaml` | Kubernetes Job for CI builds |
| `kubernetes/github-actions-runner.yaml` | Self-hosted GitHub Actions runner |
| `profiles/ci-runner.yaml` | Security profile for CI workloads |

### Web Applications

| File | Description |
|------|-------------|
| `kubernetes/web-deployment.yaml` | Web app with nginx, HPA, ConfigMaps |
| `profiles/web-server.yaml` | Security profile for web servers |

### Multi-tenant Platforms

| File | Description |
|------|-------------|
| `kubernetes/tenant-namespace.yaml` | Per-tenant namespace with quotas, RBAC, NetworkPolicy |
| `profiles/hostile-tenant.yaml` | Maximum security profile for untrusted code |

### Serverless / FaaS

| File | Description |
|------|-------------|
| `kubernetes/function-pod.yaml` | Pod, Job, and CronJob examples |
| `profiles/minimal.yaml` | Minimal profile for pure computation |

### Docker

| File | Description |
|------|-------------|
| `docker/docker-compose.yaml` | Multi-service example with ZViz |
| `docker/Dockerfile.secure` | Best practices Dockerfile for ZViz |
| `docker/README.md` | Docker usage guide |

## Directory Structure

```
examples/
├── kubernetes/               # Kubernetes manifests
│   ├── ci-runner-job.yaml        # CI build job
│   ├── function-pod.yaml         # Serverless function examples
│   ├── github-actions-runner.yaml # Self-hosted GH runner
│   ├── tenant-namespace.yaml     # Multi-tenant setup
│   └── web-deployment.yaml       # Web app deployment
├── docker/                   # Docker examples
│   ├── docker-compose.yaml       # Multi-service example
│   ├── Dockerfile.secure         # Secure container image
│   └── README.md                 # Docker usage guide
├── profiles/                 # Security profiles
│   ├── ci-runner.yaml            # CI/CD workloads
│   ├── hostile-tenant.yaml       # Maximum security
│   ├── minimal.yaml              # Minimal syscalls
│   └── web-server.yaml           # Web servers
└── README.md                 # This file
```

## Using Examples

### Kubernetes

```bash
# Apply a single example
kubectl apply -f kubernetes/ci-runner-job.yaml

# Watch the pod
kubectl get pods -w

# Check logs
kubectl logs -l app=ci-runner
```

### Custom Profiles

```bash
# Compile a profile
zviz compile profiles/ci-runner.yaml

# Use in Kubernetes via annotation
# annotations:
#   zviz.io/profile: "ci-runner"
```

## See Also

- [Deployment Guide](../deploy/README.md)
- [Profile Schema](../documentation/docs/reference/profile-schema.md)
- [Operator Guide](../documentation/docs/operator-guide/)
