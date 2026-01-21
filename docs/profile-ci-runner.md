# CI Runner Profile (Concrete)

This document defines a concrete CI runner profile using the ZViz schema. It is intended for build and test workloads with strict filesystem isolation and controlled egress.

## Intent

- Allow standard build toolchains and test runners.
- Prevent privilege escalation and kernel attack primitives.
- Restrict filesystem access to the workspace and temp directories.
- Restrict network egress to internal CIDRs or a proxy.

## Assumptions

- AppArmor or SELinux is available on the host.
- seccomp user notification is enabled.
- Network policy enforcement is available (iptables/nftables or eBPF).

## Profile

```yaml
name: zviz-ci
version: 0.1
mode: high-density

description: CI runner profile for build and test workloads.

requirements:
  lsm: required
  seccomp_notify: required
  network_policy: required

syscalls:
  allow:
    - read
    - write
    - close
    - fstat
    - newfstatat
    - lseek
    - pread64
    - pwrite64
    - mmap
    - mprotect
    - munmap
    - brk
    - madvise
    - rt_sigaction
    - rt_sigprocmask
    - sigaltstack
    - futex
    - nanosleep
    - clock_gettime
    - getpid
    - gettid
    - getuid
    - getgid
    - geteuid
    - getegid
    - getcwd
    - getdents64
    - arch_prctl
    - set_tid_address
    - prlimit64
    - rseq
    - sched_yield
    - epoll_create1
    - epoll_ctl
    - epoll_wait
    - pipe2
    - dup
    - dup2
    - dup3
    - eventfd2
    - signalfd4
    - timerfd_create
    - timerfd_settime
  deny:
    - bpf
    - kexec_load
    - perf_event_open
    - keyctl
    - userfaultfd
    - ptrace
    - mount
    - umount2
    - pivot_root
    - swapon
    - swapoff
    - reboot
    - init_module
    - finit_module
    - delete_module
    - unshare
    - setns
    - iopl
    - ioperm
    - create_module
    - syslog
    - add_key
    - request_key
    - open_by_handle_at
    - name_to_handle_at
    - kcmp
  broker:
    - openat
    - openat2
    - ioctl
    - socket
    - socketpair
    - clone
    - clone3
    - execve
    - execveat
    - prctl

ioctl:
  allowlists:
    - subsystem: tty
      commands:
        - TIOCGWINSZ
        - TIOCSPGRP
        - TIOCGPGRP
    - subsystem: fs
      commands:
        - FIONREAD
        - FIONBIO

filesystem:
  rootfs: readonly
  writable:
    - /work
    - /tmp
  tmpfs:
    - /tmp

lsm:
  type: apparmor
  profile: zviz-ci

network:
  mode: allow-cidr
  allow_cidrs:
    - 10.0.0.0/8
    - 172.16.0.0/12
  allow_domains: []

resources:
  cpu_max: "2"
  memory_max: "4G"
  pids_max: 512

broker:
  max_inflight: 256
  timeout_ms: 200

audit:
  level: full
```

## Broker constraints for CI

- `openat2` is required; `openat` is allowed only when `openat2` is unavailable on the host.
- `clone` and `clone3` must be constrained to thread-like flags; new namespaces are denied.
- `execve` is allowed only from paths permitted by the LSM profile.
- `socket` and `socketpair` are limited to allowed domains (for example, `AF_INET`, `AF_UNIX`).

## Notes

- The syscall list is a starting point and will evolve based on real workload traces.
- Some build tools may require additional syscalls (for example, `statx` or `getrandom`). These should be added via profile updates, not ad-hoc runtime changes.

## Related documents

- `docs/profile-schema.md` — Full schema reference with all field options
- `docs/policy-compiler.md` — How this profile is compiled to enforcement artifacts
- `docs/broker-design.md` — Details on brokered syscall mediation
