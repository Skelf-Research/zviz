# Debugging Guide

Troubleshoot ZViz issues in production.

## Debug Logging

```bash
zviz --log-level debug run ...
```

## Common Issues

### Container Won't Start

1. Check containerd logs: `journalctl -u containerd`
2. Check ZViz logs: `/var/log/zviz/`
3. Verify profile: `zviz compile --validate`

### Performance Problems

1. Check metrics: `zviz metrics`
2. Review broker latency
3. Check for excessive brokered syscalls

## See Also

- [Monitoring](monitoring.md)
- [Troubleshooting](../user-guide/troubleshooting.md)
