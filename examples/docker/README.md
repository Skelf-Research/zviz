# Docker Examples for ZViz

This directory contains examples for using ZViz with Docker.

## Prerequisites

1. **Install ZViz**:
   ```bash
   sudo ../deploy/install.sh
   ```

2. **Configure Docker Runtime**:
   Add to `/etc/docker/daemon.json`:
   ```json
   {
     "runtimes": {
       "zviz": {
         "path": "/usr/local/bin/zviz"
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
   docker run --runtime=zviz alpine echo "ZViz works!"
   ```

## Files

| File | Description |
|------|-------------|
| `docker-compose.yaml` | Multi-service example with ZViz |
| `Dockerfile.secure` | Best practices Dockerfile for ZViz |
| `README.md` | This file |

## Quick Start

### Single Container

```bash
# Run with ZViz runtime
docker run --runtime=zviz alpine sh -c "echo Hello from ZViz"

# Run with security profile
docker run --runtime=zviz \
  --label zviz.profile=ci-runner \
  --label zviz.audit=true \
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

You can configure ZViz behavior using Docker labels:

| Label | Description | Default |
|-------|-------------|---------|
| `zviz.profile` | Security profile name | `default` |
| `zviz.audit` | Enable audit logging | `false` |
| `zviz.broker-timeout` | Broker timeout (ms) | `1000` |
| `zviz.strict-mode` | Fail on unknown syscalls | `false` |

### Example

```bash
docker run --runtime=zviz \
  --label zviz.profile=hostile-tenant \
  --label zviz.audit=true \
  --label zviz.strict-mode=true \
  untrusted-image
```

## Building Secure Images

Use `Dockerfile.secure` as a template for building secure images:

```bash
# Build secure image
docker build -f Dockerfile.secure -t myapp:secure .

# Run with ZViz
docker run --runtime=zviz myapp:secure
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

# Verify zviz binary
ls -la /usr/local/bin/zviz

# Restart Docker
sudo systemctl restart docker
```

### "Permission denied"

```bash
# Check ZViz permissions
sudo zviz validate

# Run with verbose logging
docker run --runtime=zviz \
  --label zviz.audit=true \
  alpine sh
```

### View Audit Logs

```bash
# Check ZViz logs
cat /var/log/zviz/*.log

# Docker logs
docker logs <container-id>
```

## See Also

- [Deployment Guide](../../deploy/README.md)
- [Kubernetes Examples](../kubernetes/)
- [Security Profiles](../profiles/)
