//! ZViz Container Executor Module
//!
//! This module provides the complete container execution infrastructure:
//! - Process creation with fork/clone and namespaces
//! - Seccomp filter loading
//! - PTY/console support for interactive containers
//! - OCI hooks execution
//! - Init process for PID 1 responsibilities
//!
//! Usage:
//! ```zig
//! const executor = @import("executor/mod.zig");
//!
//! var exec = executor.Executor.init(allocator, .{
//!     .container_id = "mycontainer",
//!     .rootfs = "/var/lib/containers/mycontainer/rootfs",
//!     .args = &.{"/bin/sh"},
//!     .terminal = true,
//! });
//! defer exec.deinit();
//!
//! const exit_code = try exec.run();
//! ```

const std = @import("std");

// Re-export all submodules
pub const executor = @import("executor.zig");
pub const console = @import("console.zig");
pub const hooks = @import("hooks.zig");
pub const init = @import("init.zig");

// Convenient type aliases
pub const Executor = executor.Executor;
pub const ExecConfig = executor.ExecConfig;
pub const CloneFlags = executor.CloneFlags;
pub const SyncPipe = executor.SyncPipe;

pub const Console = console.Console;
pub const Pty = console.Pty;
pub const ConsoleSocket = console.ConsoleSocket;
pub const Winsize = console.Winsize;

pub const Hook = hooks.Hook;
pub const Hooks = hooks.Hooks;
pub const HookExecutor = hooks.HookExecutor;
pub const ContainerState = hooks.ContainerState;

pub const Init = init.Init;

// ============================================================================
// High-level container execution API
// ============================================================================

/// Container execution options combining all settings
pub const ContainerOptions = struct {
    /// Container identifier
    id: []const u8,

    /// Bundle path containing config.json and rootfs
    bundle: []const u8,

    /// Root filesystem path (relative to bundle or absolute)
    rootfs: ?[]const u8 = null,

    /// Command to execute
    args: []const []const u8,

    /// Environment variables
    env: []const []const u8 = &.{},

    /// Working directory
    cwd: []const u8 = "/",

    /// User and group
    uid: u32 = 0,
    gid: u32 = 0,

    /// Terminal allocation
    terminal: bool = false,

    /// Console socket path for PTY master
    console_socket: ?[]const u8 = null,

    /// PID file path
    pid_file: ?[]const u8 = null,

    /// Hooks to execute
    hooks: Hooks = .{},

    /// Detach after start (daemonize)
    detach: bool = false,

    /// No pivot_root (use chroot instead)
    no_pivot: bool = false,

    /// No new privileges
    no_new_privs: bool = true,

    /// Readonly rootfs
    rootfs_readonly: bool = true,

    /// Hostname
    hostname: ?[]const u8 = null,
};

/// Execute a container with full lifecycle management
pub fn execute(allocator: std.mem.Allocator, options: ContainerOptions) !i32 {
    const log = @import("../log.zig");

    // Determine rootfs path
    const rootfs = options.rootfs orelse blk: {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/rootfs", .{options.bundle}) catch {
            return error.InvalidBundlePath;
        };
        break :blk path;
    };

    // Build executor config
    const config = ExecConfig{
        .container_id = options.id,
        .rootfs = rootfs,
        .args = options.args,
        .env = options.env,
        .cwd = options.cwd,
        .uid = options.uid,
        .gid = options.gid,
        .terminal = options.terminal,
        .no_new_privs = options.no_new_privs,
        .rootfs_readonly = options.rootfs_readonly,
        .hostname = options.hostname,
    };

    var exec = Executor.init(allocator, config);
    defer exec.deinit();

    // Set up console if needed
    var con: ?Console = null;
    if (options.terminal) {
        con = Console.init(allocator);
        try con.?.createPty();

        // Send PTY master to console socket if specified
        if (options.console_socket) |socket_path| {
            var socket = ConsoleSocket.init(allocator, socket_path);
            defer socket.deinit();

            if (con.?.getMasterFd()) |master_fd| {
                try socket.sendMasterFd(master_fd);
            }
        }
    }
    defer if (con) |*c| c.deinit();

    // Create hook executor
    var hook_exec = HookExecutor.init(allocator, .{
        .id = options.id,
        .status = .creating,
        .bundle = options.bundle,
    });

    // Run createRuntime hooks
    try hook_exec.runCreateRuntime(options.hooks);

    // Execute the container
    log.info("Starting container: {s}", .{options.id});

    const exit_code = exec.run() catch |err| {
        log.err("Container execution failed: {s}", .{@errorName(err)});

        // Run poststop hooks even on failure
        hook_exec.runPoststop(options.hooks) catch |hook_err| {
            log.warn("Poststop hooks failed: {s}", .{@errorName(hook_err)});
        };

        return err;
    };

    // Update hook state with PID
    if (exec.child_pid) |pid| {
        hook_exec.state.pid = pid;
    }

    // Run poststart hooks
    hook_exec.runPoststart(options.hooks) catch |err| {
        log.warn("Poststart hooks failed: {s}", .{@errorName(err)});
    };

    // Write PID file if specified
    if (options.pid_file) |pid_path| {
        if (exec.child_pid) |pid| {
            writePidFile(pid_path, pid) catch |err| {
                log.warn("Failed to write PID file: {s}", .{@errorName(err)});
            };
        }
    }

    // Run poststop hooks
    hook_exec.runPoststop(options.hooks) catch |err| {
        log.warn("Poststop hooks failed: {s}", .{@errorName(err)});
    };

    return exit_code;
}

/// Write PID to a file
fn writePidFile(path: []const u8, pid: i32) !void {
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    var buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return error.FormatError;
    try file.writeAll(pid_str);
}

// ============================================================================
// Tests
// ============================================================================

test "container options defaults" {
    const options = ContainerOptions{
        .id = "test",
        .bundle = "/var/run/containers/test",
        .args = &.{"/bin/sh"},
    };

    try std.testing.expectEqualStrings("/", options.cwd);
    try std.testing.expect(!options.terminal);
    try std.testing.expect(options.no_new_privs);
}

test "module exports" {
    // Verify all types are accessible
    _ = Executor;
    _ = ExecConfig;
    _ = Console;
    _ = Pty;
    _ = Hook;
    _ = Hooks;
    _ = Init;
}

test {
    // Run tests from all submodules
    std.testing.refAllDecls(@This());
}
