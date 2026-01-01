# Debugging Guide

Troubleshoot ZigViz issues in production.

## Debug Logging

```bash
zigviz --log-level debug run ...
```

## Common Issues

### Container Won't Start

1. Check containerd logs: `journalctl -u containerd`
2. Check ZigViz logs: `/var/log/zigviz/`
3. Verify profile: `zigviz compile --validate`

### Performance Problems

1. Check metrics: `zigviz metrics`
2. Review broker latency
3. Check for excessive brokered syscalls

## See Also

- [Monitoring](monitoring.md)
- [Troubleshooting](../user-guide/troubleshooting.md)
