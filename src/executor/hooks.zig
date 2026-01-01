const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");

/// OCI Runtime Hooks
/// Implements the hook execution mechanism as defined by the OCI runtime spec
///
/// Hooks are executed at specific lifecycle stages:
/// - createRuntime: After container created, before pivot_root
/// - createContainer: After pivot_root, before start
/// - startContainer: After start command, before user process
/// - poststart: After user process started
/// - poststop: After container stopped

// ============================================================================
// Hook definitions
// ============================================================================

pub const Hook = struct {
    /// Path to the hook executable (must be absolute)
    path: []const u8,

    /// Arguments to pass to the hook
    args: []const []const u8 = &.{},

    /// Environment variables
    env: []const []const u8 = &.{},

    /// Timeout in seconds (0 = no timeout)
    timeout: u32 = 0,
};

pub const Hooks = struct {
    /// Hooks run after the container has been created but before pivot_root
    createRuntime: []const Hook = &.{},

    /// Hooks run after pivot_root but before start
    createContainer: []const Hook = &.{},

    /// Hooks run before the user specified process is executed
    startContainer: []const Hook = &.{},

    /// Hooks run after the user process is started
    poststart: []const Hook = &.{},

    /// Hooks run after the container process exits
    poststop: []const Hook = &.{},
};

// ============================================================================
// Container state for hook input
// ============================================================================

pub const ContainerState = struct {
    oci_version: []const u8 = "1.0.0",
    id: []const u8,
    status: Status,
    pid: ?i32 = null,
    bundle: []const u8,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,

    pub const Status = enum {
        creating,
        created,
        running,
        stopped,

        pub fn toString(self: Status) []const u8 {
            return switch (self) {
                .creating => "creating",
                .created => "created",
                .running => "running",
                .stopped => "stopped",
            };
        }
    };

    /// Serialize state to JSON for hook stdin
    pub fn toJson(self: *const ContainerState, allocator: std.mem.Allocator) ![]u8 {
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        try writer.writeAll("{");
        try writer.print("\"ociVersion\":\"{s}\",", .{self.oci_version});
        try writer.print("\"id\":\"{s}\",", .{self.id});
        try writer.print("\"status\":\"{s}\",", .{self.status.toString()});

        if (self.pid) |pid| {
            try writer.print("\"pid\":{d},", .{pid});
        }

        try writer.print("\"bundle\":\"{s}\"", .{self.bundle});

        if (self.annotations) |annotations| {
            try writer.writeAll(",\"annotations\":{");
            var first = true;
            var iter = annotations.map.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                try writer.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            }
            try writer.writeAll("}");
        }

        try writer.writeAll("}");

        const result = try allocator.alloc(u8, stream.pos);
        @memcpy(result, buf[0..stream.pos]);
        return result;
    }
};

// ============================================================================
// Hook executor
// ============================================================================

