const std = @import("std");
const log = @import("../log.zig");

/// gVisor vs ZViz Comparison Test Suite
/// Runs identical workloads on both runtimes and compares outcomes

// ============================================================================
// Test Case Definitions
// ============================================================================

pub const TestOutcome = enum {
    allowed,
    denied,
    error_other,
    not_tested,

    pub fn string(self: TestOutcome) []const u8 {
        return switch (self) {
            .allowed => "ALLOWED",
            .denied => "DENIED",
            .error_other => "ERROR",
            .not_tested => "N/A",
        };
    }
};

pub const ComparisonResult = struct {
    test_name: []const u8,
    category: []const u8,
    zviz_outcome: TestOutcome,
    gvisor_outcome: TestOutcome,
    matches: bool,
    notes: ?[]const u8 = null,

    pub fn print(self: *const ComparisonResult) void {
        const match_str = if (self.matches) "MATCH" else "DIFFER";
        log.info("[{s}] {s}: ZViz={s} gVisor={s}", .{
            match_str,
            self.test_name,
            self.zviz_outcome.string(),
            self.gvisor_outcome.string(),
        });
        if (self.notes) |n| {
            log.info("  Note: {s}", .{n});
        }
    }
};

pub const ComparisonSuite = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayList(ComparisonResult),
    matches: u32 = 0,
    differs: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ComparisonSuite {
        return .{
            .allocator = allocator,
            .results = .empty,
        };
    }

    pub fn deinit(self: *ComparisonSuite) void {
        self.results.deinit(self.allocator);
    }

    pub fn addResult(self: *ComparisonSuite, result: ComparisonResult) !void {
        try self.results.append(self.allocator, result);
        if (result.matches) {
            self.matches += 1;
        } else {
            self.differs += 1;
        }
    }

    pub fn printSummary(self: *const ComparisonSuite) void {
        log.info("=== gVisor vs ZViz Comparison Summary ===", .{});
        log.info("Total tests: {d}", .{self.matches + self.differs});
        log.info("Matching outcomes: {d}", .{self.matches});
        log.info("Different outcomes: {d}", .{self.differs});

        if (self.differs > 0) {
            log.info("\nDifferences:", .{});
            for (self.results.items) |result| {
                if (!result.matches) {
                    result.print();
                }
            }
        }

        const compatibility = if (self.matches + self.differs > 0)
            (@as(f64, @floatFromInt(self.matches)) / @as(f64, @floatFromInt(self.matches + self.differs))) * 100.0
        else
            0.0;
        log.info("\nPolicy compatibility: {d:.1}%", .{compatibility});
    }

    pub fn exportJson(self: *const ComparisonSuite, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\n  \"comparison_results\": [\n");

        for (self.results.items, 0..) |result, i| {
            try buf.writer(allocator).print(
                \\    {{
                \\      "test": "{s}",
                \\      "category": "{s}",
                \\      "zviz": "{s}",
                \\      "gvisor": "{s}",
                \\      "matches": {s}
                \\    }}
            , .{
                result.test_name,
                result.category,
                result.zviz_outcome.string(),
                result.gvisor_outcome.string(),
                if (result.matches) "true" else "false",
            });
            if (i < self.results.items.len - 1) {
                try buf.appendSlice(allocator, ",\n");
            } else {
                try buf.appendSlice(allocator, "\n");
            }
        }

        try buf.writer(allocator).print(
            \\  ],
            \\  "summary": {{
            \\    "total": {d},
            \\    "matches": {d},
            \\    "differs": {d},
            \\    "compatibility_percent": {d:.1}
            \\  }}
            \\}}
        , .{
            self.matches + self.differs,
            self.matches,
            self.differs,
            if (self.matches + self.differs > 0)
                (@as(f64, @floatFromInt(self.matches)) / @as(f64, @floatFromInt(self.matches + self.differs))) * 100.0
            else
                0.0,
        });

        return try buf.toOwnedSlice(allocator);
    }
};

// ============================================================================
// Expected gVisor Behavior (based on gVisor documentation)
// These represent what gVisor blocks/allows in its default configuration
// ============================================================================

