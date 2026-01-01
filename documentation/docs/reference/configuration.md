# Configuration Reference

ZigViz configuration options.

## Config File

`/etc/zigviz/config.yaml`:

```yaml
runtime:
  state_dir: /var/lib/zigviz
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
| `ZIGVIZ_LOG_LEVEL` | Log level |
| `ZIGVIZ_STATE_DIR` | State directory |
| `ZIGVIZ_CONFIG` | Config file path |
