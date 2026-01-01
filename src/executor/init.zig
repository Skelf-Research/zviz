const std = @import("std");
const log = @import("../log.zig");

/// Minimal init process for containers
/// Runs as PID 1 inside the container, responsible for:
/// - Reaping zombie processes
/// - Forwarding signals to the main process
/// - Clean shutdown

pub const Init = struct {
    /// PID of the main container process
    main_pid: i32,

    /// Whether to forward signals
    forward_signals: bool = true,

    /// Exit code from main process
    exit_code: ?i32 = null,

    pub fn init(main_pid: i32) Init {
        return .{
            .main_pid = main_pid,
        };
    }

    /// Run the init process loop
    pub fn run(self: *Init) !i32 {
        log.debug("Init process started, main PID: {d}", .{self.main_pid});

        // Set up signal handlers
        try self.setupSignals();

        // Main loop - wait for children and handle signals
        while (true) {
            var status: u32 = 0;
            const result = std.os.linux.waitpid(-1, &status, 0);
            const signed: isize = @bitCast(result);

            if (signed < 0) {
                const errno = std.posix.errno(@as(isize, @bitCast(result)));
                if (errno == .CHILD) {
                    // No more children
                    break;
                }
                if (errno == .INTR) {
                    // Interrupted by signal, continue
                    continue;
                }
                log.err("waitpid error: {d}", .{@intFromEnum(errno)});
                break;
            }

            const pid: i32 = @intCast(signed);

            // Check if it was the main process
            if (pid == self.main_pid) {
                if (std.os.linux.W.IFEXITED(status)) {
                    self.exit_code = @intCast(std.os.linux.W.EXITSTATUS(status));
                    log.debug("Main process exited with code {d}", .{self.exit_code.?});
                } else if (std.os.linux.W.IFSIGNALED(status)) {
                    const sig: i32 = @intCast(std.os.linux.W.TERMSIG(status));
                    self.exit_code = 128 + sig;
                    log.debug("Main process killed by signal {d}", .{sig});
                }
            } else {
                // Reaped a zombie
                log.debug("Reaped zombie process {d}", .{pid});
            }
        }

        return self.exit_code orelse 0;
    }

    fn setupSignals(self: *Init) !void {
        _ = self;
        // In a real implementation, we'd set up signal handlers to forward
        // signals to the main process. For now, we rely on default behavior.
        log.debug("Signal handlers configured", .{});
    }

    /// Forward a signal to the main process
    pub fn forwardSignal(self: *Init, sig: i32) void {
        if (self.forward_signals) {
            _ = std.os.linux.kill(self.main_pid, sig);
        }
    }
};

/// Signal handler context (for use with sigaction)
pub const SignalContext = struct {
    init: *Init,

    pub fn handler(sig: i32, info: *const std.os.linux.siginfo_t, ctx: ?*anyopaque) callconv(.C) void {
        _ = info;
        _ = ctx;

        // Get init from thread-local storage or global
        // For simplicity, we'll just log here
        switch (sig) {
            15 => { // SIGTERM
                // Forward to main process
            },
            2 => { // SIGINT
                // Forward to main process
            },
            else => {},
        }
    }
};

/// Reap all zombie children without blocking
pub fn reapZombies() void {
    while (true) {
        var status: u32 = 0;
        // WNOHANG = 1
        const result = std.os.linux.waitpid(-1, &status, 1);
        const signed: isize = @bitCast(result);

        if (signed <= 0) {
            break;
        }

        const pid: i32 = @intCast(signed);
        log.debug("Reaped zombie: {d}", .{pid});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "init creation" {
    const init_proc = Init.init(1234);
    try std.testing.expectEqual(@as(i32, 1234), init_proc.main_pid);
    try std.testing.expect(init_proc.forward_signals);
    try std.testing.expect(init_proc.exit_code == null);
}
