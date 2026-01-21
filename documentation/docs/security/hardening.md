# Hardening Guide

Secure your ZViz deployment.

## Kernel Hardening

```bash
# /etc/sysctl.conf
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
```

## Host Hardening

- Keep kernel updated
- Enable AppArmor/SELinux
- Use firewall

## Profile Hardening

- Use minimal profile
- Enable audit logging
- Review denials regularly

See [Security Policy](index.md).
