# Configuration Reference

ZViz configuration options.

## Config File

`/etc/zviz/config.yaml`:

```yaml
runtime:
  state_dir: /var/lib/zviz
  rootless: false

logging:
  level: info
  format: json

broker:
  max_inflight: 256
  timeout_ms: 1000

security:
  require_seccomp: true
  no_new_privs: true
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `ZVIZ_LOG_LEVEL` | Log level |
| `ZVIZ_STATE_DIR` | State directory |
| `ZVIZ_CONFIG` | Config file path |
