# Security Policy

This document outlines ZigViz's security policies, practices, and how to report vulnerabilities.

## Security Model

ZigViz provides defense-in-depth through five enforcement layers:

| Layer | Mechanism | Protection |
|-------|-----------|------------|
| A | Namespaces + Capabilities | Resource isolation |
| B | Seccomp-BPF + Broker | Syscall mediation |
| C | AppArmor/SELinux/Landlock | Object-level access |
| D | cgroups v2 | Resource limits |
| E | Network namespace + nftables | Network isolation |

### Trust Boundaries

```
┌─────────────────────────────────────────────────┐
│                  Untrusted                       │
│  ┌───────────────────────────────────────────┐  │
│  │              Container                     │  │
│  │  ┌─────────────────────────────────────┐  │  │
│  │  │         Application Code             │  │  │
│  │  └─────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────┘  │
├─────────────────────────────────────────────────┤
│                   Trusted                        │
│  ┌───────────────────────────────────────────┐  │
│  │              ZigViz Broker                 │  │
│  └───────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────┐  │
│  │              Host Kernel                   │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## Threat Model

### In Scope

ZigViz protects against:

- **Container escape** via syscall exploitation
- **Resource exhaustion** attacks (fork bombs, memory exhaustion)
- **Network attacks** from containers (lateral movement)
- **Filesystem attacks** (reading sensitive files, writing to system paths)
- **Capability escalation** within the container

### Out of Scope

ZigViz does NOT protect against:

- **Kernel vulnerabilities** — The host kernel is trusted
- **Hardware attacks** — Side-channel, speculative execution
- **Supply chain attacks** — Malicious container images
- **Social engineering** — Misconfigurated policies

!!! warning "Hostile Tenants"
    For environments with hostile tenants who may attempt kernel exploits, deploy ZigViz inside a microVM boundary (Firecracker, Cloud Hypervisor).

## Supported Versions

| Version | Support Status |
|---------|----------------|
| 0.1.x | Active development |
| < 0.1.0 | Not supported |

## Security Updates

Security updates are released as:

1. **Patch releases** (0.1.x) for vulnerabilities
2. **Security advisories** in the GitHub repository
3. **CVE assignments** for significant vulnerabilities

### Update Policy

- **Critical**: Patch within 24 hours
- **High**: Patch within 7 days
- **Medium**: Patch within 30 days
- **Low**: Patch in next regular release

## Reporting Vulnerabilities

### Private Disclosure

**DO NOT** report security vulnerabilities through public GitHub issues.

Instead, please email: **security@zigviz.io**

Include:

1. Description of the vulnerability
2. Steps to reproduce
3. Potential impact
4. Suggested fix (if any)

### PGP Key

```
-----BEGIN PGP PUBLIC KEY BLOCK-----
[PGP key would go here]
-----END PGP PUBLIC KEY BLOCK-----
```

### Bug Bounty

We currently do not offer a formal bug bounty program, but we do provide:

- Public acknowledgment (with permission)
- CVE credit
- ZigViz swag for significant findings

### Response Timeline

| Step | Timeline |
|------|----------|
| Acknowledgment | 24 hours |
| Initial assessment | 72 hours |
| Fix development | 7-30 days (severity dependent) |
| Disclosure | 90 days or upon fix release |

## Security Best Practices

### For Users

1. **Use restrictive profiles** — Start minimal, add permissions as needed
2. **Enable audit logging** — Monitor for suspicious activity
3. **Keep ZigViz updated** — Apply security patches promptly
4. **Validate container images** — Scan for vulnerabilities
5. **Use read-only rootfs** — Reduce attack surface

### For Operators

1. **Network segmentation** — Isolate ZigViz nodes
2. **Least privilege** — Run ZigViz with minimal permissions
3. **Centralized logging** — Aggregate and analyze audit logs
4. **Regular security scans** — Audit configurations
5. **Incident response plan** — Prepare for security events

### For Contributors

1. **Security-first design** — Consider security implications
2. **Code review** — All changes require review
3. **Fuzz testing** — Run fuzzers on new code
4. **Dependency auditing** — Monitor for vulnerable dependencies
5. **Secure defaults** — Default to most secure option

## Security Audits

### Internal Audits

- Continuous fuzzing via OSS-Fuzz
- Regular security review of changes
- Automated vulnerability scanning

### External Audits

[To be scheduled]

We plan to conduct external security audits before major releases.

## Compliance

ZigViz supports compliance requirements:

| Standard | Support |
|----------|---------|
| SOC 2 | Audit logging, access controls |
| PCI-DSS | Network isolation, encryption |
| HIPAA | Data isolation, logging |
| GDPR | Data containment |

## Security Hardening

See the [Hardening Guide](hardening.md) for:

- Kernel configuration
- Host hardening
- Network security
- AppArmor/SELinux policies
- Audit configuration

## Known Limitations

1. **Kernel trust** — ZigViz trusts the host kernel
2. **Clock access** — Containers can read system time
3. **CPU timing** — No protection against timing attacks
4. **Memory limits** — OOM killer may affect host

## Security Contacts

- **Security Team**: security@zigviz.io
- **Maintainers**: maintainers@zigviz.io
- **General**: hello@zigviz.io

## See Also

- [Reporting Vulnerabilities](reporting.md)
- [Security Advisories](advisories.md)
- [Hardening Guide](hardening.md)
- [Threat Model](../architecture/threat-model.md)