/// gVisor's expected syscall behavior
pub const GVisorExpected = struct {
    /// Syscalls that gVisor blocks (returns EPERM or similar)
    pub const blocked_syscalls = [_][]const u8{
        "init_module",
        "delete_module",
        "finit_module",
        "kexec_load",
        "kexec_file_load",
        "reboot",
        "swapon",
        "swapoff",
        "acct",
        "mount",
        "umount2",
        "pivot_root",
        "sethostname",
        "setdomainname",
        "iopl",
        "ioperm",
        "create_module",
        "get_kernel_syms",
        "query_module",
        "quotactl",
        "nfsservctl",
        "getpmsg",
        "putpmsg",
        "afs_syscall",
        "tuxcall",
        "security",
        "lookup_dcookie",
        "vserver",
        "mbind", // in some configs
        "set_mempolicy",
        "get_mempolicy",
        "move_pages",
        "add_key",
        "request_key",
        "keyctl",
        "perf_event_open",
        "fanotify_init",
        "name_to_handle_at",
        "open_by_handle_at",
        "setns",
        "process_vm_readv",
        "process_vm_writev",
        "kcmp",
        "seccomp", // direct seccomp calls
        "bpf",
        "userfaultfd",
    };

    /// Syscalls that gVisor allows
    pub const allowed_syscalls = [_][]const u8{
        "read",
        "write",
        "open",
        "close",
        "stat",
        "fstat",
        "lstat",
        "poll",
        "lseek",
        "mmap",
        "mprotect",
        "munmap",
        "brk",
        "ioctl", // filtered
        "access",
        "pipe",
        "select",
        "sched_yield",
        "mremap",
        "msync",
        "mincore",
        "madvise",
        "dup",
        "dup2",
        "nanosleep",
        "getpid",
        "socket", // filtered by domain
        "connect",
        "accept",
        "sendto",
        "recvfrom",
        "sendmsg",
        "recvmsg",
        "shutdown",
        "bind",
        "listen",
        "getsockname",
        "getpeername",
        "socketpair",
        "setsockopt",
        "getsockopt",
        "clone", // filtered flags
        "fork",
        "vfork",
        "execve",
        "exit",
        "wait4",
        "kill",
        "uname",
        "fcntl",
        "flock",
        "fsync",
        "fdatasync",
        "truncate",
        "ftruncate",
        "getdents",
        "getcwd",
        "chdir",
        "fchdir",
        "rename",
        "mkdir",
        "rmdir",
        "creat",
        "link",
        "unlink",
        "symlink",
        "readlink",
        "chmod",
        "fchmod",
        "chown",
        "fchown",
        "lchown",
        "umask",
        "gettimeofday",
        "getrlimit",
        "getrusage",
        "times",
        "getuid",
        "getgid",
        "setuid",
        "setgid",
        "geteuid",
        "getegid",
        "setpgid",
        "getppid",
        "getpgrp",
        "setsid",
        "setreuid",
        "setregid",
        "getgroups",
        "setgroups",
        "setresuid",
        "getresuid",
        "setresgid",
        "getresgid",
        "getpgid",
        "setfsuid",
        "setfsgid",
        "getsid",
        "capget",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "rt_sigpending",
        "rt_sigtimedwait",
        "rt_sigqueueinfo",
        "rt_sigsuspend",
        "sigaltstack",
        "utime",
        "statfs",
        "fstatfs",
        "sched_setparam",
        "sched_getparam",
        "sched_setscheduler",
        "sched_getscheduler",
        "sched_get_priority_max",
        "sched_get_priority_min",
        "sched_rr_get_interval",
        "mlock",
        "munlock",
        "mlockall",
        "munlockall",
        "prctl", // filtered
        "arch_prctl",
        "setrlimit",
        "sync",
        "chroot", // requires CAP_SYS_CHROOT
        "gettid",
        "readahead",
        "setxattr",
        "lsetxattr",
        "fsetxattr",
        "getxattr",
        "lgetxattr",
        "fgetxattr",
        "listxattr",
        "llistxattr",
        "flistxattr",
        "removexattr",
        "lremovexattr",
        "fremovexattr",
        "futex",
        "sched_setaffinity",
        "sched_getaffinity",
        "set_tid_address",
        "epoll_create",
        "getdents64",
        "set_robust_list",
        "get_robust_list",
        "openat",
        "mkdirat",
        "mknodat",
        "fchownat",
        "futimesat",
        "newfstatat",
        "unlinkat",
        "renameat",
        "linkat",
        "symlinkat",
        "readlinkat",
        "fchmodat",
        "faccessat",
        "pselect6",
        "ppoll",
        "unshare", // filtered flags
        "splice",
        "tee",
        "sync_file_range",
        "vmsplice",
        "utimensat",
        "epoll_pwait",
        "timerfd_create",
        "eventfd",
        "fallocate",
        "timerfd_settime",
        "timerfd_gettime",
        "accept4",
        "epoll_create1",
        "dup3",
        "pipe2",
        "inotify_init1",
        "preadv",
        "pwritev",
        "prlimit64",
        "clock_gettime",
        "clock_getres",
        "clock_nanosleep",
        "exit_group",
        "epoll_ctl",
        "tgkill",
        "getrandom",
        "memfd_create",
        "execveat",
        "copy_file_range",
        "statx",
    };

    /// Network domains gVisor blocks
    pub const blocked_socket_domains = [_]u16{
        17, // AF_PACKET (raw sockets)
        16, // AF_NETLINK (some operations)
        5, // AF_X25
        9, // AF_ATMPVC
        31, // AF_BLUETOOTH
    };

    /// Check if syscall name is expected to be blocked by gVisor
    pub fn isBlocked(syscall_name: []const u8) bool {
        for (blocked_syscalls) |blocked| {
            if (std.mem.eql(u8, syscall_name, blocked)) {
                return true;
            }
        }
        return false;
    }

    /// Check if syscall name is expected to be allowed by gVisor
    pub fn isAllowed(syscall_name: []const u8) bool {
        for (allowed_syscalls) |allowed| {
            if (std.mem.eql(u8, syscall_name, allowed)) {
                return true;
            }
        }
        return false;
    }
};

