const std = @import("std");
const log = @import("../log.zig");

/// Escape-class test suite
/// These tests attempt to break out of the container sandbox.
/// All escape attempts should FAIL (be blocked by ZigViz).

// ============================================================================
// Test Result Types
// ============================================================================

pub const EscapeTestResult = struct {
    name: []const u8,
    description: []const u8,
    category: EscapeCategory,
    blocked: bool,
    error_code: ?i32 = null,
    details: ?[]const u8 = null,
};

pub const EscapeCategory = enum {
    namespace,
    capability,
    seccomp,
    filesystem,
    network,
    resource,
    toctou,

    pub fn string(self: EscapeCategory) []const u8 {
        return switch (self) {
            .namespace => "Namespace Breakout",
            .capability => "Capability Escalation",
            .seccomp => "Seccomp Bypass",
            .filesystem => "Filesystem Escape",
            .network => "Network Escape",
            .resource => "Resource Exhaustion",
            .toctou => "TOCTOU Attack",
        };
    }
};

pub const EscapeTestSuite = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayList(EscapeTestResult),
    passed: u32 = 0,
    failed: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) EscapeTestSuite {
        return .{
            .allocator = allocator,
            .results = .empty,
        };
    }

    pub fn deinit(self: *EscapeTestSuite) void {
        self.results.deinit(self.allocator);
    }

    pub fn addResult(self: *EscapeTestSuite, result: EscapeTestResult) !void {
        try self.results.append(self.allocator, result);
        if (result.blocked) {
            self.passed += 1;
        } else {
            self.failed += 1;
        }
    }

    pub fn printSummary(self: *const EscapeTestSuite) void {
        log.info("=== Escape Test Summary ===", .{});
        log.info("Total tests: {d}", .{self.passed + self.failed});
        log.info("Blocked (PASS): {d}", .{self.passed});
        log.info("Escaped (FAIL): {d}", .{self.failed});

        if (self.failed > 0) {
            log.err("SECURITY FAILURE: {d} escape attempts succeeded!", .{self.failed});
            for (self.results.items) |result| {
                if (!result.blocked) {
                    log.err("  - {s}: {s}", .{ result.name, result.description });
                }
            }
        } else {
            log.info("All escape attempts blocked - sandbox is secure", .{});
        }
    }
};

// ============================================================================
// Namespace Escape Tests
// ============================================================================

/// Test: Attempt to create new user namespace
pub fn testUnshareUserNs() EscapeTestResult {
    const result = std.os.linux.unshare(0x10000000); // CLONE_NEWUSER
    const blocked = @as(isize, @bitCast(result)) < 0;

    return .{
        .name = "unshare_user_ns",
        .description = "Attempt to create new user namespace",
        .category = .namespace,
        .blocked = blocked,
        .error_code = if (blocked) @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result))))) else null,
    };
}

/// Test: Attempt to create new PID namespace
pub fn testUnsharePidNs() EscapeTestResult {
    const result = std.os.linux.unshare(0x20000000); // CLONE_NEWPID
    const blocked = @as(isize, @bitCast(result)) < 0;

    return .{
        .name = "unshare_pid_ns",
        .description = "Attempt to create new PID namespace",
        .category = .namespace,
        .blocked = blocked,
        .error_code = if (blocked) @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result))))) else null,
    };
}

/// Test: Attempt to create new mount namespace
pub fn testUnshareMountNs() EscapeTestResult {
    const result = std.os.linux.unshare(0x00020000); // CLONE_NEWNS
    const blocked = @as(isize, @bitCast(result)) < 0;

    return .{
        .name = "unshare_mount_ns",
        .description = "Attempt to create new mount namespace",
        .category = .namespace,
        .blocked = blocked,
        .error_code = if (blocked) @intCast(@intFromEnum(std.posix.errno(@as(isize, @bitCast(result))))) else null,
    };
}