pub const HookExecutor = struct {
    allocator: std.mem.Allocator,
    state: ContainerState,

    pub fn init(allocator: std.mem.Allocator, state: ContainerState) HookExecutor {
        return .{
            .allocator = allocator,
            .state = state,
        };
    }

    /// Execute a set of hooks in order
    pub fn executeHooks(self: *HookExecutor, hooks: []const Hook) !void {
        for (hooks, 0..) |hook, i| {
            log.debug("Executing hook {d}/{d}: {s}", .{ i + 1, hooks.len, hook.path });
            try self.executeHook(hook);
        }
    }

    /// Execute a single hook
    pub fn executeHook(self: *HookExecutor, hook: Hook) !void {
        // Serialize state to JSON
        const state_json = try self.state.toJson(self.allocator);
        defer self.allocator.free(state_json);

        // Fork to execute hook
        const fork_result = std.os.linux.fork();
        const fork_signed: isize = @bitCast(fork_result);

        if (fork_signed < 0) {
            return errors.Error.SystemError;
        }

        if (fork_signed == 0) {
            // Child process - execute the hook
            self.childExecuteHook(hook, state_json) catch {
                std.process.exit(1);
            };
            unreachable;
        }

        // Parent - wait for child with timeout
        const pid: i32 = @intCast(fork_signed);
        try self.waitForHook(pid, hook.timeout);
    }

    fn childExecuteHook(self: *HookExecutor, hook: Hook, state_json: []const u8) !void {
        _ = self;

        // Set up stdin pipe for state JSON
        var stdin_pipe: [2]i32 = undefined;
        const pipe_result = std.os.linux.pipe2(&stdin_pipe, .{});
        if (@as(isize, @bitCast(pipe_result)) < 0) {
            return error.PipeCreationFailed;
        }

        // Fork again to write to stdin
        const writer_fork = std.os.linux.fork();
        const writer_signed: isize = @bitCast(writer_fork);

        if (writer_signed == 0) {
            // Writer child - write state to pipe and exit
            _ = std.os.linux.close(@intCast(stdin_pipe[0]));
            _ = std.os.linux.write(@intCast(stdin_pipe[1]), state_json.ptr, state_json.len);
            _ = std.os.linux.close(@intCast(stdin_pipe[1]));
            std.process.exit(0);
        }

        // Executor child
        _ = std.os.linux.close(@intCast(stdin_pipe[1]));

        // Dup pipe read to stdin
        _ = std.os.linux.dup2(@intCast(stdin_pipe[0]), 0);
        _ = std.os.linux.close(@intCast(stdin_pipe[0]));

        // Build argv
        const argv_len = if (hook.args.len > 0) hook.args.len else 1;
        const argv = std.heap.page_allocator.allocSentinel(?[*:0]const u8, argv_len, null) catch {
            return error.OutOfMemory;
        };

        if (hook.args.len > 0) {
            for (hook.args, 0..) |arg, i| {
                argv[i] = std.heap.page_allocator.dupeZ(u8, arg) catch return error.OutOfMemory;
            }
        } else {
            argv[0] = std.heap.page_allocator.dupeZ(u8, hook.path) catch return error.OutOfMemory;
        }

        // Build envp
        const envp = std.heap.page_allocator.allocSentinel(?[*:0]const u8, hook.env.len, null) catch {
            return error.OutOfMemory;
        };

        for (hook.env, 0..) |env_var, i| {
            envp[i] = std.heap.page_allocator.dupeZ(u8, env_var) catch return error.OutOfMemory;
        }

        // Execute - this only returns if exec fails
        const path_z = std.heap.page_allocator.dupeZ(u8, hook.path) catch return error.OutOfMemory;
        std.posix.execvpeZ(path_z, argv, envp) catch {
            std.process.exit(1);
        };
        unreachable;
    }

    fn waitForHook(self: *HookExecutor, pid: i32, timeout: u32) !void {
        _ = self;

        if (timeout == 0) {
            // No timeout, just wait
            var status: u32 = 0;
            while (true) {
                const result = std.os.linux.waitpid(pid, &status, 0);
                const signed: isize = @bitCast(result);
                if (signed < 0) {
                    const errno = std.posix.errno(@as(isize, @bitCast(result)));
                    if (errno == .INTR) continue;
                    return errors.Error.SystemError;
                }
                break;
            }

            if (std.os.linux.W.IFEXITED(status)) {
                const exit_code = std.os.linux.W.EXITSTATUS(status);
                if (exit_code != 0) {
                    log.err("Hook exited with code {d}", .{exit_code});
                    return errors.Error.HookError;
                }
            } else {
                log.err("Hook terminated abnormally", .{});
                return errors.Error.HookError;
            }
        } else {
            // Wait with timeout using WNOHANG and sleep
            const timeout_ns = @as(u64, timeout) * std.time.ns_per_s;
            var elapsed: u64 = 0;
            const sleep_interval: u64 = 100 * std.time.ns_per_ms; // 100ms

            while (elapsed < timeout_ns) {
                var status: u32 = 0;
                const result = std.os.linux.waitpid(pid, &status, 1); // WNOHANG
                const signed: isize = @bitCast(result);

                if (signed > 0) {
                    // Child exited
                    if (std.os.linux.W.IFEXITED(status)) {
                        const exit_code = std.os.linux.W.EXITSTATUS(status);
                        if (exit_code != 0) {
                            log.err("Hook exited with code {d}", .{exit_code});
                            return errors.Error.HookError;
                        }
                    }
                    return; // Success
                }

                if (signed < 0) {
                    const errno = std.posix.errno(@as(isize, @bitCast(result)));
                    if (errno != .INTR) {
                        return errors.Error.SystemError;
                    }
                }

                // Sleep and retry
                std.Thread.sleep(sleep_interval);
                elapsed += sleep_interval;
            }

            // Timeout - kill the hook
            log.err("Hook timed out after {d}s", .{timeout});
            _ = std.os.linux.kill(pid, 9); // SIGKILL

            // Reap the child
            var status: u32 = 0;
            _ = std.os.linux.waitpid(pid, &status, 0);

            return errors.Error.HookError;
        }
    }

    // ========================================================================
    // Convenience methods for each hook phase
    // ========================================================================

    pub fn runCreateRuntime(self: *HookExecutor, hooks: Hooks) !void {
        if (hooks.createRuntime.len > 0) {
            log.debug("Running createRuntime hooks", .{});
            try self.executeHooks(hooks.createRuntime);
        }
    }

    pub fn runCreateContainer(self: *HookExecutor, hooks: Hooks) !void {
        if (hooks.createContainer.len > 0) {
            log.debug("Running createContainer hooks", .{});
            try self.executeHooks(hooks.createContainer);
        }
    }

    pub fn runStartContainer(self: *HookExecutor, hooks: Hooks) !void {
        if (hooks.startContainer.len > 0) {
            log.debug("Running startContainer hooks", .{});
            try self.executeHooks(hooks.startContainer);
        }
    }

    pub fn runPoststart(self: *HookExecutor, hooks: Hooks) !void {
        if (hooks.poststart.len > 0) {
            log.debug("Running poststart hooks", .{});
            self.state.status = .running;
            try self.executeHooks(hooks.poststart);
        }
    }

    pub fn runPoststop(self: *HookExecutor, hooks: Hooks) !void {
        if (hooks.poststop.len > 0) {
            log.debug("Running poststop hooks", .{});
            self.state.status = .stopped;
            try self.executeHooks(hooks.poststop);
        }
    }
};