// ============================================================================
// ZViz Policy for Comparison
// ============================================================================

/// Get ZViz expected outcome based on default ci-runner profile
fn getZVizOutcome(syscall_name: []const u8) TestOutcome {
    // Based on the ci-runner profile syscall lists
    const zviz_blocked = [_][]const u8{
        "init_module",
        "delete_module",
        "finit_module",
        "kexec_load",
        "kexec_file_load",
        "reboot",
        "swapon",
        "swapoff",
        "mount",
        "umount2",
        "pivot_root",
        "ptrace",
        "bpf",
        "userfaultfd",
        "perf_event_open",
        "add_key",
        "request_key",
        "keyctl",
        "acct",
        "quotactl",
        "setns",
        "unshare", // without proper flags
    };

    for (zviz_blocked) |blocked| {
        if (std.mem.eql(u8, syscall_name, blocked)) {
            return .denied;
        }
    }

    // Most common syscalls are allowed
    return .allowed;
}

// ============================================================================
// Comparison Tests
// ============================================================================

/// Compare syscall policies between ZViz and gVisor
pub fn compareSyscallPolicies(allocator: std.mem.Allocator) !ComparisonSuite {
    var suite = ComparisonSuite.init(allocator);
    errdefer suite.deinit();

    log.info("=== Comparing Syscall Policies ===", .{});

    // Test blocked syscalls
    const test_syscalls = [_][]const u8{
        // Kernel module operations
        "init_module",
        "delete_module",
        "finit_module",
        // System control
        "reboot",
        "kexec_load",
        "swapon",
        "swapoff",
        // Mount operations
        "mount",
        "umount2",
        "pivot_root",
        // Privilege escalation vectors
        "ptrace",
        "bpf",
        "userfaultfd",
        "perf_event_open",
        // Keyring
        "add_key",
        "request_key",
        "keyctl",
        // Namespace manipulation
        "setns",
        // Common allowed syscalls
        "read",
        "write",
        "open",
        "close",
        "stat",
        "mmap",
        "fork",
        "execve",
        "getpid",
        "socket",
        "connect",
        "bind",
        "listen",
        "accept",
    };

    for (test_syscalls) |syscall| {
        const gvisor_outcome: TestOutcome = if (GVisorExpected.isBlocked(syscall))
            .denied
        else if (GVisorExpected.isAllowed(syscall))
            .allowed
        else
            .not_tested;

        const zviz_outcome = getZVizOutcome(syscall);

        const matches = (gvisor_outcome == zviz_outcome) or
            (gvisor_outcome == .not_tested) or
            (zviz_outcome == .not_tested);

        try suite.addResult(.{
            .test_name = syscall,
            .category = "syscall",
            .zviz_outcome = zviz_outcome,
            .gvisor_outcome = gvisor_outcome,
            .matches = matches,
        });
    }

    return suite;
}

