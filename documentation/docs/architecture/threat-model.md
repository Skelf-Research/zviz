# Threat Model

ZigViz's security model and what it protects against.

## Trust Boundaries

- **Untrusted**: Container workloads
- **Trusted**: ZigViz broker, Host kernel

## In Scope

- Container escape via syscalls
- Resource exhaustion
- Network attacks
- Filesystem access

## Out of Scope

- Kernel vulnerabilities
- Hardware attacks
- Supply chain attacks

See [Security Policy](../security/index.md) for details.
