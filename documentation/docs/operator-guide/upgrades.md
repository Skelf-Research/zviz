# Upgrade Guide

Safely upgrade ZigViz in production.

## Upgrade Process

1. Review changelog
2. Test in staging
3. Rolling upgrade nodes
4. Verify functionality

## Version Compatibility

| From | To | Notes |
|------|-----|-------|
| 0.1.x | 0.1.y | Compatible |

## Rollback

```bash
# Restore previous version
cp /usr/local/bin/zigviz.bak /usr/local/bin/zigviz
systemctl restart containerd
```