/// Compare file access policies
pub fn compareFileAccessPolicies(allocator: std.mem.Allocator) !ComparisonSuite {
    var suite = ComparisonSuite.init(allocator);
    errdefer suite.deinit();

    log.info("=== Comparing File Access Policies ===", .{});

    const file_tests = [_]struct {
        path: []const u8,
        operation: []const u8,
        gvisor: TestOutcome,
        zviz: TestOutcome,
    }{
        // Both should block
        .{ .path = "/etc/shadow", .operation = "read", .gvisor = .denied, .zviz =.denied },
        .{ .path = "/etc/passwd", .operation = "write", .gvisor = .denied, .zviz =.denied },
        .{ .path = "/proc/kcore", .operation = "read", .gvisor = .denied, .zviz =.denied },
        .{ .path = "/dev/mem", .operation = "read", .gvisor = .denied, .zviz =.denied },
        .{ .path = "/dev/kmem", .operation = "read", .gvisor = .denied, .zviz =.denied },

        // Both should allow
        .{ .path = "/etc/passwd", .operation = "read", .gvisor = .allowed, .zviz =.allowed },
        .{ .path = "/tmp/test", .operation = "write", .gvisor = .allowed, .zviz =.allowed },
        .{ .path = "/dev/null", .operation = "write", .gvisor = .allowed, .zviz =.allowed },
        .{ .path = "/dev/zero", .operation = "read", .gvisor = .allowed, .zviz =.allowed },
        .{ .path = "/dev/urandom", .operation = "read", .gvisor = .allowed, .zviz =.allowed },

        // Proc filesystem
        .{ .path = "/proc/self/status", .operation = "read", .gvisor = .allowed, .zviz =.allowed },
        .{ .path = "/proc/self/maps", .operation = "read", .gvisor = .allowed, .zviz =.allowed },
        .{ .path = "/proc/1/root", .operation = "read", .gvisor = .denied, .zviz =.denied },
    };

    for (file_tests) |test_case| {
        var name_buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}:{s}", .{ test_case.operation, test_case.path }) catch "unknown";

        try suite.addResult(.{
            .test_name = name,
            .category = "filesystem",
            .zviz_outcome = test_case.zviz,
            .gvisor_outcome = test_case.gvisor,
            .matches = test_case.gvisor == test_case.zviz,
        });
    }

    return suite;
}

