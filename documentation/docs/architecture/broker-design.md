# Broker Design

The ZigViz broker mediates syscalls that require argument inspection.

## Overview

- Uses `SECCOMP_RET_USER_NOTIF` for syscall interception
- Validates arguments against profile rules
- Returns results or performs operations on behalf of container

## Brokered Syscalls

| Syscall | Mediation |
|---------|-----------|
| openat | Path validation |
| socket | Domain/type filter |
| clone | Flag validation |
| ioctl | Command filter |
| execve | Path validation |

See [Architecture Overview](index.md) for more details.
