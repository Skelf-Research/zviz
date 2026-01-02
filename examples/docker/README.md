# Docker Examples for ZigViz

This directory contains examples for using ZigViz with Docker.

## Prerequisites

1. **Install ZigViz**:
   ```bash
   sudo ../deploy/install.sh
   ```

2. **Configure Docker Runtime**:
   Add to `/etc/docker/daemon.json`:
   ```json
   {
     "runtimes": {
       "zigviz": {
         "path": "/usr/local/bin/zigviz"
       }
     }
   }
   ```

3. **Restart Docker**:
   ```bash
   sudo systemctl restart docker
   ```

4. **Verify Installation**:
   ```bash
   docker run --runtime=zigviz alpine echo "ZigViz works!"
   ```

## Files

| File | Description |
|------|-------------|
| `docker-compose.yaml` | Multi-service example with ZigViz |
| `Dockerfile.secure` | Best practices Dockerfile for ZigViz |
| `README.md` | This file |

## Quick Start

### Single Container

```bash
# Run with ZigViz runtime
docker run --runtime=zigviz alpine sh -c "echo Hello from ZigViz"

# Run with security profile
docker run --runtime=zigviz \
  --label zigviz.profile=ci-runner \
  --label zigviz.audit=true \
  node:20-alpine npm test
```

### Docker Compose

```bash
# Start all services
docker-compose up -d

# View logs
docker-compose logs -f web

# Run CI job
docker-compose --profile ci up ci-runner

# Stop all services
docker-compose down
```

## Security Labels

You can configure ZigViz behavior using Docker labels:

| Label | Description | Default |
|-------|-------------|---------|
| `zigviz.profile` | Security profile name | `default` |
| `zigviz.audit` | Enable audit logging | `false` |
| `zigviz.broker-timeout` | Broker timeout (ms) | `1000` |
| `zigviz.strict-mode` | Fail on unknown syscalls | `false` |

### Example

```bash
docker run --runtime=zigviz \
  --label zigviz.profile=hostile-tenant \
  --label zigviz.audit=true \
  --label zigviz.strict-mode=true \
  untrusted-image
```

## Building Secure Images

Use `Dockerfile.secure` as a template for building secure images:

```bash
# Build secure image
docker build -f Dockerfile.secure -t myapp:secure .

# Run with ZigViz
docker run --runtime=zigviz myapp:secure
```

### Best Practices

1. **Use minimal base images**: distroless, alpine, scratch
2. **Run as non-root**: Always specify USER
3. **Read-only filesystem**: Use `--read-only` flag
4. **Drop capabilities**: Use `--cap-drop=ALL`
5. **No shell**: Remove /bin/sh in production images

## Troubleshooting

### "Runtime not found"

```bash
# Check Docker configuration
cat /etc/docker/daemon.json

# Verify zigviz binary
ls -la /usr/local/bin/zigviz

# Restart Docker
sudo systemctl restart docker
```

### "Permission denied"

```bash
# Check ZigViz permissions
sudo zigviz validate

# Run with verbose logging
docker run --runtime=zigviz \
  --label zigviz.audit=true \
  alpine sh
```

### View Audit Logs

```bash
# Check ZigViz logs
cat /var/log/zigviz/*.log

# Docker logs
docker logs <container-id>
```

## See Also

- [Deployment Guide](../../deploy/README.md)
- [Kubernetes Examples](../kubernetes/)
- [Security Profiles](../profiles/)
