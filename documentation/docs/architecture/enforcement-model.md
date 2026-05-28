# Enforcement Model

ZViz applies five layers of kernel-level enforcement before `execve`-ing the
workload. The order matters: each layer's setup must complete while the
previous layer still permits it.

## The five layers, in application order

1. **Namespaces** (`user`, `pid`, `mount`, `ipc`, `uts`; `net` optional). The
   parent forks; the child does `unshare(CLONE_NEWUSER | ...)` before the
   parent writes the uid/gid maps and signals the child to proceed. Because
   `CLONE_NEWPID` puts only *future* children into the new pid namespace, the
   child then forks once more so the workload itself becomes pid 1 of that
   namespace.
2. **Capability drop** via `PR_CAPBSET_DROP` for every capability in the
   process's bounding set, then `PR_SET_NO_NEW_PRIVS` so the drop is
   irrevocable across `execve`. The default profile drops all 41 capabilities;
   `CAP_NET_RAW`, `CAP_SYS_ADMIN`, etc. are unreachable for the workload.
3. **Landlock** (stackable LSM, Linux ≥ 5.13). Build a ruleset with
   `LANDLOCK_ACCESS_FS_READ_WRITE` on the container's rootfs (or
   `READ_EXEC` if the OCI `root.readonly: true` was set) and
   `READ_WRITE` on `/tmp`, then commit with `landlock_restrict_self`. The
   restriction is irrevocable for the calling task and its descendants.
4. **seccomp-BPF**. Load the compiled filter (a single classic-BPF program
   of ~168 instructions: 130 allow checks, 24 deny checks, the inline
   socket-domain filter, plus the action returns). The kernel evaluates the
   program on every syscall.
5. **cgroups v2**. The parent attached the child to a per-container cgroup
   before the child reached this stage; the cgroup limits memory and the
   number of processes (default `pids.max=512`, `memory.max=2G`).

## Filesystem setup inside the mount namespace

In addition to the security layers, the executor sets up the container's
filesystem inside its mount namespace, *before* `pivot_root`:

- Bind-mounts the rootfs onto itself (a prerequisite for `pivot_root`).
- Mounts a private `tmpfs` at `<rootfs>/dev` (mode 755) and bind-mounts the
  host's `/dev/null`, `/dev/zero`, `/dev/full`, `/dev/random`, `/dev/urandom`,
  `/dev/tty` onto empty target files inside it. After `pivot_root`, it adds
  the standard `/dev/std{in,out,err}` and `/dev/fd` symlinks to
  `/proc/self/fd`.
- Mounts `procfs` at `<rootfs>/proc` (`nosuid,nodev,noexec`) and `sysfs` at
  `<rootfs>/sys` (`nosuid,nodev,noexec,ro`). Both mounts have to happen
  pre-pivot because an unprivileged user namespace's procfs check requires
  ancestor-procfs visibility, which `pivot_root` removes.
- Applies the OCI `mounts[]` array: `bind`/`rbind` with the
  Linux-specific `MS_BIND` followed by an `MS_REMOUNT|MS_RDONLY` when `ro`
  is requested (the kernel ignores `MS_RDONLY` on the initial bind syscall;
  the remount is mandatory). `tmpfs`/`proc`/`sysfs` typed mounts go through
  one syscall each. Unknown options are logged and skipped.

## Filter size

The current default container profile produces a 168-instruction filter:
130 allow + 24 deny + 5 socket-domain check + 3 load + 4 action returns +
2 architecture check. That fits comfortably under the kernel's 4096-instruction
BPF limit.

## Multi-architecture support

The seccomp filter generator is architecture-dispatched via an `Arch` enum
that emits the matching `AUDIT_ARCH_*` constant at filter-build time. The
project cross-compiles cleanly for `aarch64-linux-musl`. The syscall *number*
tables in `src/schema/schema.zig` are currently x86\_64-only; populating them
for aarch64 (which follows the asm-generic numbering) is the remaining work
for a true aarch64 deployment.

## Why this ordering

- Landlock must precede seccomp so the `landlock_*` syscalls themselves are
  not blocked.
- Capabilities drop before seccomp so a compromised setup path cannot
  re-acquire privilege.
- Cgroup attachment happens in the parent before the child reaches its
  policy-application phase, so memory pressure during setup is bounded.
