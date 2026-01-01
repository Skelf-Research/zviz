//! Syscall Tester - Run inside containers to test actual syscall behavior
//!
//! Build: zig build-exe -target x86_64-linux-musl syscall_tester.zig
//! Usage: ./syscall_tester [test_name]
//!
//! This binary attempts various syscalls and reports success/failure.
//! Run it in both gVisor and ZigViz containers to compare outcomes.

const std = @import("std");

const TestResult = struct {
    name: []const u8,
    category: []const u8,
    allowed: bool,
    errno: ?i32 = null,
};

var results: [64]TestResult = undefined;
var result_count: usize = 0;

fn addResult(name: []const u8, category: []const u8, allowed: bool, errno: ?i32) void {
    if (result_count < results.len) {
        results[result_count] = .{
            .name = name,
            .category = category,
            .allowed = allowed,
            .errno = errno,
        };
        result_count += 1;
    }
}

// ============================================================================
// Syscall Tests
// ============================================================================

fn testGetpid() void {
    const result = std.os.linux.getpid();
    addResult("getpid", "syscall", result > 0, null);
}

fn testGetuid() void {
    const result = std.os.linux.getuid();
    addResult("getuid", "syscall", true, null);
    _ = result;
}

fn testMount() void {
    const result = std.os.linux.mount(null, "/mnt", "tmpfs", 0, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("mount", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testUnshareUserNs() void {
    const result = std.os.linux.unshare(0x10000000); // CLONE_NEWUSER
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("unshare_user_ns", "namespace", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testUnsharePidNs() void {
    const result = std.os.linux.unshare(0x20000000); // CLONE_NEWPID
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("unshare_pid_ns", "namespace", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testPtrace() void {
    // PTRACE_TRACEME = 0
    const result = std.os.linux.syscall4(.ptrace, 0, 0, 0, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("ptrace", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testBpf() void {
    const result = std.os.linux.syscall3(.bpf, 0, 0, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("bpf", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testInitModule() void {
    const result = std.os.linux.syscall3(.init_module, 0, 0, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("init_module", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testKexecLoad() void {
    const result = std.os.linux.syscall4(.kexec_load, 0, 0, 0, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("kexec_load", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testReboot() void {
    // Don't actually reboot - just test if syscall is allowed
    // LINUX_REBOOT_CMD_CAD_OFF = 0
    const result = std.os.linux.syscall4(.reboot, 0xfee1dead, 0x28121969, 0, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("reboot", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testUserfaultfd() void {
    const result = std.os.linux.syscall1(.userfaultfd, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("userfaultfd", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testPerfEventOpen() void {
    const result = std.os.linux.syscall5(.perf_event_open, 0, 0, @as(usize, @bitCast(@as(isize, -1))), @as(usize, @bitCast(@as(isize, -1))), 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));
    addResult("perf_event_open", "syscall", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

// ============================================================================
// Network Tests
// ============================================================================

fn testRawSocket() void {
    // AF_PACKET = 17, SOCK_RAW = 3
    const result = std.os.linux.socket(17, 3, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));

    if (@as(isize, @bitCast(result)) >= 0) {
        _ = std.os.linux.close(@intCast(result));
    }

    addResult("raw_socket", "network", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testNetlinkSocket() void {
    // AF_NETLINK = 16, SOCK_RAW = 3
    const result = std.os.linux.socket(16, 3, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));

    if (@as(isize, @bitCast(result)) >= 0) {
        _ = std.os.linux.close(@intCast(result));
    }

    addResult("netlink_socket", "network", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testTcpSocket() void {
    // AF_INET = 2, SOCK_STREAM = 1
    const result = std.os.linux.socket(2, 1, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));

    if (@as(isize, @bitCast(result)) >= 0) {
        _ = std.os.linux.close(@intCast(result));
    }

    addResult("tcp_socket", "network", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testUdpSocket() void {
    // AF_INET = 2, SOCK_DGRAM = 2
    const result = std.os.linux.socket(2, 2, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));

    if (@as(isize, @bitCast(result)) >= 0) {
        _ = std.os.linux.close(@intCast(result));
    }

    addResult("udp_socket", "network", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

fn testUnixSocket() void {
    // AF_UNIX = 1, SOCK_STREAM = 1
    const result = std.os.linux.socket(1, 1, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));

    if (@as(isize, @bitCast(result)) >= 0) {
        _ = std.os.linux.close(@intCast(result));
    }

    addResult("unix_socket", "network", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

// ============================================================================
// Filesystem Tests
// ============================================================================

fn testReadPasswd() void {
    const fd = std.os.linux.open("/etc/passwd", .{ .ACCMODE = .RDONLY }, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(fd)))));

    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = std.os.linux.close(@intCast(fd));
    }

    addResult("read_passwd", "filesystem", @as(isize, @bitCast(fd)) >= 0, if (errno != 0) errno else null);
}

fn testWritePasswd() void {
    const fd = std.os.linux.open("/etc/passwd", .{ .ACCMODE = .WRONLY }, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(fd)))));

    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = std.os.linux.close(@intCast(fd));
    }

    addResult("write_passwd", "filesystem", @as(isize, @bitCast(fd)) >= 0, if (errno != 0) errno else null);
}

fn testReadProcRoot() void {
    const fd = std.os.linux.open("/proc/1/root", .{ .ACCMODE = .RDONLY }, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(fd)))));

    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = std.os.linux.close(@intCast(fd));
    }

    addResult("proc_1_root", "filesystem", @as(isize, @bitCast(fd)) >= 0, if (errno != 0) errno else null);
}

fn testReadDevMem() void {
    const fd = std.os.linux.open("/dev/mem", .{ .ACCMODE = .RDONLY }, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(fd)))));

    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = std.os.linux.close(@intCast(fd));
    }

    addResult("dev_mem", "filesystem", @as(isize, @bitCast(fd)) >= 0, if (errno != 0) errno else null);
}

fn testReadDevNull() void {
    const fd = std.os.linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(fd)))));

    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = std.os.linux.close(@intCast(fd));
    }

    addResult("dev_null", "filesystem", @as(isize, @bitCast(fd)) >= 0, if (errno != 0) errno else null);
}

// ============================================================================
// Capability Tests
// ============================================================================

fn testCapset() void {
    const header = extern struct {
        version: u32 = 0x20080522,
        pid: i32 = 0,
    }{};

    const data = [2]extern struct {
        effective: u32 = 0xFFFFFFFF,
        permitted: u32 = 0xFFFFFFFF,
        inheritable: u32 = 0xFFFFFFFF,
    }{ .{}, .{} };

    const result = std.os.linux.syscall2(.capset, @intFromPtr(&header), @intFromPtr(&data));
    const errno: i32 = @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result)))));

    addResult("capset", "capability", @as(isize, @bitCast(result)) >= 0, if (errno != 0) errno else null);
}

// ============================================================================
// Output
// ============================================================================

fn writeStdout(data: []const u8) void {
    _ = std.os.linux.write(1, data.ptr, data.len);
}

fn printResults() void {
    var buf: [4096]u8 = undefined;

    writeStdout("{\n  \"results\": [\n");

    for (results[0..result_count], 0..) |r, i| {
        const allowed_str = if (r.allowed) "true" else "false";
        var errno_buf: [16]u8 = undefined;
        const errno_str = if (r.errno) |e|
            std.fmt.bufPrint(&errno_buf, "{d}", .{e}) catch "0"
        else
            "null";

        const line = std.fmt.bufPrint(&buf, "    {{\"name\": \"{s}\", \"category\": \"{s}\", \"allowed\": {s}, \"errno\": {s}}}", .{
            r.name,
            r.category,
            allowed_str,
            errno_str,
        }) catch continue;
        writeStdout(line);

        if (i < result_count - 1) {
            writeStdout(",\n");
        } else {
            writeStdout("\n");
        }
    }

    writeStdout("  ]\n}\n");
}

fn printHumanReadable() void {
    var buf: [256]u8 = undefined;

    writeStdout("=== Syscall Test Results ===\n\n");

    var allowed_count: usize = 0;
    var denied_count: usize = 0;

    for (results[0..result_count]) |r| {
        const status = if (r.allowed) "ALLOWED" else "DENIED ";
        var errno_buf: [32]u8 = undefined;
        const errno_str = if (r.errno) |e|
            std.fmt.bufPrint(&errno_buf, " (errno={d})", .{e}) catch ""
        else
            "";

        const line = std.fmt.bufPrint(&buf, "[{s}] {s}: {s}{s}\n", .{
            r.category,
            r.name,
            status,
            errno_str,
        }) catch continue;
        writeStdout(line);

        if (r.allowed) {
            allowed_count += 1;
        } else {
            denied_count += 1;
        }
    }

    const summary = std.fmt.bufPrint(&buf, "\nSummary: {d} allowed, {d} denied\n", .{ allowed_count, denied_count }) catch return;
    writeStdout(summary);
}

// ============================================================================
// Main
// ============================================================================

pub fn main() void {
    const args = std.process.argsAlloc(std.heap.page_allocator) catch return;
    defer std.process.argsFree(std.heap.page_allocator, args);

    var json_output = false;
    var run_all = true;
    var specific_test: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStdout(
                \\Syscall Tester - Test syscall behavior in container runtimes
                \\
                \\Usage: syscall_tester [options] [test_name]
                \\
                \\Options:
                \\  --json    Output results as JSON
                \\  --help    Show this help
                \\
                \\Tests: getpid, mount, ptrace, bpf, init_module, raw_socket, etc.
                \\
            );
            return;
        } else {
            specific_test = arg;
            run_all = false;
        }
    }

    // Run tests
    if (run_all or std.mem.eql(u8, specific_test orelse "", "getpid")) testGetpid();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "getuid")) testGetuid();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "mount")) testMount();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "unshare_user")) testUnshareUserNs();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "unshare_pid")) testUnsharePidNs();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "ptrace")) testPtrace();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "bpf")) testBpf();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "init_module")) testInitModule();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "kexec")) testKexecLoad();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "reboot")) testReboot();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "userfaultfd")) testUserfaultfd();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "perf")) testPerfEventOpen();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "raw_socket")) testRawSocket();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "netlink")) testNetlinkSocket();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "tcp_socket")) testTcpSocket();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "udp_socket")) testUdpSocket();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "unix_socket")) testUnixSocket();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "read_passwd")) testReadPasswd();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "write_passwd")) testWritePasswd();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "proc_root")) testReadProcRoot();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "dev_mem")) testReadDevMem();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "dev_null")) testReadDevNull();
    if (run_all or std.mem.eql(u8, specific_test orelse "", "capset")) testCapset();

    // Output results
    if (json_output) {
        printResults();
    } else {
        printHumanReadable();
    }
}
