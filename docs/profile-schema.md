# Profile Schema

This document defines the logical schema for ZigViz profiles. Profiles are the input to the policy compiler.

## Schema (YAML)

```yaml
name: zigviz-ci
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
    - io_pgetevents
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
  profile: zigviz-ci

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

## Notes

- `allow_domains` requires a DNS-aware egress proxy and is not enforced by CIDR rules alone.
- `clone` and `clone3` should be constrained to thread-like flags; new namespaces must be denied.
- `execve` and `execveat` can be brokered when strict binary allowlists are required.
- `requirements` let the compiler fail closed when host capabilities are missing.
