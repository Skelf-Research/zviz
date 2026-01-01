# Policy Profiles

Profiles define the enforcement policy for a workload. Each profile compiles to concrete artifacts used by the runtime.

## Outputs per profile

- Seccomp BPF program (allow/deny/broker tiers).
- LSM policy (AppArmor/SELinux or Landlock rules).
- Network egress/ingress rules for the namespace (CIDR allowlists).
- Broker rule tables (syscall- and argument-level allowlists).

## Profile selection

Profiles are intended to be explicit and deterministic. The default packaging model is separate binaries per profile to minimize surface area. A multi-profile binary is optional for operational convenience.

- Default: separate binaries per profile (smallest surface area).
- Optional: a single binary with built-in profiles and a strict selection flag.

Profile selection is host-controlled and not configurable from inside the container.

## Example: CI runner profile (high level)

- Allow: `read`, `write`, `futex`, `clock_gettime`, `epoll_*`, `mmap`, and other safe high-frequency syscalls.
- Deny: `bpf`, `kexec_load`, `perf_event_open`, raw sockets, module loading.
- Broker: `openat`/`openat2`, `ioctl`, `socket`, `clone`/`clone3`, `execve`, `prctl`.
- LSM: read-only rootfs, writable workspace subtree only.
- Network: allow outbound TCP/UDP to approved CIDRs; domain allowlists require a DNS-aware policy layer or egress proxy.

For the complete profile definition, see `docs/profile-ci-runner.md`.

## Policy verification

Profiles should ship with:

- Rendered policy artifacts for inspection.
- A machine-readable manifest linking rules to policy intent.
- A small conformance test suite for each profile.

## Related documents

- `docs/profile-schema.md` — Full schema reference for profile definitions
- `docs/profile-ci-runner.md` — Complete CI runner profile example
- `docs/policy-compiler.md` — How profiles are compiled to enforcement artifacts
- `docs/host-requirements.md` — Required host capabilities for profile execution