// ============================================================================
// Prestart hooks (deprecated but still supported)
// ============================================================================

pub const PrestartHooks = struct {
    /// Execute prestart hooks (run in runtime namespace)
    pub fn execute(allocator: std.mem.Allocator, hooks: []const Hook, state: ContainerState) !void {
        var executor = HookExecutor.init(allocator, state);
        try executor.executeHooks(hooks);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "container state to json" {
    const state = ContainerState{
        .id = "test-container",
        .status = .running,
        .pid = 1234,
        .bundle = "/var/run/containers/test",
    };

    const json = try state.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "test-container") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1234") != null);
}

test "hook definition" {
    const hook = Hook{
        .path = "/usr/bin/test-hook",
        .args = &.{ "/usr/bin/test-hook", "--verbose" },
        .env = &.{"FOO=bar"},
        .timeout = 30,
    };

    try std.testing.expectEqualStrings("/usr/bin/test-hook", hook.path);
    try std.testing.expectEqual(@as(usize, 2), hook.args.len);
    try std.testing.expectEqual(@as(u32, 30), hook.timeout);
}

test "hooks struct" {
    const hooks = Hooks{
        .poststart = &.{
            Hook{ .path = "/hook1" },
            Hook{ .path = "/hook2" },
        },
    };

    try std.testing.expectEqual(@as(usize, 2), hooks.poststart.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.poststop.len);
}

test "status to string" {
    try std.testing.expectEqualStrings("creating", ContainerState.Status.creating.toString());
    try std.testing.expectEqualStrings("created", ContainerState.Status.created.toString());
    try std.testing.expectEqualStrings("running", ContainerState.Status.running.toString());
    try std.testing.expectEqualStrings("stopped", ContainerState.Status.stopped.toString());
}
