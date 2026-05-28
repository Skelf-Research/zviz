# Your First Container

This tutorial walks you through running a real workload under ZViz, end-to-end.

## Prerequisites

- ZViz built from source: `zig build -Doptimize=ReleaseSafe`. Resulting binary at `./zig-out/bin/zviz`.
- Docker (we use `docker export` to build the rootfs; once you have a rootfs, ZViz never talks to Docker again).
- On Ubuntu 24.04+ (or any kernel with `kernel.apparmor_restrict_unprivileged_userns=1`), one of:
   - Install the bundled AppArmor profile once: `sudo install -m 0644 packaging/apparmor/zviz /etc/apparmor.d/zviz && sudo apparmor_parser -r /etc/apparmor.d/zviz`.
   - Or temporarily disable the restriction: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.
  Without one of these, `pivot_root` fails inside the unprivileged user namespace and ZViz falls back to chdir-only filesystem isolation, which the OCI spec does not consider a real chroot.
- Rootless mode is the default. No `sudo` required for `zviz run` itself.

## 1. Build a bundle

A bundle is a directory with two things: the container's `rootfs/` and an OCI `config.json` describing the workload. We will build one for `redis:alpine`.

```bash
mkdir -p ~/zviz-redis/rootfs
docker create --name extract redis:alpine
docker export extract | tar -C ~/zviz-redis/rootfs -xf -
docker rm extract
```

`docker export` flattens the image's filesystem into a tar; we untar it into `rootfs/`. This is a one-time per-image cost. The Docker daemon is not involved in any later step.

## 2. Write the config

The minimum-viable `config.json` says which command to run, which user to run it as, and which Linux namespaces to unshare. Save this to `~/zviz-redis/config.json`:

```json
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": false,
    "user": {"uid": 0, "gid": 0},
    "args": ["/usr/local/bin/redis-server",
             "--save", "", "--appendonly", "no",
             "--protected-mode", "no",
             "--port", "6379", "--bind", "127.0.0.1"],
    "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "cwd": "/"
  },
  "root": {"path": "rootfs", "readonly": false},
  "hostname": "my-redis",
  "linux": {
    "namespaces": [
      {"type": "pid"},
      {"type": "mount"},
      {"type": "ipc"},
      {"type": "uts"}
    ]
  }
}
```

You do **not** need a `mounts[]` entry for `/proc`, `/sys`, or `/dev` — the runtime auto-mounts those (procfs at `/proc`, sysfs read-only at `/sys`, a private tmpfs at `/dev` populated with the standard char devices and `std{in,out,err}` symlinks).

You **can** add a `mounts[]` entry to bind-mount host data in:

```json
"mounts": [
  {"destination": "/data", "source": "/srv/redis-state", "type": "bind", "options": ["rw", "rbind"]}
]
```

For read-only data use `"options": ["ro", "rbind"]` — the runtime emits the kernel's mandatory second `MS_REMOUNT|MS_RDONLY` syscall for you (Linux silently ignores `MS_RDONLY` on the initial bind mount; missing the remount is the most common "I asked for ro and got rw" foot-gun).

## 3. Run it

```bash
./zig-out/bin/zviz run my-redis ~/zviz-redis
```

The first time, the verbose logs make the layer ordering visible:

```
[INFO] Writing ID maps for pid <host_pid> (uid=<your_uid>, gid=<your_gid>)
[INFO] Wrote setgroups deny
[INFO] Wrote uid_map: 0 <your_uid> 1
[INFO] Wrote gid_map: 0 <your_gid> 1
[INFO] Dropping capabilities, keeping 0
[INFO] Capabilities dropped
[INFO] Applying Landlock rules (2 paths)
[INFO] Landlock ruleset enforced
[INFO] Loading seccomp filter with 168 instructions
[INFO] Seccomp filter loaded successfully
[INFO] Container started with PID <host_pid>
1:M 28 May 2026 11:56:44.626 * monotonic clock: POSIX clock_gettime
1:M 28 May 2026 11:56:44.627 * Running mode=standalone, port=6379.
1:M 28 May 2026 11:56:44.627 * Ready to accept connections tcp
```

In another terminal:

```bash
redis-cli -h 127.0.0.1 -p 6379 ping
# PONG
```

To stop the container, send `^C` to the foreground `zviz run` (or, from elsewhere, `kill -INT <pid>`). The runtime tears down the cgroup, removes the per-container mount namespace (so the tmpfs at `/dev` and the bind mounts disappear), and exits with the workload's exit code.

## What you just exercised

The container is rootless (your invoking user mapped to uid 0 inside its own user namespace), pid 1 of a fresh pid namespace, runs under a 168-instruction seccomp filter that blocks `ptrace`, `mount`, `unshare`, `bpf`, `io_uring_setup`/`enter` and 19 other dangerous syscalls, and has Landlock active over its rootfs. The redis-server binary is dynamically linked against musl; the dynamic loader resolves it normally because the rootfs is the real `redis:alpine` filesystem under `pivot_root`.

## Next steps

- [`comparison.md`](../architecture/comparison.md) — how the runtime stacks up against runc and gVisor on syscall latency, cold start, memory, and redis throughput.
- [`enforcement-model.md`](../architecture/enforcement-model.md) — the full layer-by-layer description of what each enforcement step does and why the order matters.
- [`threat-model.md`](../architecture/threat-model.md) — the trust boundary and what is in/out of scope.
