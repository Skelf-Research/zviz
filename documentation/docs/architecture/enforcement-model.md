# Enforcement Model

ZigViz uses a five-layer enforcement model for defense in depth.

## Layer Overview

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| A | Namespaces + Capabilities | Resource isolation |
| B | Seccomp-BPF + Broker | Syscall mediation |
| C | LSM (AppArmor/SELinux/Landlock) | Object access |
| D | cgroups v2 | Resource limits |
| E | Network namespace + nftables | Network policy |

## Layer Details

See [Architecture Overview](index.md) for full details.
