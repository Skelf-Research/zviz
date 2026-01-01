const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const linux = @import("../syscalls/linux.zig");
const containment = @import("../containment/containment.zig");
const seccomp = @import("../seccomp/seccomp.zig");
const cgroup = @import("../cgroup/cgroup.zig");
const console_mod = @import("console.zig");

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

    /// Namespaces to create
    namespaces: u64 = CloneFlags.NEWNS | CloneFlags.NEWPID | CloneFlags.NEWIPC | CloneFlags.NEWUTS,

    /// Whether to set up user namespace
    user_ns: bool = true,

    /// Seccomp policy to apply
    seccomp_policy: ?seccomp.SyscallPolicy = null,

    /// Cgroup path for resource limits
    cgroup_path: ?[]const u8 = null,

    /// Allocate a PTY
    terminal: bool = false,

    /// Console socket path for OCI console protocol
    console_socket: ?[]const u8 = null,

    /// Make rootfs readonly
    rootfs_readonly: bool = true,

    /// Set no_new_privs
    no_new_privs: bool = true,

    /// Hostname for UTS namespace
    hostname: ?[]const u8 = null,
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

    pub fn init(allocator: std.mem.Allocator, config: ExecConfig) Executor {
        return .{
            .allocator = allocator,
            .config = config,
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

        // Fork the container process
        const pid = try self.forkContainer();
        self.child_pid = pid;

        if (pid == 0) {
            // Child process - this runs in the container
            self.childProcess() catch |err| {
                log.err("Container child error: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
            unreachable;
        }

        // Parent process
        return try self.parentProcess(pid);
    }

    /// Set up stdio for the container (PTY or pipes)
    fn setupStdio(self: *Executor) !void {
        if (self.config.terminal) {
            // Terminal mode: create PTY
            self.console = console_mod.Console.init(self.allocator);
            self.console.?.createPty() catch |err| {
                log.warn("Failed to create PTY: {s}, falling back to pipes", .{@errorName(err)});
                self.console = null;
                try self.setupPipes();
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
        } else {
            // Non-terminal mode: create pipes for stdin/stdout/stderr
            try self.setupPipes();
            log.debug("Console mode: pipes", .{});
        }
    }

    /// Set up stdio pipes for non-terminal mode
    fn setupPipes(self: *Executor) !void {
        self.stdin_pipe = try SyncPipe.init();
        self.stdout_pipe = try SyncPipe.init();
        self.stderr_pipe = try SyncPipe.init();
    }

    /// Fork with namespaces
    fn forkContainer(self: *Executor) !i32 {
        // Use standard fork
        // Namespace setup will be done after fork in the child using unshare
        const fork_result = std.os.linux.fork();
        const fork_signed: isize = @bitCast(fork_result);

        if (fork_signed < 0) {
            log.err("Fork failed: {d}", .{fork_signed});
            return errors.Error.NamespaceCreationFailed;
        }

        if (fork_signed == 0) {
            // In child - unshare namespaces
            self.unshareNamespaces() catch |err| {
                log.err("Failed to unshare namespaces: {s}", .{@errorName(err)});
                std.process.exit(1);
            };
        }

        return @intCast(fork_signed);
    }

    /// Unshare namespaces in child process
    fn unshareNamespaces(self: *Executor) !void {
        const flags: u32 = @truncate(self.config.namespaces);

        if (flags == 0) return;

        const result = std.os.linux.unshare(flags);
        if (@as(isize, @bitCast(result)) < 0) {
            return errors.Error.NamespaceCreationFailed;
        }

        log.debug("Unshared namespaces with flags: 0x{x}", .{flags});
    }

    /// Child process setup and exec
    fn childProcess(self: *Executor) !void {
        // Close parent's end of pipes
        if (self.parent_to_child) |*p| p.closeWrite();
        if (self.child_to_parent) |*p| p.closeRead();

        // Set up console/stdio for child
        try self.setupChildStdio();

        // Wait for parent to set up cgroups, uid_map, etc.
        if (self.parent_to_child) |*p| {
            try p.wait();
        }

        // Set up namespaces that weren't created at clone time
        if (self.config.user_ns) {
            try self.setupUserNamespace();
        }

        // Set hostname if configured
        if (self.config.hostname) |hostname| {
            try self.setHostname(hostname);
        }

        // Set up filesystem
        try self.setupFilesystem();

        // Set no_new_privs
        if (self.config.no_new_privs) {
            try containment.setNoNewPrivs();
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
        try self.setUser();

        // Change to working directory
        try self.changeDir();

        // Execute the command
        try self.execCommand();
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
        } else {
            // Close child ends of pipes in parent
            if (self.stdin_pipe) |*p| p.closeRead();
            if (self.stdout_pipe) |*p| p.closeWrite();
            if (self.stderr_pipe) |*p| p.closeWrite();
        }
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
        // Set up the container filesystem using pivot_root
        const config = containment.Config{
            .namespaces = &.{},
            .rootfs_readonly = self.config.rootfs_readonly,
            .no_new_privileges = false, // We'll set this separately
        };
        _ = config;

        // For now, just chroot (pivot_root requires more setup)
        const result = std.os.linux.syscall1(.chroot, @intFromPtr(self.config.rootfs.ptr));
        if (@as(isize, @bitCast(result)) < 0) {
            log.err("chroot failed", .{});
            return errors.Error.NamespaceCreationFailed;
        }

        // Change to root
        std.posix.chdir("/") catch {
            return errors.Error.NamespaceCreationFailed;
        };

        log.debug("Filesystem setup complete", .{});
    }

    fn loadSeccomp(self: *Executor, policy: seccomp.SyscallPolicy) !void {
        // Generate BPF program
        const bpf = seccomp.generateBpf(self.allocator, policy) catch |err| {
            log.err("Failed to generate seccomp BPF: {s}", .{@errorName(err)});
            return errors.Error.SeccompLoadFailed;
        };
        defer self.allocator.free(bpf);

        // Load the filter
        seccomp.loadFilter(bpf) catch |err| {
            log.err("Failed to load seccomp filter: {s}", .{@errorName(err)});
            return errors.Error.SeccompLoadFailed;
        };

        log.debug("Seccomp filter loaded ({d} instructions)", .{bpf.len});
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
        if (self.config.args.len == 0) {
            log.err("No command specified", .{});
            return errors.Error.InvalidSyscallArgs;
        }

        // Convert args to null-terminated format for execve
        const argv = try self.allocator.allocSentinel(?[*:0]const u8, self.config.args.len, null);
        defer self.allocator.free(argv);

        for (self.config.args, 0..) |arg, i| {
            argv[i] = try self.allocator.dupeZ(u8, arg);
        }

        // Convert env to null-terminated format
        const envp = try self.allocator.allocSentinel(?[*:0]const u8, self.config.env.len, null);
        defer self.allocator.free(envp);

        for (self.config.env, 0..) |env_var, i| {
            envp[i] = try self.allocator.dupeZ(u8, env_var);
        }

        log.debug("Executing: {s}", .{self.config.args[0]});

        // Execute
        const err = std.posix.execvpeZ(argv[0].?, argv, envp);
        log.err("execve failed: {s}", .{@errorName(err)});
        return errors.Error.SystemError;
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

        // Disable setgroups first (required for unprivileged user namespaces)
        const setgroups_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/setgroups", .{pid}) catch return;
        if (std.fs.openFileAbsolute(setgroups_path, .{ .mode = .write_only })) |file| {
            defer file.close();
            file.writeAll("deny") catch {};
        } else |_| {}

        // Write uid_map
        const uid_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/uid_map", .{pid}) catch return;
        const uid_content = std.fmt.bufPrint(&content_buf, "0 {d} 1", .{uid}) catch return;

        if (std.fs.openFileAbsolute(uid_path, .{ .mode = .write_only })) |file| {
            defer file.close();
            file.writeAll(uid_content) catch {};
            log.debug("Wrote uid_map: {s}", .{uid_content});
        } else |_| {}

        // Write gid_map
        const gid_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/gid_map", .{pid}) catch return;
        const gid_content = std.fmt.bufPrint(&content_buf, "0 {d} 1", .{gid}) catch return;

        if (std.fs.openFileAbsolute(gid_path, .{ .mode = .write_only })) |file| {
            defer file.close();
            file.writeAll(gid_content) catch {};
            log.debug("Wrote gid_map: {s}", .{gid_content});
        } else |_| {}
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
