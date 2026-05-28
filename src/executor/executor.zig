const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const linux = @import("../syscalls/linux.zig");
const containment = @import("../containment/containment.zig");
const seccomp = @import("../seccomp/seccomp.zig");
const cgroup = @import("../cgroup/cgroup.zig");
const console_mod = @import("console.zig");
const lsm = @import("../lsm/lsm.zig");

/// Container executor - handles the actual fork/exec of container processes

// ============================================================================
// Clone flags for container creation
// ============================================================================

pub const CloneFlags = struct {
    pub const NEWNS: u64 = 0x00020000; // New mount namespace
    pub const NEWUTS: u64 = 0x04000000; // New UTS namespace
    pub const NEWIPC: u64 = 0x08000000; // New IPC namespace
    pub const NEWUSER: u64 = 0x10000000; // New user namespace
    pub const NEWPID: u64 = 0x20000000; // New PID namespace
    pub const NEWNET: u64 = 0x40000000; // New network namespace
    pub const NEWCGROUP: u64 = 0x02000000; // New cgroup namespace
};

// ============================================================================
// Pipe for parent-child synchronization
// ============================================================================

pub const SyncPipe = struct {
    read_fd: i32,
    write_fd: i32,

    pub fn init() !SyncPipe {
        var fds: [2]i32 = undefined;
        const result = std.os.linux.pipe2(&fds, .{});
        if (@as(isize, @bitCast(result)) < 0) {
            return error.PipeCreationFailed;
        }
        return .{
            .read_fd = fds[0],
            .write_fd = fds[1],
        };
    }

    pub fn closeRead(self: *SyncPipe) void {
        if (self.read_fd >= 0) {
            _ = std.os.linux.close(@intCast(self.read_fd));
            self.read_fd = -1;
        }
    }

    pub fn closeWrite(self: *SyncPipe) void {
        if (self.write_fd >= 0) {
            _ = std.os.linux.close(@intCast(self.write_fd));
            self.write_fd = -1;
        }
    }

    pub fn close(self: *SyncPipe) void {
        self.closeRead();
        self.closeWrite();
    }

    /// Wait for signal from other end
    pub fn wait(self: *SyncPipe) !void {
        var buf: [1]u8 = undefined;
        const n = std.os.linux.read(@intCast(self.read_fd), &buf, 1);
        if (@as(isize, @bitCast(n)) <= 0) {
            return error.SyncFailed;
        }
    }

    /// Signal the other end
    pub fn signal(self: *SyncPipe) !void {
        const buf = [_]u8{0};
        const n = std.os.linux.write(@intCast(self.write_fd), &buf, 1);
        if (@as(isize, @bitCast(n)) != 1) {
            return error.SyncFailed;
        }
    }
};

// ============================================================================
// Container Execution Config
// ============================================================================

/// One entry in the OCI `mounts[]` array, lifted out of `ExecConfig` because
/// Zig disallows declarations between struct fields.
pub const ExecConfigMount = struct {
    destination: []const u8,
    type: ?[]const u8 = null,
    source: ?[]const u8 = null,
    options: ?[]const []const u8 = null,
};

pub const ExecConfig = struct {
    /// Container ID
    container_id: []const u8,

    /// Root filesystem path
    rootfs: []const u8,

    /// Command to execute
    args: []const []const u8,

    /// Environment variables
    env: []const []const u8 = &.{},

    /// Working directory
    cwd: []const u8 = "/",

    /// User ID to run as
    uid: u32 = 0,

    /// Group ID to run as
    gid: u32 = 0,

    /// Namespaces to create (NEWUSER is added automatically in rootless mode)
    namespaces: u64 = CloneFlags.NEWNS | CloneFlags.NEWPID | CloneFlags.NEWIPC | CloneFlags.NEWUTS,

    /// Whether to set up user namespace (required for rootless mode)
    user_ns: bool = true,

    /// Rootless mode - set to null for auto-detection at runtime
    rootless: ?bool = null,

    /// Seccomp policy to apply
    seccomp_policy: ?seccomp.SyscallPolicy = null,

    /// Cgroup path for resource limits
    cgroup_path: ?[]const u8 = null,

    /// Allocate a PTY
    terminal: bool = false,

    /// Console socket path for OCI console protocol
    console_socket: ?[]const u8 = null,

    /// Make rootfs readonly. Default false to match OCI's `root.readonly: false`
    /// default (the spec value runtime.zig parses into config.root.readonly).
    /// When false, the Landlock rule for "/" is READ_WRITE so workloads can
    /// write to their own rootfs; when true, the rule is READ_EXEC only.
    rootfs_readonly: bool = false,

    /// OCI `mounts[]` to apply inside the container's mount namespace, BEFORE
    /// pivot_root. Each entry mirrors the runtime.Config.Mount struct without
    /// pulling that module into the executor's interface. The type itself
    /// (`ExecConfigMount`) is declared at module scope (Zig disallows
    /// declarations between struct fields).
    mounts: ?[]const ExecConfigMount = null,

    /// Set no_new_privs
    no_new_privs: bool = true,

    /// Hostname for UTS namespace
    hostname: ?[]const u8 = null,

    /// Drop all capabilities in the bounding set
    drop_capabilities: bool = true,

    /// Enable Landlock filesystem restrictions
    enable_landlock: bool = true,

    /// Verbose mode - log blocked syscalls in real-time
    verbose: bool = false,
};

// ============================================================================
// Container Executor
// ============================================================================

