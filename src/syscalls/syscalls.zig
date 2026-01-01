const std = @import("std");
pub const linux = @import("linux.zig");

/// Syscall handler result
pub const Result = union(enum) {
    /// Allow the syscall to proceed
    allow: void,
    /// Deny with specific errno
    deny: i32,
    /// Return a specific value (for fd injection)
    value: i64,
    /// Continue to next handler (for chained handlers)
    @"continue": void,
};

/// Syscall context for handlers
pub const Context = struct {
    /// Notification ID
    id: u64,
    /// Target process PID
    pid: i32,
    /// Syscall number
    nr: i32,
    /// Syscall arguments
    args: [6]u64,
    /// Allocator for temporary allocations
    allocator: std.mem.Allocator,

    /// Read a string argument from the target process
    pub fn readStringArg(self: Context, arg_index: usize, buf: []u8) ![]const u8 {
        if (arg_index >= 6) return error.InvalidArgIndex;
        const addr = self.args[arg_index];
        if (addr == 0) return error.NullPointer;
        return linux.readProcessString(self.pid, addr, buf);
    }

    /// Get argument as signed integer
    pub fn getArgSigned(self: Context, arg_index: usize) !i64 {
        if (arg_index >= 6) return error.InvalidArgIndex;
        return @bitCast(self.args[arg_index]);
    }

    /// Get argument as unsigned integer
    pub fn getArgUnsigned(self: Context, arg_index: usize) !u64 {
        if (arg_index >= 6) return error.InvalidArgIndex;
        return self.args[arg_index];
    }

    /// Get argument as file descriptor
    pub fn getArgFd(self: Context, arg_index: usize) !i32 {
        if (arg_index >= 6) return error.InvalidArgIndex;
        return @intCast(@as(i64, @bitCast(self.args[arg_index])));
    }

    /// Get argument as flags
    pub fn getArgFlags(self: Context, arg_index: usize) !u32 {
        if (arg_index >= 6) return error.InvalidArgIndex;
        return @truncate(self.args[arg_index]);
    }
};

/// Handler function type
pub const Handler = *const fn (ctx: Context) Result;

/// Syscall handler registry
pub const Registry = struct {
    handlers: std.AutoHashMap(i32, Handler),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .handlers = std.AutoHashMap(i32, Handler).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.handlers.deinit();
    }

    pub fn register(self: *Registry, syscall_nr: i32, handler: Handler) !void {
        try self.handlers.put(syscall_nr, handler);
    }

    pub fn get(self: *Registry, syscall_nr: i32) ?Handler {
        return self.handlers.get(syscall_nr);
    }
};

test "context read args" {
    // AT_FDCWD is -100, which as a u64 is 0xFFFFFFFFFFFFFF9C
    const AT_FDCWD_U64: u64 = @bitCast(@as(i64, linux.AT.FDCWD));
    const ctx = Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.openat,
        .args = .{ AT_FDCWD_U64, 0x12345678, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };

    const fd = try ctx.getArgFd(0);
    try std.testing.expectEqual(linux.AT.FDCWD, fd); // AT_FDCWD = -100

    const addr = try ctx.getArgUnsigned(1);
    try std.testing.expectEqual(@as(u64, 0x12345678), addr);
}