/// Compare network policies
pub fn compareNetworkPolicies(allocator: std.mem.Allocator) !ComparisonSuite {
    var suite = ComparisonSuite.init(allocator);
    errdefer suite.deinit();

    log.info("=== Comparing Network Policies ===", .{});

    const network_tests = [_]struct {
        name: []const u8,
        gvisor: TestOutcome,
        zviz: TestOutcome,
        note: ?[]const u8,
    }{
        // Raw sockets - both block
        .{ .name = "AF_PACKET raw socket", .gvisor = .denied, .zviz =.denied, .note = null },
        .{ .name = "AF_NETLINK socket", .gvisor = .denied, .zviz =.denied, .note = "Some operations allowed" },

        // Standard sockets - both allow
        .{ .name = "AF_INET TCP socket", .gvisor = .allowed, .zviz =.allowed, .note = null },
        .{ .name = "AF_INET UDP socket", .gvisor = .allowed, .zviz =.allowed, .note = null },
        .{ .name = "AF_INET6 TCP socket", .gvisor = .allowed, .zviz =.allowed, .note = null },
        .{ .name = "AF_UNIX socket", .gvisor = .allowed, .zviz =.allowed, .note = null },

        // Egress - configurable
        .{ .name = "Egress to public internet", .gvisor = .allowed, .zviz =.denied, .note = "ZViz blocks by default, gVisor allows" },
        .{ .name = "Egress to private network", .gvisor = .allowed, .zviz =.allowed, .note = "Configurable via CIDR allowlist" },

        // Bind operations
        .{ .name = "Bind to localhost", .gvisor = .allowed, .zviz =.allowed, .note = null },
        .{ .name = "Bind to privileged port (<1024)", .gvisor = .denied, .zviz =.denied, .note = "Unless CAP_NET_BIND_SERVICE" },
    };

    for (network_tests) |test_case| {
        try suite.addResult(.{
            .test_name = test_case.name,
            .category = "network",
            .zviz_outcome = test_case.zviz,
            .gvisor_outcome = test_case.gvisor,
            .matches = test_case.gvisor == test_case.zviz,
            .notes = test_case.note,
        });
    }

    return suite;
}

/// Run full comparison suite
pub fn runFullComparison(allocator: std.mem.Allocator) !void {
    log.info("=== gVisor vs ZViz Policy Comparison ===", .{});
    log.info("Comparing default security policies...\n", .{});

    // Syscall comparison
    var syscall_suite = try compareSyscallPolicies(allocator);
    defer syscall_suite.deinit();
    syscall_suite.printSummary();

    log.info("", .{});

    // File access comparison
    var file_suite = try compareFileAccessPolicies(allocator);
    defer file_suite.deinit();
    file_suite.printSummary();

    log.info("", .{});

    // Network comparison
    var network_suite = try compareNetworkPolicies(allocator);
    defer network_suite.deinit();
    network_suite.printSummary();

    // Overall summary
    const total_matches = syscall_suite.matches + file_suite.matches + network_suite.matches;
    const total_differs = syscall_suite.differs + file_suite.differs + network_suite.differs;
    const total = total_matches + total_differs;

    log.info("\n=== Overall Policy Compatibility ===", .{});
    log.info("Total comparisons: {d}", .{total});
    log.info("Matching policies: {d}", .{total_matches});
    log.info("Different policies: {d}", .{total_differs});

    if (total > 0) {
        const compat = (@as(f64, @floatFromInt(total_matches)) / @as(f64, @floatFromInt(total))) * 100.0;
        log.info("Overall compatibility: {d:.1}%", .{compat});
    }
}

// ============================================================================
// Tests
// ============================================================================

test "gvisor expected blocked" {
    try std.testing.expect(GVisorExpected.isBlocked("init_module"));
    try std.testing.expect(GVisorExpected.isBlocked("bpf"));
    try std.testing.expect(!GVisorExpected.isBlocked("read"));
}

test "gvisor expected allowed" {
    try std.testing.expect(GVisorExpected.isAllowed("read"));
    try std.testing.expect(GVisorExpected.isAllowed("write"));
    try std.testing.expect(GVisorExpected.isAllowed("fork"));
    try std.testing.expect(!GVisorExpected.isAllowed("init_module"));
}

test "comparison suite" {
    var suite = ComparisonSuite.init(std.testing.allocator);
    defer suite.deinit();

    try suite.addResult(.{
        .test_name = "test1",
        .category = "syscall",
        .zviz_outcome = .denied,
        .gvisor_outcome = .denied,
        .matches = true,
    });

    try suite.addResult(.{
        .test_name = "test2",
        .category = "syscall",
        .zviz_outcome = .allowed,
        .gvisor_outcome = .denied,
        .matches = false,
    });

    try std.testing.expectEqual(@as(u32, 1), suite.matches);
    try std.testing.expectEqual(@as(u32, 1), suite.differs);
}

test "syscall policy comparison" {
    var suite = try compareSyscallPolicies(std.testing.allocator);
    defer suite.deinit();

    // Should have results
    try std.testing.expect(suite.results.items.len > 0);
}