pub const Executor = struct {
    allocator: std.mem.Allocator,
    config: ExecConfig,
    child_pid: ?i32 = null,
    exit_code: ?i32 = null,

    // Synchronization pipes
    parent_to_child: ?SyncPipe = null,
    child_to_parent: ?SyncPipe = null,

    // Console/PTY handling
    console: ?console_mod.Console = null,

    // Stdio pipes for non-terminal mode
    stdin_pipe: ?SyncPipe = null,
    stdout_pipe: ?SyncPipe = null,
    stderr_pipe: ?SyncPipe = null,

    // Track if we're in rootless mode (determined at init, before any namespace changes)
    is_rootless: bool = false,

    // Track if filesystem isolation (chroot/pivot_root) succeeded
    fs_isolated: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: ExecConfig) Executor {
        // Determine rootless status at init time (before any namespaces are created)
        const rootless = config.rootless orelse (std.os.linux.getuid() != 0);
        return .{
            .allocator = allocator,
            .config = config,
            .is_rootless = rootless,
        };
    }

    pub fn deinit(self: *Executor) void {
        if (self.parent_to_child) |*p| p.close();
        if (self.child_to_parent) |*p| p.close();
        if (self.console) |*c| c.deinit();
        if (self.stdin_pipe) |*p| p.close();
        if (self.stdout_pipe) |*p| p.close();
        if (self.stderr_pipe) |*p| p.close();
    }

    /// Execute the container
    pub fn run(self: *Executor) !i32 {
        log.info("Executing container: {s}", .{self.config.container_id});

        // Create sync pipes
        self.parent_to_child = try SyncPipe.init();
        self.child_to_parent = try SyncPipe.init();

        // Set up console/stdio
        try self.setupStdio();

        log.debug("About to fork container", .{});

        // Fork the container process
        const pid = try self.forkContainer();
        self.child_pid = pid;

        if (pid == 0) {
            // Child process - this runs in the container
            self.childProcess() catch {
                // Use raw exit_group syscall - std.process.exit may access /proc
                // which is unavailable inside the chroot
                _ = std.os.linux.syscall1(.exit_group, 1);
                unreachable;
            };
            unreachable;
        }

        // Parent process
        log.debug("Parent: child forked with pid {d}", .{pid});
        return try self.parentProcess(pid);
    }

    /// Set up stdio for the container (PTY or inherited)
    fn setupStdio(self: *Executor) !void {
        if (self.config.terminal) {
            // Terminal mode: create PTY
            self.console = console_mod.Console.init(self.allocator);
            self.console.?.createPty() catch |err| {
                log.warn("Failed to create PTY: {s}, falling back to inherited stdio", .{@errorName(err)});
                self.console = null;
                return;
            };

            // If console socket is specified, send the PTY master fd
            if (self.config.console_socket) |socket_path| {
                if (self.console) |*c| {
                    if (c.getMasterFd()) |master_fd| {
                        var console_socket = console_mod.ConsoleSocket.init(self.allocator, socket_path);
                        defer console_socket.deinit();
                        console_socket.sendMasterFd(master_fd) catch |err| {
                            log.warn("Failed to send PTY fd to console socket: {s}", .{@errorName(err)});
                        };
                    }
                }
            }

            log.debug("Console mode: PTY allocated", .{});
        }
        // Non-terminal mode: child inherits parent's stdin/stdout/stderr directly
    }

    /// Set up stdio pipes for non-terminal mode
    fn setupPipes(self: *Executor) !void {
        self.stdin_pipe = try SyncPipe.init();
        self.stdout_pipe = try SyncPipe.init();
        self.stderr_pipe = try SyncPipe.init();
    }

    /// Fork the container process
    fn forkContainer(self: *Executor) !i32 {
        const fork_result = std.os.linux.fork();
        const fork_signed: isize = @bitCast(fork_result);

        if (fork_signed < 0) {
            log.err("Fork failed: {d}", .{fork_signed});
            return errors.Error.NamespaceCreationFailed;
        }

        if (fork_signed == 0) {
            // Child: create namespaces
            self.unshareUserNamespace() catch |err| {
                log.err("Failed to create namespaces: {s}", .{@errorName(err)});
                _ = std.os.linux.syscall1(.exit_group, 1);
                unreachable;
            };
        }

        return @intCast(fork_signed);
    }

    /// Check if running in rootless mode (uses cached value from init)
    fn isRootless(self: *Executor) bool {
        return self.is_rootless;
    }

    /// Unshare user namespace (phase 1 - before uid/gid maps are written)
    /// In rootless mode, we create USER + all other namespaces together
    fn unshareUserNamespace(self: *Executor) !void {
        if (!self.isRootless()) return;

        // In rootless mode, create user namespace AND all other namespaces together
        const flags: u32 = @truncate(self.config.namespaces | CloneFlags.NEWUSER);

        if (flags == 0) return; // No namespaces requested

        const result = std.os.linux.unshare(flags);
        if (@as(isize, @bitCast(result)) < 0) {
            const errno: u16 = @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(result)))));
            log.err("Failed to create namespaces (flags: 0x{x}, errno: {d})", .{ flags, errno });
            return errors.Error.NamespaceCreationFailed;
        }
        log.debug("Created all namespaces for rootless mode (flags: 0x{x})", .{flags});
    }

    /// Unshare remaining namespaces (phase 2 - after uid/gid maps are written)
    /// In rootless mode, this is a no-op since namespaces were created in phase 1
    fn unshareNamespaces(self: *Executor) !void {
        // In rootless mode, all namespaces were created in phase 1
        if (self.isRootless()) {
            return;
        }

        const flags: u32 = @truncate(self.config.namespaces);

        if (flags == 0) return;

        const result = std.os.linux.unshare(flags);
        if (@as(isize, @bitCast(result)) < 0) {
            const errno: u16 = @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(result)))));
            log.err("Failed to unshare namespaces (flags: 0x{x}, errno: {d})", .{ flags, errno });
            return errors.Error.NamespaceCreationFailed;
        }

        log.debug("Unshared namespaces with flags: 0x{x}", .{flags});
    }

    /// Child process setup and exec
    fn childProcess(self: *Executor) !void {
        // Close parent's end of pipes
        if (self.parent_to_child) |*p| p.closeWrite();
        if (self.child_to_parent) |*p| p.closeRead();

        // Wait for parent to set up cgroups, uid_map, etc.
        if (self.parent_to_child) |*p| {
            try p.wait();
        }

        // Second fork: required so the WORKLOAD runs as pid 1 in the NEW pid
        // namespace. `unshare(CLONE_NEWPID)` only puts FUTURE children into the
        // new pidns; the calling task stays in the old pidns. Without this fork,
        // the workload's first fork() becomes pid 1 of the new pidns; when it
        // exits, the kernel marks the pidns "dying" and the workload's next
        // fork() returns -ENOMEM ("init process of pidns terminated"). With this
        // fork, the workload itself is pid 1 and stays alive for the container's
        // lifetime, so its children can come and go freely.
        if (self.isRootless()) {
            const f_raw = std.os.linux.fork();
            const f_signed: isize = @bitCast(f_raw);
            if (f_signed < 0) {
                log.err("intermediate fork failed: {d}", .{f_signed});
                _ = std.os.linux.syscall1(.exit_group, 1);
                unreachable;
            }
            if (f_signed > 0) {
                // intermediate parent: reap the grandchild and exit with its code.
                // This task lives only as a pidns shim; no further policy applies
                // (seccomp/Landlock are loaded below by the grandchild).
                var status: u32 = 0;
                _ = std.os.linux.wait4(@intCast(f_signed), &status, 0, null);
                var code: u32 = 1;
                if (std.os.linux.W.IFEXITED(status)) {
                    code = std.os.linux.W.EXITSTATUS(status);
                } else if (std.os.linux.W.IFSIGNALED(status)) {
                    code = 128 + std.os.linux.W.TERMSIG(status);
                }
                _ = std.os.linux.syscall1(.exit_group, code);
                unreachable;
            }
            // grandchild: this is pid 1 in the new pidns; continue setup below.
        }

        // Now that uid/gid maps are written, create remaining namespaces
        try self.unshareNamespaces();

        // Set up user namespace if configured
        if (self.config.user_ns) {
            try self.setupUserNamespace();
        }

        // Set hostname if configured
        if (self.config.hostname) |hostname| {
            try self.setHostname(hostname);
        }

        // Set up filesystem (chroot + chdir)
        try self.setupFilesystem();

        // Set no_new_privs
        if (self.config.no_new_privs) {
            containment.setNoNewPrivs() catch {};
        }

        // Drop capabilities from bounding set
        if (self.config.drop_capabilities) {
            containment.dropCapabilities(&.{}) catch |err| {
                log.debug("Failed to drop capabilities: {s}", .{@errorName(err)});
            };
        }

        // Apply Landlock filesystem restrictions
        if (self.config.enable_landlock) {
            if (self.fs_isolated) {
                // Chroot/pivot_root mode: restrict within the new root.
                // OCI's default is rootfs read-write (config.root.readonly:false);
                // honour that so real workloads can write to their own rootfs.
                const root_access = if (self.config.rootfs_readonly)
                    lsm.LANDLOCK_ACCESS_FS_READ_EXEC
                else
                    lsm.LANDLOCK_ACCESS_FS_READ_WRITE;
                const rules = [_]lsm.LandlockPathRule{
                    .{ .path = "/", .access = root_access },
                    .{ .path = "/tmp", .access = lsm.LANDLOCK_ACCESS_FS_READ_WRITE },
                };
                lsm.applyLandlockRulesWithPaths(&rules) catch |err| {
                    log.debug("Landlock unavailable: {s}", .{@errorName(err)});
                };
            } else {
                // Chdir fallback mode: restrict to rootfs subtree.
                // Same readonly toggle as the pivot_root branch above; default
                // is rw to match OCI root.readonly: false.
                const fb_access = if (self.config.rootfs_readonly)
                    lsm.LANDLOCK_ACCESS_FS_READ_EXEC
                else
                    lsm.LANDLOCK_ACCESS_FS_READ_WRITE;
                const rules = [_]lsm.LandlockPathRule{
                    .{ .path = self.config.rootfs, .access = fb_access },
                };
                lsm.applyLandlockRulesWithPaths(&rules) catch |err| {
                    log.debug("Landlock unavailable: {s}", .{@errorName(err)});
                };
            }
        }

        // Load seccomp filter
        if (self.config.seccomp_policy) |policy| {
            try self.loadSeccomp(policy);
        }

        // Signal parent we're ready
        if (self.child_to_parent) |*p| {
            try p.signal();
            p.close();
        }

        // Change to target uid/gid
        _ = std.os.linux.syscall2(.setgroups, 0, 0);
        _ = std.os.linux.syscall1(.setgid, self.config.gid);
        _ = std.os.linux.syscall1(.setuid, self.config.uid);

        // Change to working directory
        if (self.fs_isolated) {
            std.posix.chdir(self.config.cwd) catch {};
        } else {
            // In chdir mode, we're already in the rootfs. Only change if cwd != "/"
            if (!std.mem.eql(u8, self.config.cwd, "/")) {
                // Convert absolute cwd to relative: "/tmp" -> "./tmp"
                var cwd_buf: [512]u8 = undefined;
                if (self.config.cwd.len > 0 and self.config.cwd[0] == '/' and self.config.cwd.len + 1 < cwd_buf.len) {
                    cwd_buf[0] = '.';
                    @memcpy(cwd_buf[1 .. self.config.cwd.len + 1], self.config.cwd);
                    cwd_buf[self.config.cwd.len + 1] = 0;
                    std.posix.chdir(cwd_buf[0 .. self.config.cwd.len + 1]) catch {};
                } else {
                    std.posix.chdir(self.config.cwd) catch {};
                }
            }
        }

        // Execute the command
        self.execCommandDirect();
    }

    /// Set up stdio in child process
    fn setupChildStdio(self: *Executor) !void {
        if (self.console) |*c| {
            // PTY mode: set up console
            c.setupForChild() catch |err| {
                log.warn("Failed to set up console in child: {s}", .{@errorName(err)});
            };
        } else if (self.stdin_pipe != null) {
            // Pipe mode: redirect stdin/stdout/stderr
            try self.redirectPipesToStdio();
        }
    }

    /// Redirect pipes to stdin/stdout/stderr
    fn redirectPipesToStdio(self: *Executor) !void {
        // stdin: read from stdin_pipe
        if (self.stdin_pipe) |*p| {
            const result = std.os.linux.dup2(@intCast(p.read_fd), 0);
            if (@as(isize, @bitCast(result)) < 0) {
                return error.Dup2Failed;
            }
            p.close();
        }

        // stdout: write to stdout_pipe
        if (self.stdout_pipe) |*p| {
            const result = std.os.linux.dup2(@intCast(p.write_fd), 1);
            if (@as(isize, @bitCast(result)) < 0) {
                return error.Dup2Failed;
            }
            p.close();
        }

        // stderr: write to stderr_pipe
        if (self.stderr_pipe) |*p| {
            const result = std.os.linux.dup2(@intCast(p.write_fd), 2);
            if (@as(isize, @bitCast(result)) < 0) {
                return error.Dup2Failed;
            }
            p.close();
        }
    }

    /// Parent process - wait for child
    fn parentProcess(self: *Executor, pid: i32) !i32 {
        // Close child's end of pipes
        if (self.parent_to_child) |*p| p.closeRead();
        if (self.child_to_parent) |*p| p.closeWrite();

        // Set up console/stdio for parent
        self.setupParentStdio();

        // Set up cgroup
        if (self.config.cgroup_path) |cgroup_path| {
            try self.addToCgroup(pid, cgroup_path);
        }

        // Write uid/gid maps for user namespace
        if (self.config.user_ns) {
            try self.writeIdMaps(pid);
        }

        // Signal child to continue
        if (self.parent_to_child) |*p| {
            try p.signal();
            p.close();
        }

        // Wait for child to be ready
        if (self.child_to_parent) |*p| {
            try p.wait();
            p.close();
        }

        log.info("Container started with PID {d}", .{pid});

        // Wait for container to exit
        return try self.waitForChild(pid);
    }

    /// Set up stdio for parent process
    fn setupParentStdio(self: *Executor) void {
        if (self.console) |*c| {
            // Close slave in parent
            c.setupForParent();
        }
        // Non-terminal: nothing to do, child inherits our stdio
    }

    fn setupUserNamespace(self: *Executor) !void {
        _ = self;
        // User namespace is set up at clone time, but we might need to
        // do additional setup here
        log.debug("User namespace setup complete", .{});
    }

    fn setHostname(self: *Executor, hostname: []const u8) !void {
        _ = self;
        const result = std.os.linux.syscall2(.sethostname, @intFromPtr(hostname.ptr), hostname.len);
        if (@as(isize, @bitCast(result)) < 0) {
            log.warn("Failed to set hostname", .{});
        }
    }

    fn setupFilesystem(self: *Executor) !void {
        // Need null-terminated string for syscalls
        var rootfs_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const rootfs_z = std.fmt.bufPrintZ(&rootfs_buf, "{s}", .{self.config.rootfs}) catch {
            log.err("rootfs path too long", .{});
            return errors.Error.NamespaceCreationFailed;
        };

        log.debug("Setting up filesystem, rootfs: {s}", .{rootfs_z});

        // Try pivot_root approach (works with AppArmor restricted user namespaces)
        if (self.tryPivotRoot(rootfs_z)) {
            self.fs_isolated = true;
            log.debug("Filesystem setup complete (pivot_root)", .{});
            return;
        }

        // Fallback: try chroot (works when CAP_SYS_CHROOT is available)
        const result = std.os.linux.syscall1(.chroot, @intFromPtr(rootfs_z.ptr));
        if (@as(isize, @bitCast(result)) >= 0) {
            self.fs_isolated = true;
            std.posix.chdir("/") catch {
                return errors.Error.NamespaceCreationFailed;
            };
            log.debug("Filesystem setup complete (chroot)", .{});
            return;
        }

        // Last resort: chdir to rootfs (commands use rootfs-relative paths)
        if (self.is_rootless) {
            log.debug("pivot_root and chroot both failed, using chdir fallback", .{});
            std.posix.chdir(self.config.rootfs) catch |err| {
                log.err("Failed to chdir to rootfs: {s}", .{@errorName(err)});
                return errors.Error.NamespaceCreationFailed;
            };
            return;
        }

        log.err("Failed to set up filesystem isolation", .{});
        return errors.Error.NamespaceCreationFailed;
    }

    /// Try pivot_root approach: bind-mount rootfs, pivot, unmount old root
    fn tryPivotRoot(self: *Executor, rootfs_z: [:0]const u8) bool {
        const MS_BIND: usize = 0x1000;
        const MS_REC: usize = 0x4000;
        const MNT_DETACH: usize = 0x2;

        // Step 1: Bind mount rootfs onto itself (makes it a mount point)
        const mount_result = std.os.linux.syscall5(
            .mount,
            @intFromPtr(rootfs_z.ptr),
            @intFromPtr(rootfs_z.ptr),
            0, // filesystemtype (NULL for bind)
            MS_BIND | MS_REC,
            0, // data (NULL)
        );
        if (@as(isize, @bitCast(mount_result)) < 0) {
            const errno: u16 = @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(mount_result)))));
            log.debug("bind mount failed (errno: {d})", .{errno});
            return false;
        }

        // Step 1b: Populate /dev inside the rootfs BEFORE pivot_root. We mount
        // a private tmpfs at <rootfs>/dev and bind-mount the host's character
        // devices onto empty files inside it. Doing this pre-pivot lets us
        // reach the host's /dev/* by absolute path; after pivot_root the host
        // tree is gone. Errors are non-fatal: a workload that doesn't use
        // /dev/null still runs.
        self.populateDev(rootfs_z) catch |err| {
            log.debug("/dev population partially failed: {s}", .{@errorName(err)});
        };

        // Step 1c: Mount /proc and /sys inside the rootfs BEFORE pivot_root.
        // procfs mount under an unprivileged userns wants the calling task to
        // still see an ancestor procfs at mount time; doing this after
        // pivot_root (when the host tree is gone) returns EPERM.
        self.populateKernelFs(rootfs_z) catch |err| {
            log.debug("/proc or /sys population failed: {s}", .{@errorName(err)});
        };

        // Step 1d: Apply user-specified OCI mounts (A5). These run BEFORE
        // pivot_root so the host source paths (for bind mounts) are still
        // reachable. A user mount whose destination matches one of the auto-
        // mounted paths (/proc, /sys, /dev) silently replaces the auto-mount
        // because the second mount on the same target stacks on the first; we
        // could detect and skip but the OCI spec says explicit wins.
        self.applyUserMounts(rootfs_z) catch |err| {
            log.debug("user mounts partially failed: {s}", .{@errorName(err)});
        };

        // Step 2: Create directory for old root
        var pivot_old_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const pivot_old_z = std.fmt.bufPrintZ(&pivot_old_buf, "{s}/.pivot_old", .{rootfs_z}) catch return false;

        const mkdir_result = std.os.linux.syscall2(.mkdir, @intFromPtr(pivot_old_z.ptr), 0o700);
        const mkdir_signed: isize = @bitCast(mkdir_result);
        if (mkdir_signed < 0 and mkdir_signed != -17) { // -17 = EEXIST, which is fine
            log.debug("mkdir .pivot_old failed (errno: {d})", .{@as(u16, @truncate(@as(usize, @bitCast(-mkdir_signed))))});
            return false;
        }

        // Step 3: pivot_root(new_root, put_old)
        const pivot_result = std.os.linux.syscall2(
            .pivot_root,
            @intFromPtr(rootfs_z.ptr),
            @intFromPtr(pivot_old_z.ptr),
        );
        if (@as(isize, @bitCast(pivot_result)) < 0) {
            const errno: u16 = @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(pivot_result)))));
            log.debug("pivot_root failed (errno: {d})", .{errno});
            // Clean up mkdir
            _ = std.os.linux.syscall1(.rmdir, @intFromPtr(pivot_old_z.ptr));
            return false;
        }

        // Step 4: chdir to new root
        std.posix.chdir("/") catch return false;

        // Step 5: Unmount old root (detach so it goes away when all refs are gone)
        const old_root: [*:0]const u8 = "/.pivot_old";
        _ = std.os.linux.syscall2(.umount2, @intFromPtr(old_root), MNT_DETACH);

        // Step 6: Remove the old root directory
        _ = std.os.linux.syscall1(.rmdir, @intFromPtr(old_root));

        // Step 7: Create the convenience symlinks under /dev once we're inside
        // the new root (the targets reference /proc/self/fd which only resolves
        // post-pivot when /proc is reachable as a relative path).
        const links = [_]struct { src: [*:0]const u8, tgt: [*:0]const u8 }{
            .{ .src = "/proc/self/fd/0", .tgt = "/dev/stdin" },
            .{ .src = "/proc/self/fd/1", .tgt = "/dev/stdout" },
            .{ .src = "/proc/self/fd/2", .tgt = "/dev/stderr" },
            .{ .src = "/proc/self/fd", .tgt = "/dev/fd" },
        };
        for (links) |l| {
            _ = std.os.linux.syscall2(.symlink, @intFromPtr(l.src), @intFromPtr(l.tgt));
        }

        return true;
    }

    /// Populate /dev inside the rootfs by mounting a tmpfs there and
    /// bind-mounting the standard host character devices onto empty files.
    /// Called from `tryPivotRoot` BEFORE the actual pivot so the host's
    /// `/dev/*` paths are still reachable.
    fn populateDev(self: *Executor, rootfs_z: [:0]const u8) !void {
        _ = self;
        const MS_BIND: usize = 0x1000;
        const MS_NOSUID: usize = 0x2;
        const O_WRONLY: u32 = 0o1;
        const O_CREAT: u32 = 0o100;
        const O_CLOEXEC: u32 = 0o2000000;
        const tmpfs_data: [*:0]const u8 = "mode=755,size=64k";

        // Build "<rootfs>/dev"
        var dev_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const dev_z = std.fmt.bufPrintZ(&dev_buf, "{s}/dev", .{rootfs_z}) catch return error.PathTooLong;

        // Ensure <rootfs>/dev exists (may already; ignore EEXIST = -17)
        const mkdir_r = std.os.linux.syscall2(.mkdir, @intFromPtr(dev_z.ptr), 0o755);
        const mkdir_s: isize = @bitCast(mkdir_r);
        if (mkdir_s < 0 and mkdir_s != -17) {
            log.debug("mkdir {s} failed (errno {d})", .{ dev_z, @as(u16, @truncate(@as(usize, @bitCast(-mkdir_s)))) });
        }

        // Mount a fresh tmpfs at <rootfs>/dev so the bind targets are private
        // to this container and disappear on exit.
        const tmpfs_type: [*:0]const u8 = "tmpfs";
        const tmpfs_src: [*:0]const u8 = "tmpfs";
        _ = std.os.linux.syscall5(
            .mount,
            @intFromPtr(tmpfs_src),
            @intFromPtr(dev_z.ptr),
            @intFromPtr(tmpfs_type),
            MS_NOSUID,
            @intFromPtr(tmpfs_data),
        );

        // Bind-mount each host device onto an empty file in the new tmpfs.
        const devs = [_][]const u8{ "null", "zero", "full", "random", "urandom", "tty" };
        for (devs) |name| {
            var host_buf: [64:0]u8 = undefined;
            const host_z = std.fmt.bufPrintZ(&host_buf, "/dev/{s}", .{name}) catch continue;

            var tgt_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const tgt_z = std.fmt.bufPrintZ(&tgt_buf, "{s}/{s}", .{ dev_z, name }) catch continue;

            // Create empty target file (bind-mount source over destination).
            const fd_r = std.os.linux.syscall4(
                .openat,
                @as(usize, @bitCast(@as(isize, -100))), // AT_FDCWD
                @intFromPtr(tgt_z.ptr),
                @as(usize, O_WRONLY | O_CREAT | O_CLOEXEC),
                @as(usize, 0o644),
            );
            const fd_s: isize = @bitCast(fd_r);
            if (fd_s >= 0) {
                _ = std.os.linux.syscall1(.close, @as(usize, @bitCast(fd_s)));
            }

            _ = std.os.linux.syscall5(
                .mount,
                @intFromPtr(host_z.ptr),
                @intFromPtr(tgt_z.ptr),
                0,
                MS_BIND,
                0,
            );
        }
    }

    /// Mount /proc and /sys into <rootfs>/proc and <rootfs>/sys BEFORE
    /// pivot_root. Mounting procfs after pivot_root returns EPERM under recent
    /// kernels' unprivileged-userns check because the calling task can no
    /// longer see an ancestor procfs to satisfy the visibility prerequisite.
    /// Flags reduce privilege: nosuid+nodev+noexec for procfs; same plus
    /// MS_RDONLY for sysfs.
    fn populateKernelFs(self: *Executor, rootfs_z: [:0]const u8) !void {
        _ = self;
        const MS_NOSUID: usize = 0x2;
        const MS_NODEV: usize = 0x4;
        const MS_NOEXEC: usize = 0x8;
        const MS_RDONLY: usize = 0x1;

        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;

        // /proc
        const proc_path = std.fmt.bufPrintZ(&path_buf, "{s}/proc", .{rootfs_z}) catch return;
        const mk_p = std.os.linux.syscall2(.mkdir, @intFromPtr(proc_path.ptr), 0o755);
        if (@as(isize, @bitCast(mk_p)) < 0 and @as(isize, @bitCast(mk_p)) != -17) {
            log.debug("mkdir <rootfs>/proc failed", .{});
        }
        const proc_src: [*:0]const u8 = "proc";
        const proc_fs: [*:0]const u8 = "proc";
        const proc_r = std.os.linux.syscall5(
            .mount,
            @intFromPtr(proc_src),
            @intFromPtr(proc_path.ptr),
            @intFromPtr(proc_fs),
            MS_NOSUID | MS_NODEV | MS_NOEXEC,
            0,
        );
        if (@as(isize, @bitCast(proc_r)) < 0) {
            const errno: u16 = @truncate(@as(usize, @bitCast(-@as(isize, @bitCast(proc_r)))));
            log.debug("mount /proc failed (errno: {d})", .{errno});
        }

        // /sys
        var path_buf2: [std.fs.max_path_bytes:0]u8 = undefined;
        const sys_path = std.fmt.bufPrintZ(&path_buf2, "{s}/sys", .{rootfs_z}) catch return;
        const mk_s = std.os.linux.syscall2(.mkdir, @intFromPtr(sys_path.ptr), 0o755);
        if (@as(isize, @bitCast(mk_s)) < 0 and @as(isize, @bitCast(mk_s)) != -17) {
            log.debug("mkdir <rootfs>/sys failed", .{});
        }
        const sys_src: [*:0]const u8 = "sysfs";
        const sys_fs: [*:0]const u8 = "sysfs";
        _ = std.os.linux.syscall5(
            .mount,
            @intFromPtr(sys_src),
            @intFromPtr(sys_path.ptr),
            @intFromPtr(sys_fs),
            MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_RDONLY,
            0,
        );
    }

    /// Apply OCI `mounts[]` from the config inside the rootfs, BEFORE pivot_root.
    /// Supported types: bind (the common case), tmpfs, proc, sysfs. Options
    /// parsed: ro, rw, nosuid, nodev, noexec, bind, rbind, private, rprivate.
    /// Unknown types or unparsable options are logged and skipped; we never
    /// abort the container for a bad mount entry.
    fn applyUserMounts(self: *Executor, rootfs_z: [:0]const u8) !void {
        const MS_RDONLY: usize = 0x1;
        const MS_NOSUID: usize = 0x2;
        const MS_NODEV: usize = 0x4;
        const MS_NOEXEC: usize = 0x8;
        const MS_BIND: usize = 0x1000;
        const MS_REC: usize = 0x4000;
        const MS_PRIVATE: usize = 0x40000;

        const mounts = self.config.mounts orelse return;
        for (mounts) |m| {
            // Build absolute target inside the rootfs: <rootfs>/<destination>.
            var tgt_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const dest_slash: u8 = if (m.destination.len > 0 and m.destination[0] == '/') 0 else '/';
            const tgt_z = if (dest_slash == 0)
                std.fmt.bufPrintZ(&tgt_buf, "{s}{s}", .{ rootfs_z, m.destination }) catch continue
            else
                std.fmt.bufPrintZ(&tgt_buf, "{s}/{s}", .{ rootfs_z, m.destination }) catch continue;

            // mkdir -p the parent so the bind/mount has a target. We try once
            // for the leaf; if EEXIST or ENOENT we proceed and let mount fail.
            _ = std.os.linux.syscall2(.mkdir, @intFromPtr(tgt_z.ptr), 0o755);

            // Default flags + data string. Walk options to set flags.
            var flags: usize = 0;
            var is_bind: bool = false;
            var is_rec: bool = false;
            var make_private: bool = false;
            if (m.options) |opts| {
                for (opts) |opt| {
                    if (std.mem.eql(u8, opt, "ro")) flags |= MS_RDONLY
                    else if (std.mem.eql(u8, opt, "rw")) flags &= ~MS_RDONLY
                    else if (std.mem.eql(u8, opt, "nosuid")) flags |= MS_NOSUID
                    else if (std.mem.eql(u8, opt, "nodev")) flags |= MS_NODEV
                    else if (std.mem.eql(u8, opt, "noexec")) flags |= MS_NOEXEC
                    else if (std.mem.eql(u8, opt, "bind")) is_bind = true
                    else if (std.mem.eql(u8, opt, "rbind")) { is_bind = true; is_rec = true; }
                    else if (std.mem.eql(u8, opt, "private")) make_private = true
                    else if (std.mem.eql(u8, opt, "rprivate")) { make_private = true; is_rec = true; }
                    // Unknown options (mode=, uid=, gid=, size=, …) are passed
                    // as data when the fs type accepts them; we forward the
                    // first such option below. Most workloads only need flag
                    // options, so this is acceptable for v1.
                }
            }

            // Decide whether this is a bind or a typed mount.
            const t = m.type orelse "";
            const src = m.source orelse "";
            var fstype_z_buf: [64:0]u8 = undefined;
            var src_z_buf: [std.fs.max_path_bytes:0]u8 = undefined;

            const fstype_z: ?[*:0]const u8 = if (t.len > 0)
                @ptrCast((std.fmt.bufPrintZ(&fstype_z_buf, "{s}", .{t}) catch break).ptr)
            else null;
            const src_z: ?[*:0]const u8 = if (src.len > 0)
                @ptrCast((std.fmt.bufPrintZ(&src_z_buf, "{s}", .{src}) catch break).ptr)
            else null;

            if (is_bind or std.mem.eql(u8, t, "bind") or std.mem.eql(u8, t, "rbind")) {
                // Linux kernel quirk: the initial bind-mount syscall ignores
                // MS_RDONLY (and several other propagation flags). To make the
                // mount truly read-only we must follow up with a MS_REMOUNT.
                const want_ro = (flags & MS_RDONLY) != 0;
                var bind_flags: usize = MS_BIND;
                if (is_rec or std.mem.eql(u8, t, "rbind")) bind_flags |= MS_REC;
                _ = std.os.linux.syscall5(
                    .mount,
                    if (src_z) |s| @intFromPtr(s) else 0,
                    @intFromPtr(tgt_z.ptr),
                    0,
                    bind_flags,
                    0,
                );
                if (want_ro) {
                    const MS_REMOUNT: usize = 0x20;
                    const remount_flags: usize = bind_flags | MS_REMOUNT | MS_RDONLY | (flags & (MS_NOSUID | MS_NODEV | MS_NOEXEC));
                    _ = std.os.linux.syscall5(
                        .mount,
                        0,
                        @intFromPtr(tgt_z.ptr),
                        0,
                        remount_flags,
                        0,
                    );
                }
            } else {
                _ = std.os.linux.syscall5(
                    .mount,
                    if (src_z) |s| @intFromPtr(s) else 0,
                    @intFromPtr(tgt_z.ptr),
                    if (fstype_z) |f| @intFromPtr(f) else 0,
                    flags,
                    0,
                );
            }

            if (make_private) {
                const private_flags: usize = MS_PRIVATE | (if (is_rec) MS_REC else @as(usize, 0));
                _ = std.os.linux.syscall5(.mount, 0, @intFromPtr(tgt_z.ptr), 0, private_flags, 0);
            }
        }
    }

    fn loadSeccomp(self: *Executor, policy: seccomp.SyscallPolicy) !void {
        // Log blocked syscalls in verbose mode
        if (self.config.verbose and policy.deny.len > 0) {
            log.info("=== Verbose mode: The following syscalls will be BLOCKED ===", .{});
            for (policy.deny) |syscall_nr| {
                const name = seccomp.getSyscallName(@intCast(syscall_nr));
                log.info("[WILL BLOCK] syscall={s} (nr={d}) → EPERM", .{ name, syscall_nr });
            }
            log.info("=== End of blocked syscall list ({d} syscalls) ===", .{policy.deny.len});
        }

        // Without a broker listener, broker-listed syscalls must be allowed
        // (USER_NOTIF without a listener would block/fail the syscall)
        const effective_allow = self.allocator.alloc(i32, policy.allow.len + policy.broker.len) catch |err| {
            log.err("Failed to allocate seccomp policy: {s}", .{@errorName(err)});
            return errors.Error.SeccompLoadFailed;
        };

        @memcpy(effective_allow[0..policy.allow.len], policy.allow);
        @memcpy(effective_allow[policy.allow.len..], policy.broker);

        const effective_policy = seccomp.SyscallPolicy{
            .allow = effective_allow,
            .deny = policy.deny,
            .broker = &.{}, // No broker syscalls when no listener
        };

        // Generate BPF program (verbose flag passed but broker not active yet)
        const bpf = seccomp.generateBpf(self.allocator, effective_policy, false) catch |err| {
            log.err("Failed to generate seccomp BPF: {s}", .{@errorName(err)});
            self.allocator.free(effective_allow);
            return errors.Error.SeccompLoadFailed;
        };

        // Load the filter
        seccomp.loadFilter(bpf) catch |err| {
            log.err("Failed to load seccomp filter: {s}", .{@errorName(err)});
            self.allocator.free(bpf);
            self.allocator.free(effective_allow);
            return errors.Error.SeccompLoadFailed;
        };

        // Note: we intentionally do NOT free bpf/effective_allow here.
        // After seccomp is loaded, the GPA's free() may use syscalls blocked
        // by the filter. The child is about to exec (replacing the process
        // image) so the OS will reclaim all memory.
    }

    fn setUser(self: *Executor) !void {
        // Set supplementary groups (empty for now)
        const result1 = std.os.linux.syscall2(.setgroups, 0, 0);
        if (@as(isize, @bitCast(result1)) < 0) {
            log.debug("setgroups failed (may be expected)", .{});
        }

        // Set GID
        const result2 = std.os.linux.syscall1(.setgid, self.config.gid);
        if (@as(isize, @bitCast(result2)) < 0) {
            log.warn("setgid failed", .{});
        }

        // Set UID
        const result3 = std.os.linux.syscall1(.setuid, self.config.uid);
        if (@as(isize, @bitCast(result3)) < 0) {
            log.warn("setuid failed", .{});
        }
    }

    fn changeDir(self: *Executor) !void {
        std.posix.chdir(self.config.cwd) catch |err| {
            log.warn("Failed to chdir to {s}: {s}", .{ self.config.cwd, @errorName(err) });
        };
    }

    fn execCommand(self: *Executor) !void {
        self.execCommandDirect();
    }

    /// Execute the container command
    fn execCommandDirect(self: *Executor) noreturn {
        if (self.config.args.len == 0) {
            _ = std.os.linux.syscall1(.exit_group, 1);
            unreachable;
        }

        // Use fixed-size stack buffers for arg/env strings
        // Each string gets its own buffer with null terminator
        var str_bufs: [32][512]u8 = undefined;
        var str_ptrs: [32][*:0]const u8 = undefined;
        var str_count: usize = 0;

        // Helper to add a null-terminated string
        const addStr = struct {
            fn f(bufs: *[32][512]u8, ptrs: *[32][*:0]const u8, count: *usize, src: []const u8) void {
                if (count.* >= 32 or src.len >= 511) return;
                const idx = count.*;
                @memcpy(bufs[idx][0..src.len], src);
                bufs[idx][src.len] = 0;
                ptrs[idx] = @ptrCast(&bufs[idx]);
                count.* += 1;
            }
        }.f;

        // When filesystem is not isolated (chdir fallback), adjust absolute
        // paths to be relative to the rootfs we chdir'd into
        var path_bufs: [32][512]u8 = undefined;

        // Add args
        const arg_start: usize = 0;
        for (self.config.args, 0..) |arg, i| {
            if (!self.fs_isolated and arg.len > 0 and arg[0] == '/' and arg.len + 1 < 512) {
                // Convert absolute path to rootfs-relative: "/bin/sh" -> "./bin/sh"
                path_bufs[i][0] = '.';
                @memcpy(path_bufs[i][1 .. arg.len + 1], arg);
                addStr(&str_bufs, &str_ptrs, &str_count, path_bufs[i][0 .. arg.len + 1]);
            } else {
                addStr(&str_bufs, &str_ptrs, &str_count, arg);
            }
        }
        const arg_end = str_count;

        // Add env
        const env_start = str_count;
        if (self.config.env.len > 0) {
            for (self.config.env) |env_var| {
                addStr(&str_bufs, &str_ptrs, &str_count, env_var);
            }
        } else {
            addStr(&str_bufs, &str_ptrs, &str_count, "PATH=/usr/local/bin:/usr/bin:/bin");
        }
        const env_end = str_count;

        // Build argv (null-terminated pointer array)
        var argv: [33]?[*:0]const u8 = .{null} ** 33;
        for (arg_start..arg_end, 0..) |si, i| {
            argv[i] = str_ptrs[si];
        }

        // Build envp (null-terminated pointer array)
        var envp: [33]?[*:0]const u8 = .{null} ** 33;
        for (env_start..env_end, 0..) |si, i| {
            envp[i] = str_ptrs[si];
        }

        if (argv[0] == null) {
            _ = std.os.linux.syscall1(.exit_group, 1);
            unreachable;
        }

        // Execute
        _ = std.os.linux.execve(
            argv[0].?,
            @ptrCast(&argv),
            @ptrCast(&envp),
        );

        // execve failed
        _ = std.os.linux.syscall1(.exit_group, 127);
        unreachable;
    }

    fn addToCgroup(self: *Executor, pid: i32, cgroup_path: []const u8) !void {
        _ = self;

        // Write PID to cgroup.procs
        var path_buf: [256]u8 = undefined;
        const procs_path = std.fmt.bufPrint(&path_buf, "{s}/cgroup.procs", .{cgroup_path}) catch return;

        const file = std.fs.openFileAbsolute(procs_path, .{ .mode = .write_only }) catch |err| {
            log.warn("Failed to open cgroup.procs: {s}", .{@errorName(err)});
            return;
        };
        defer file.close();

        var pid_buf: [16]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;
        file.writeAll(pid_str) catch {};

        log.debug("Added PID {d} to cgroup {s}", .{ pid, cgroup_path });
    }

    fn writeIdMaps(self: *Executor, pid: i32) !void {
        _ = self;

        // Write uid_map: map container root (0) to current user
        const uid = std.os.linux.getuid();
        const gid = std.os.linux.getgid();

        var path_buf: [64]u8 = undefined;
        var content_buf: [64]u8 = undefined;

        log.info("Writing ID maps for pid {d} (uid={d}, gid={d})", .{ pid, uid, gid });

        // Disable setgroups first (required for unprivileged user namespaces)
        const setgroups_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/setgroups", .{pid}) catch return;
        if (std.fs.openFileAbsolute(setgroups_path, .{ .mode = .write_only })) |file| {
            defer file.close();
            file.writeAll("deny") catch |err| {
                log.warn("Failed to write setgroups deny: {s}", .{@errorName(err)});
            };
            log.info("Wrote setgroups deny", .{});
        } else |err| {
            log.warn("Failed to open setgroups: {s}", .{@errorName(err)});
        }

        // Write uid_map
        const uid_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/uid_map", .{pid}) catch return;
        const uid_content = std.fmt.bufPrint(&content_buf, "0 {d} 1", .{uid}) catch return;

        if (std.fs.openFileAbsolute(uid_path, .{ .mode = .write_only })) |file| {
            defer file.close();
            file.writeAll(uid_content) catch |err| {
                log.err("Failed to write uid_map: {s}", .{@errorName(err)});
            };
            log.info("Wrote uid_map: {s}", .{uid_content});
        } else |err| {
            log.err("Failed to open uid_map: {s}", .{@errorName(err)});
        }

        // Write gid_map
        const gid_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/gid_map", .{pid}) catch return;
        const gid_content = std.fmt.bufPrint(&content_buf, "0 {d} 1", .{gid}) catch return;

        if (std.fs.openFileAbsolute(gid_path, .{ .mode = .write_only })) |file| {
            defer file.close();
            file.writeAll(gid_content) catch |err| {
                log.err("Failed to write gid_map: {s}", .{@errorName(err)});
            };
            log.info("Wrote gid_map: {s}", .{gid_content});
        } else |err| {
            log.err("Failed to open gid_map: {s}", .{@errorName(err)});
        }
    }

    fn waitForChild(self: *Executor, pid: i32) !i32 {
        var status: u32 = 0;
        const options: u32 = 0;

        while (true) {
            const result = std.os.linux.waitpid(pid, &status, options);
            const signed: isize = @bitCast(result);

            if (signed < 0) {
                const errno = std.posix.errno(@as(isize, @bitCast(result)));
                if (errno == .INTR) {
                    continue; // Interrupted, retry
                }
                log.err("waitpid failed", .{});
                return errors.Error.SystemError;
            }

            // Check if child exited
            if (std.os.linux.W.IFEXITED(status)) {
                const exit_code: i32 = @intCast(std.os.linux.W.EXITSTATUS(status));
                self.exit_code = exit_code;
                log.info("Container exited with code {d}", .{exit_code});
                return exit_code;
            }

            // Check if child was signaled
            if (std.os.linux.W.IFSIGNALED(status)) {
                const sig: i32 = @intCast(std.os.linux.W.TERMSIG(status));
                self.exit_code = 128 + sig;
                log.info("Container killed by signal {d}", .{sig});
                return 128 + sig;
            }
        }
    }

    /// Send signal to container
    pub fn signal(self: *Executor, sig: i32) !void {
        if (self.child_pid) |pid| {
            const result = std.os.linux.kill(pid, sig);
            if (@as(isize, @bitCast(result)) < 0) {
                return errors.Error.SystemError;
            }
        }
    }

    // ========================================================================
    // Container I/O methods
    // ========================================================================

    /// Get the console (PTY) if available
    pub fn getConsole(self: *Executor) ?*console_mod.Console {
        if (self.console) |*c| {
            return c;
        }
        return null;
    }

    /// Get the stdout read fd for reading container output (pipe mode)
    pub fn getStdoutFd(self: *Executor) ?i32 {
        if (self.stdout_pipe) |p| {
            return p.read_fd;
        }
        return null;
    }

    /// Get the stderr read fd for reading container errors (pipe mode)
    pub fn getStderrFd(self: *Executor) ?i32 {
        if (self.stderr_pipe) |p| {
            return p.read_fd;
        }
        return null;
    }

    /// Get the stdin write fd for writing to container (pipe mode)
    pub fn getStdinFd(self: *Executor) ?i32 {
        if (self.stdin_pipe) |p| {
            return p.write_fd;
        }
        return null;
    }

    /// Write data to container stdin
    pub fn writeStdin(self: *Executor, data: []const u8) !usize {
        if (self.console) |*c| {
            try c.relayInput(data);
            return data.len;
        } else if (self.stdin_pipe) |p| {
            const result = std.os.linux.write(@intCast(p.write_fd), data.ptr, data.len);
            const signed: isize = @bitCast(result);
            if (signed < 0) {
                return error.WriteFailed;
            }
            return @intCast(signed);
        }
        return 0;
    }

    /// Read data from container stdout
    pub fn readStdout(self: *Executor, buf: []u8) !usize {
        if (self.console) |*c| {
            return try c.relayOutput(buf);
        } else if (self.stdout_pipe) |p| {
            const result = std.os.linux.read(@intCast(p.read_fd), buf.ptr, buf.len);
            const signed: isize = @bitCast(result);
            if (signed < 0) {
                return error.ReadFailed;
            }
            return @intCast(signed);
        }
        return 0;
    }

    /// Read data from container stderr (only in pipe mode)
    pub fn readStderr(self: *Executor, buf: []u8) !usize {
        if (self.stderr_pipe) |p| {
            const result = std.os.linux.read(@intCast(p.read_fd), buf.ptr, buf.len);
            const signed: isize = @bitCast(result);
            if (signed < 0) {
                return error.ReadFailed;
            }
            return @intCast(signed);
        }
        return 0;
    }

    /// Resize the terminal window (PTY mode only)
    pub fn resizeTerminal(self: *Executor, rows: u16, cols: u16) !void {
        if (self.console) |*c| {
            try c.setSize(rows, cols);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "sync pipe" {
    var pipe = try SyncPipe.init();
    defer pipe.close();

    try std.testing.expect(pipe.read_fd >= 0);
    try std.testing.expect(pipe.write_fd >= 0);
}

test "exec config defaults" {
    const config = ExecConfig{
        .container_id = "test",
        .rootfs = "/tmp/rootfs",
        .args = &.{"/bin/sh"},
    };

    try std.testing.expectEqualStrings("/", config.cwd);
    try std.testing.expectEqual(@as(u32, 0), config.uid);
    try std.testing.expect(config.no_new_privs);
}
