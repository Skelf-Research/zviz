# Error Codes

ZigViz error codes and meanings.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid arguments |
| 126 | Command not executable |
| 127 | Command not found |

## Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `PermissionDenied` | Insufficient privileges | Run as root |
| `SeccompNotAvailable` | Kernel feature missing | Update kernel |
| `ProfileNotFound` | Profile doesn't exist | Check path |
