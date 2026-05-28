# Threat Model

ZViz isolates a container workload with five layers of kernel-level enforcement.
This page states the trust boundary explicitly so users can decide whether the
guarantees match their deployment.

## Trusted computing base

| Component | Why it is trusted |
|---|---|
| Host kernel | All enforcement primitives run in it; a kernel CVE that escapes seccomp/Landlock/namespace isolation defeats every container runtime equally. ZViz reduces but does not eliminate the host kernel surface reachable from inside a container (`docs/architecture/comparison.md` for the measured number). |
| ZViz parent supervisor process | Sets up the cgroup, writes the user namespace's uid/gid maps, applies Landlock and seccomp in the child before `execve`. Compromise of the parent before the child enters the sandbox is fatal to isolation. |
| In-kernel BPF interpreter | Evaluates the seccomp filter; assumed correct. |
| The broker process (when a profile configures one) | Mediates argument-sensitive syscalls. The default profile ships with an *empty* broker set, so most deployments do not need to trust a userspace broker at all. |

## Attacker capabilities

The container workload is untrusted. The attacker model is:

- Arbitrary code execution as container-root inside the user namespace (mapped to the invoking user on the host).
- May issue any syscall, open any path the policy permits, and deliberately probe for escape primitives.
- Cannot inject code into the parent supervisor or alter the BPF program after `execve` (NO_NEW_PRIVS plus the irrevocable `landlock_restrict_self` enforce this).

We do not assume the workload is benign or buggy. The security evaluation in
the accompanying paper runs real escape payloads inside the runtime and
records the kernel-level outcome.

## In scope

- Container escape via the syscall interface.
- Capability escalation inside the namespace.
- Filesystem-access policy violation (paths not granted by Landlock or by an OCI `mounts[]` entry).
- Network policy violation (socket-domain filtering blocks `AF_PACKET`/`AF_NETLINK`/etc. by default).
- Resource exhaustion of the host (cgroup memory and pids limits).

## Out of scope

The same boundary gVisor draws for its own model:

- Hardware side channels and firmware attacks.
- Supply-chain attacks on the runtime itself (a malicious ZViz binary is not a container-escape problem; verify the build).
- Hypervisor escape (irrelevant; ZViz does not run a hypervisor).
- Memory-primitive kernel CVEs that work through permitted syscalls (Dirty COW, Dirty Pipe). A syscall filter cannot block these; defending against them is the host kernel's job.

We do *not* assume the host kernel is bug-free. Instead the paper measures how
much of it each runtime exposes, rather than asserting that the residual
surface is safe.

## What changes if you opt into the broker

Enabling broker-mediated syscalls (e.g. path-restricted `openat`) adds the
broker process to the TCB. Because `SECCOMP_RET_USER_NOTIF` dereferences
pointer arguments in the target's address space, naive brokers are vulnerable
to a time-of-check/time-of-use race. ZViz validates the notification id with
`SECCOMP_IOCTL_NOTIF_ID_VALID` before acting; profiles that ship a broker
should review this invariant.
