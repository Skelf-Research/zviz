const std = @import("std");

/// Log levels for ZViz
pub const Level = enum {
    debug,
    info,
    warn,
    err,

    pub fn string(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

/// Global log level (can be set at runtime)
var current_level: Level = .info;

/// Output format
pub const Format = enum {
    text,
    json,
};

var current_format: Format = .text;

pub fn setLevel(level: Level) void {
    current_level = level;
}

pub fn setFormat(format: Format) void {
    current_format = format;
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    logImpl(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    logImpl(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logImpl(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    logImpl(.err, fmt, args);
}

fn logImpl(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) < @intFromEnum(current_level)) {
        return;
    }

    const stderr = std.fs.File.stderr();
    const timestamp = std.time.timestamp();
    var buf: [4096]u8 = undefined;

    switch (current_format) {
        .text => {
            const msg = std.fmt.bufPrint(&buf, "[{d}] [{s}] " ++ fmt ++ "\n", .{timestamp} ++ .{level.string()} ++ args) catch return;
            stderr.writeAll(msg) catch {};
        },
        .json => {
            const msg = std.fmt.bufPrint(&buf, "{{\"ts\":{d},\"level\":\"{s}\",\"msg\":\"" ++ fmt ++ "\"}}\n", .{timestamp} ++ .{level.string()} ++ args) catch return;
            stderr.writeAll(msg) catch {};
        },
    }
}

/// Structured audit log entry for broker decisions
pub const AuditEntry = struct {
    timestamp: i64,
    syscall_nr: i32,
    pid: i32,
    decision: Decision,
    rule_id: ?[]const u8,
    latency_ns: u64,
    error_code: ?i32,

    pub const Decision = enum {
        allow,
        deny,
        broker_allow,
        broker_deny,
    };

    pub fn log(self: AuditEntry) void {
        const stderr = std.fs.File.stderr();
        var buf: [1024]u8 = undefined;

        var pos: usize = 0;
        const base = std.fmt.bufPrint(buf[pos..], "{{\"ts\":{d},\"syscall\":{d},\"pid\":{d},\"decision\":\"{s}\",\"latency_ns\":{d}", .{
            self.timestamp,
            self.syscall_nr,
            self.pid,
            @tagName(self.decision),
            self.latency_ns,
        }) catch return;
        pos += base.len;

        if (self.rule_id) |rid| {
            const rule_part = std.fmt.bufPrint(buf[pos..], ",\"rule\":\"{s}\"", .{rid}) catch return;
            pos += rule_part.len;
        }
        if (self.error_code) |ec| {
            const err_part = std.fmt.bufPrint(buf[pos..], ",\"errno\":{d}", .{ec}) catch return;
            pos += err_part.len;
        }

        if (pos + 2 <= buf.len) {
            buf[pos] = '}';
            buf[pos + 1] = '\n';
            pos += 2;
        }

        stderr.writeAll(buf[0..pos]) catch {};
    }
};

test "log levels" {
    setLevel(.debug);
    debug("test debug message: {d}", .{42});
    info("test info message", .{});
    warn("test warn message", .{});
    err("test error message", .{});
}

test "audit entry" {
    const entry = AuditEntry{
        .timestamp = 1234567890,
        .syscall_nr = 257, // openat
        .pid = 1000,
        .decision = .broker_allow,
        .rule_id = "fs.read",
        .latency_ns = 50000,
        .error_code = null,
    };
    entry.log();
}