/// Test: Attempt to join host PID namespace via /proc/1/ns/pid
pub fn testSetnsHostPid() EscapeTestResult {
    const fd = std.os.linux.open("/proc/1/ns/pid", .{ .ACCMODE = .RDONLY }, 0);
    const fd_signed: isize = @bitCast(fd);

    if (fd_signed < 0) {
        return .{
            .name = "setns_host_pid",
            .description = "Attempt to join host PID namespace",
            .category = .namespace,
            .blocked = true,
            .details = "Cannot open /proc/1/ns/pid",
        };
    }

    const result = std.os.linux.syscall2(.setns, fd, 0x20000000); // CLONE_NEWPID
    _ = std.os.linux.close(@intCast(fd));

    return .{
        .name = "setns_host_pid",
        .description = "Attempt to join host PID namespace",
        .category = .namespace,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

// ============================================================================
// Capability Escalation Tests
// ============================================================================

/// Test: Attempt to set capabilities
pub fn testCapset() EscapeTestResult {
    // Try to get all capabilities
    const header = extern struct {
        version: u32 = 0x20080522, // _LINUX_CAPABILITY_VERSION_3
        pid: i32 = 0,
    }{};

    const data = [2]extern struct {
        effective: u32 = 0xFFFFFFFF,
        permitted: u32 = 0xFFFFFFFF,
        inheritable: u32 = 0xFFFFFFFF,
    }{ .{}, .{} };

    const result = std.os.linux.syscall2(.capset, @intFromPtr(&header), @intFromPtr(&data));

    return .{
        .name = "capset_all_caps",
        .description = "Attempt to escalate to all capabilities",
        .category = .capability,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

/// Test: Attempt to use prctl to set dumpable (can leak info)
pub fn testPrctlDumpable() EscapeTestResult {
    // PR_SET_DUMPABLE = 4
    const result = std.os.linux.syscall2(.prctl, 4, 1);
    // This might succeed but shouldn't be dangerous in isolation
    // More concerning prctl options would be PR_SET_SECCOMP etc.

    return .{
        .name = "prctl_dumpable",
        .description = "Set process as dumpable",
        .category = .capability,
        .blocked = @as(isize, @bitCast(result)) < 0,
        .details = "Dumpable allows core dumps that may leak secrets",
    };
}

/// Test: Attempt to disable seccomp via prctl
pub fn testPrctlSeccompDisable() EscapeTestResult {
    // PR_SET_SECCOMP = 22, SECCOMP_MODE_DISABLED = 0
    const result = std.os.linux.syscall2(.prctl, 22, 0);

    return .{
        .name = "prctl_seccomp_disable",
        .description = "Attempt to disable seccomp",
        .category = .seccomp,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

// ============================================================================
// Seccomp Bypass Tests
// ============================================================================

/// Test: Attempt to load kernel module
pub fn testInitModule() EscapeTestResult {
    const result = std.os.linux.syscall3(.init_module, 0, 0, 0);

    return .{
        .name = "init_module",
        .description = "Attempt to load kernel module",
        .category = .seccomp,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

/// Test: Attempt to use ptrace
pub fn testPtrace() EscapeTestResult {
    // PTRACE_TRACEME = 0
    const result = std.os.linux.syscall4(.ptrace, 0, 0, 0, 0);

    return .{
        .name = "ptrace",
        .description = "Attempt to use ptrace",
        .category = .seccomp,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

/// Test: Attempt to use BPF syscall
pub fn testBpf() EscapeTestResult {
    const result = std.os.linux.syscall3(.bpf, 0, 0, 0);

    return .{
        .name = "bpf_syscall",
        .description = "Attempt to use BPF syscall",
        .category = .seccomp,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

/// Test: Attempt to use userfaultfd
pub fn testUserfaultfd() EscapeTestResult {
    const result = std.os.linux.syscall1(.userfaultfd, 0);

    return .{
        .name = "userfaultfd",
        .description = "Attempt to use userfaultfd (potential for exploits)",
        .category = .seccomp,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

/// Test: Attempt to use kexec
pub fn testKexecLoad() EscapeTestResult {
    const result = std.os.linux.syscall4(.kexec_load, 0, 0, 0, 0);

    return .{
        .name = "kexec_load",
        .description = "Attempt to load new kernel",
        .category = .seccomp,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

// ============================================================================
// Filesystem Escape Tests
// ============================================================================

/// Test: Attempt to mount filesystem
pub fn testMount() EscapeTestResult {
    const result = std.os.linux.syscall5(.mount, 0, 0, 0, 0, 0);

    return .{
        .name = "mount",
        .description = "Attempt to mount filesystem",
        .category = .filesystem,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

/// Test: Attempt to access /proc/1/root (host root)
pub fn testProcHostRoot() EscapeTestResult {
    const fd = std.os.linux.open("/proc/1/root", .{ .ACCMODE = .RDONLY }, 0);

    return .{
        .name = "proc_host_root",
        .description = "Attempt to access host root via /proc/1/root",
        .category = .filesystem,
        .blocked = @as(isize, @bitCast(fd)) < 0,
    };
}

/// Test: Attempt to write to /etc/passwd
pub fn testWriteEtcPasswd() EscapeTestResult {
    const fd = std.os.linux.open("/etc/passwd", .{ .ACCMODE = .WRONLY }, 0);

    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = std.os.linux.close(@intCast(fd));
    }

    return .{
        .name = "write_etc_passwd",
        .description = "Attempt to write to /etc/passwd",
        .category = .filesystem,
        .blocked = @as(isize, @bitCast(fd)) < 0,
    };
}

/// Test: Attempt pivot_root
pub fn testPivotRoot() EscapeTestResult {
    const result = std.os.linux.syscall2(.pivot_root, 0, 0);

    return .{
        .name = "pivot_root",
        .description = "Attempt to change root filesystem",
        .category = .filesystem,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

// ============================================================================
// Network Escape Tests
// ============================================================================

/// Test: Attempt to create raw socket
pub fn testRawSocket() EscapeTestResult {
    // AF_PACKET = 17, SOCK_RAW = 3
    const result = std.os.linux.socket(17, 3, 0);

    if (@as(isize, @bitCast(result)) >= 0) {
        _ = std.os.linux.close(@intCast(result));
    }

    return .{
        .name = "raw_socket",
        .description = "Attempt to create raw socket",
        .category = .network,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

/// Test: Attempt to create netlink socket
pub fn testNetlinkSocket() EscapeTestResult {
    // AF_NETLINK = 16, SOCK_RAW = 3
    const result = std.os.linux.socket(16, 3, 0);

    if (@as(isize, @bitCast(result)) >= 0) {
        _ = std.os.linux.close(@intCast(result));
    }

    return .{
        .name = "netlink_socket",
        .description = "Attempt to create netlink socket",
        .category = .network,
        .blocked = @as(isize, @bitCast(result)) < 0,
    };
}

// ============================================================================
// Resource Exhaustion Tests
// ============================================================================

/// Test: Fork bomb detection (limited iterations)
pub fn testForkBomb(max_forks: u32) EscapeTestResult {
    var forked: u32 = 0;
    var failed = false;

    while (forked < max_forks) : (forked += 1) {
        const result = std.os.linux.fork();
        const signed: isize = @bitCast(result);

        if (signed < 0) {
            failed = true;
            break;
        }

        if (signed == 0) {
            // Child - exit immediately
            std.process.exit(0);
        }

        // Parent - collect zombie
        var status: u32 = 0;
        _ = std.os.linux.waitpid(@intCast(signed), &status, 0);
    }

    return .{
        .name = "fork_bomb",
        .description = "Attempt fork bomb (limited)",
        .category = .resource,
        .blocked = failed,
        .details = if (failed) "Fork limited by cgroup pids_max" else "Fork succeeded (cgroup limits may not be active)",
    };
}

// ============================================================================
// Run All Tests
// ============================================================================

/// Run all escape tests
pub fn runAllTests(allocator: std.mem.Allocator) !EscapeTestSuite {
    var suite = EscapeTestSuite.init(allocator);
    errdefer suite.deinit();

    log.info("=== Running Escape Tests ===", .{});

    // Namespace tests
    log.info("Testing namespace escapes...", .{});
    try suite.addResult(testUnshareUserNs());
    try suite.addResult(testUnsharePidNs());
    try suite.addResult(testUnshareMountNs());
    try suite.addResult(testSetnsHostPid());

    // Capability tests
    log.info("Testing capability escalation...", .{});
    try suite.addResult(testCapset());
    try suite.addResult(testPrctlDumpable());
    try suite.addResult(testPrctlSeccompDisable());

    // Seccomp tests
    log.info("Testing seccomp bypasses...", .{});
    try suite.addResult(testInitModule());
    try suite.addResult(testPtrace());
    try suite.addResult(testBpf());
    try suite.addResult(testUserfaultfd());
    try suite.addResult(testKexecLoad());

    // Filesystem tests
    log.info("Testing filesystem escapes...", .{});
    try suite.addResult(testMount());
    try suite.addResult(testProcHostRoot());
    try suite.addResult(testWriteEtcPasswd());
    try suite.addResult(testPivotRoot());

    // Network tests
    log.info("Testing network escapes...", .{});
    try suite.addResult(testRawSocket());
    try suite.addResult(testNetlinkSocket());

    // Resource tests (skip fork bomb in regular testing)
    // try suite.addResult(testForkBomb(100));

    suite.printSummary();
    return suite;
}

// ============================================================================
// Tests
// ============================================================================

test "escape test result creation" {
    const result = EscapeTestResult{
        .name = "test",
        .description = "Test escape",
        .category = .namespace,
        .blocked = true,
    };

    try std.testing.expectEqualStrings("test", result.name);
    try std.testing.expect(result.blocked);
}

test "escape test suite" {
    var suite = EscapeTestSuite.init(std.testing.allocator);
    defer suite.deinit();

    try suite.addResult(.{
        .name = "test1",
        .description = "Blocked test",
        .category = .seccomp,
        .blocked = true,
    });

    try suite.addResult(.{
        .name = "test2",
        .description = "Unblocked test",
        .category = .seccomp,
        .blocked = false,
    });

    try std.testing.expectEqual(@as(u32, 1), suite.passed);
    try std.testing.expectEqual(@as(u32, 1), suite.failed);
}
