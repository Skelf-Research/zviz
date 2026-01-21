const std = @import("std");
const log = @import("../log.zig");
const seccomp = @import("../seccomp/seccomp.zig");
const containment = @import("../containment/containment.zig");
const cgroup = @import("../cgroup/cgroup.zig");

/// Security validation and hardening checks for ZViz

// ============================================================================
// Security Audit Results
// ============================================================================

pub const AuditSeverity = enum {
    info,
    warning,
    critical,

    pub fn string(self: AuditSeverity) []const u8 {
        return switch (self) {
            .info => "INFO",
            .warning => "WARNING",
            .critical => "CRITICAL",
        };
    }
};

pub const AuditFinding = struct {
    severity: AuditSeverity,
    category: []const u8,
    message: []const u8,
    recommendation: []const u8,
};

pub const AuditResult = struct {
    findings: []AuditFinding,
    critical_count: u32,
    warning_count: u32,
    info_count: u32,
    passed: bool,
};

// ============================================================================
// Seccomp Policy Audit
// ============================================================================

/// Dangerous syscalls that should typically be blocked
const DANGEROUS_SYSCALLS = [_]u32{
    // Kernel module operations
    175, // init_module
    176, // delete_module
    313, // finit_module

    // Direct I/O
    173, // ioperm
    172, // iopl

    // Process tracing
    101, // ptrace

    // Kernel keyring
    248, // add_key
    249, // request_key
    250, // keyctl

    // System state
    167, // swapon
    168, // swapoff
    169, // reboot

    // Namespace creation (in non-user-ns context)
    // 272, // unshare - context dependent
    // 308, // setns - context dependent

    // Mount operations
    165, // mount
    166, // umount2
    43, // pivot_root

    // Capability manipulation
    125, // capset

    // Clock manipulation
    227, // clock_settime

    // Quota manipulation
    179, // quotactl

    // Kexec
    246, // kexec_load
    320, // kexec_file_load

    // BPF (potential for escape)
    321, // bpf

    // Userfaultfd (potential for escape)
    323, // userfaultfd

    // Perf events (information leak)
    298, // perf_event_open
};

/// Audit a seccomp policy for security issues
pub fn auditSeccompPolicy(allocator: std.mem.Allocator, policy: seccomp.SyscallPolicy) !AuditResult {
    var findings: std.ArrayList(AuditFinding) = .empty;
    errdefer findings.deinit(allocator);

    var critical_count: u32 = 0;
    var warning_count: u32 = 0;
    var info_count: u32 = 0;

    // Check for dangerous syscalls in allow list
    for (policy.allow) |syscall| {
        for (DANGEROUS_SYSCALLS) |dangerous| {
            if (syscall == dangerous) {
                try findings.append(allocator, .{
                    .severity = .critical,
                    .category = "seccomp",
                    .message = "Dangerous syscall in allow list",
                    .recommendation = "Move to broker list or deny",
                });
                critical_count += 1;
                break;
            }
        }
    }

    // Check for empty deny list
    if (policy.deny.len == 0) {
        try findings.append(allocator, .{
            .severity = .warning,
            .category = "seccomp",
            .message = "Empty deny list",
            .recommendation = "Explicitly deny dangerous syscalls",
        });
        warning_count += 1;
    }

    // Check broker list has handlers
    if (policy.broker.len > 0) {
        try findings.append(allocator, .{
            .severity = .info,
            .category = "seccomp",
            .message = "Broker syscalls configured",
            .recommendation = "Ensure broker handlers are properly implemented",
        });
        info_count += 1;
    }

    // Check for potential covert channels
    const covert_channel_syscalls = [_]u32{
        // Timing channels
        35, // nanosleep
        230, // clock_nanosleep
        // IPC
        29, // shmget
        30, // shmat
        31, // shmctl
        64, // semget
        65, // semop
        66, // semctl
    };

    var covert_channel_allowed: u32 = 0;
    for (policy.allow) |syscall| {
        for (covert_channel_syscalls) |cc| {
            if (syscall == cc) {
                covert_channel_allowed += 1;
                break;
            }
        }
    }

    if (covert_channel_allowed > 3) {
        try findings.append(allocator, .{
            .severity = .warning,
            .category = "seccomp",
            .message = "Multiple potential covert channel syscalls allowed",
            .recommendation = "Review necessity of IPC and timing syscalls",
        });
        warning_count += 1;
    }

    return .{
        .findings = try findings.toOwnedSlice(allocator),
        .critical_count = critical_count,
        .warning_count = warning_count,
        .info_count = info_count,
        .passed = critical_count == 0,
    };
}

// ============================================================================
// Namespace Configuration Audit
// ============================================================================

/// Audit namespace configuration
pub fn auditNamespaceConfig(config: containment.Config) AuditResult {
    var findings: [10]AuditFinding = undefined;
    var count: usize = 0;
    var critical_count: u32 = 0;
    var warning_count: u32 = 0;
    const info_count: u32 = 0;

    // Check for user namespace (provides UID isolation)
    var has_user_ns = false;
    var has_pid_ns = false;
    var has_net_ns = false;
    var has_mount_ns = false;

    for (config.namespaces) |ns| {
        switch (ns) {
            .user => has_user_ns = true,
            .pid => has_pid_ns = true,
            .network => has_net_ns = true,
            .mount => has_mount_ns = true,
            else => {},
        }
    }

    if (!has_user_ns) {
        findings[count] = .{
            .severity = .warning,
            .category = "namespaces",
            .message = "User namespace not enabled",
            .recommendation = "Enable user namespace for UID isolation",
        };
        count += 1;
        warning_count += 1;
    }

    if (!has_pid_ns) {
        findings[count] = .{
            .severity = .critical,
            .category = "namespaces",
            .message = "PID namespace not enabled",
            .recommendation = "Enable PID namespace to hide host processes",
        };
        count += 1;
        critical_count += 1;
    }

    if (!has_mount_ns) {
        findings[count] = .{
            .severity = .critical,
            .category = "namespaces",
            .message = "Mount namespace not enabled",
            .recommendation = "Enable mount namespace for filesystem isolation",
        };
        count += 1;
        critical_count += 1;
    }

    if (!config.no_new_privileges) {
        findings[count] = .{
            .severity = .critical,
            .category = "privileges",
            .message = "no_new_privs not set",
            .recommendation = "Enable no_new_privs to prevent privilege escalation",
        };
        count += 1;
        critical_count += 1;
    }

    if (!config.rootfs_readonly) {
        findings[count] = .{
            .severity = .warning,
            .category = "filesystem",
            .message = "Root filesystem is writable",
            .recommendation = "Make rootfs readonly and use specific writable mounts",
        };
        count += 1;
        warning_count += 1;
    }

    if (config.capabilities_keep.len > 5) {
        findings[count] = .{
            .severity = .warning,
            .category = "capabilities",
            .message = "Many capabilities retained",
            .recommendation = "Minimize retained capabilities",
        };
        count += 1;
        warning_count += 1;
    }

    return .{
        .findings = findings[0..count],
        .critical_count = critical_count,
        .warning_count = warning_count,
        .info_count = info_count,
        .passed = critical_count == 0,
    };
}

// ============================================================================
// Resource Limits Audit
// ============================================================================

/// Audit cgroup resource limits
pub fn auditResourceLimits(limits: cgroup.Limits) AuditResult {
    var findings: [10]AuditFinding = undefined;
    var count: usize = 0;
    var warning_count: u32 = 0;
    var info_count: u32 = 0;

    // Check memory limit
    if (limits.memory_max == null) {
        findings[count] = .{
            .severity = .warning,
            .category = "resources",
            .message = "No memory limit set",
            .recommendation = "Set memory_max to prevent OOM attacks",
        };
        count += 1;
        warning_count += 1;
    } else if (limits.memory_max.? > 16 * 1024 * 1024 * 1024) { // 16GB
        findings[count] = .{
            .severity = .info,
            .category = "resources",
            .message = "High memory limit (>16GB)",
            .recommendation = "Review if this limit is necessary",
        };
        count += 1;
        info_count += 1;
    }

    // Check PID limit
    if (limits.pids_max == null) {
        findings[count] = .{
            .severity = .warning,
            .category = "resources",
            .message = "No PID limit set",
            .recommendation = "Set pids_max to prevent fork bombs",
        };
        count += 1;
        warning_count += 1;
    } else if (limits.pids_max.? > 10000) {
        findings[count] = .{
            .severity = .info,
            .category = "resources",
            .message = "High PID limit (>10000)",
            .recommendation = "Review if this limit is necessary",
        };
        count += 1;
        info_count += 1;
    }

    // Check CPU quota
    if (limits.cpu_quota == null) {
        findings[count] = .{
            .severity = .info,
            .category = "resources",
            .message = "No CPU quota set",
            .recommendation = "Consider setting CPU quota for fair scheduling",
        };
        count += 1;
        info_count += 1;
    }

    return .{
        .findings = findings[0..count],
        .critical_count = 0,
        .warning_count = warning_count,
        .info_count = info_count,
        .passed = true, // Resource limits are warnings, not critical
    };
}

// ============================================================================
// Full Security Audit
// ============================================================================

/// Run complete security audit
pub fn runFullAudit(
    allocator: std.mem.Allocator,
    seccomp_policy: ?seccomp.SyscallPolicy,
    ns_config: ?containment.Config,
    resource_limits: ?cgroup.Limits,
) !void {
    log.info("=== ZViz Security Audit ===", .{});

    var total_critical: u32 = 0;
    var total_warning: u32 = 0;

    // Seccomp audit
    if (seccomp_policy) |policy| {
        log.info("Auditing seccomp policy...", .{});
        const result = try auditSeccompPolicy(allocator, policy);
        defer allocator.free(result.findings);

        for (result.findings) |finding| {
            log.warn("[{s}] {s}: {s}", .{
                finding.severity.string(),
                finding.category,
                finding.message,
            });
        }
        total_critical += result.critical_count;
        total_warning += result.warning_count;
    }

    // Namespace audit
    if (ns_config) |config| {
        log.info("Auditing namespace configuration...", .{});
        const result = auditNamespaceConfig(config);

        for (result.findings) |finding| {
            log.warn("[{s}] {s}: {s}", .{
                finding.severity.string(),
                finding.category,
                finding.message,
            });
        }
        total_critical += result.critical_count;
        total_warning += result.warning_count;
    }

    // Resource limits audit
    if (resource_limits) |limits| {
        log.info("Auditing resource limits...", .{});
        const result = auditResourceLimits(limits);

        for (result.findings) |finding| {
            log.warn("[{s}] {s}: {s}", .{
                finding.severity.string(),
                finding.category,
                finding.message,
            });
        }
        total_warning += result.warning_count;
    }

    // Summary
    log.info("=== Audit Summary ===", .{});
    log.info("Critical issues: {d}", .{total_critical});
    log.info("Warnings: {d}", .{total_warning});

    if (total_critical > 0) {
        log.err("AUDIT FAILED: {d} critical issues found", .{total_critical});
    } else if (total_warning > 0) {
        log.warn("AUDIT PASSED WITH WARNINGS: {d} warnings", .{total_warning});
    } else {
        log.info("AUDIT PASSED: No issues found", .{});
    }
}

// ============================================================================
// Host Security Checks
// ============================================================================

/// Check host security requirements
pub fn checkHostSecurity() !void {
    log.info("Checking host security configuration...", .{});

    // Check cgroups v2
    if (!cgroup.checkCgroupsV2()) {
        log.warn("Cgroups v2 not available - using legacy cgroups", .{});
    }

    // Check seccomp availability
    const seccomp_available = blk: {
        // Try to read seccomp status from /proc/self/status
        const file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch break :blk false;
        defer file.close();
        var buf: [4096]u8 = undefined;
        const content = file.readAll(&buf) catch break :blk false;
        break :blk std.mem.indexOf(u8, buf[0..content], "Seccomp:") != null;
    };

    if (!seccomp_available) {
        log.warn("Seccomp may not be available", .{});
    }

    // Check for unprivileged user namespaces
    const userns_available = blk: {
        const file = std.fs.openFileAbsolute("/proc/sys/kernel/unprivileged_userns_clone", .{}) catch {
            // File doesn't exist - assume enabled (common on modern kernels)
            break :blk true;
        };
        defer file.close();
        var buf: [8]u8 = undefined;
        const content = file.readAll(&buf) catch break :blk false;
        break :blk content > 0 and buf[0] == '1';
    };

    if (!userns_available) {
        log.warn("Unprivileged user namespaces may be disabled", .{});
    }

    log.info("Host security check complete", .{});
}

// ============================================================================
// Tests
// ============================================================================

test "audit seccomp policy - safe policy" {
    const policy = seccomp.SyscallPolicy{
        .allow = &.{ 0, 1, 2, 3 }, // read, write, open, close
        .deny = &.{ 175, 176, 313 }, // module operations
        .broker = &.{257}, // openat
    };

    const result = try auditSeccompPolicy(std.testing.allocator, policy);
    defer std.testing.allocator.free(result.findings);

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.critical_count);
}

test "audit seccomp policy - dangerous policy" {
    const policy = seccomp.SyscallPolicy{
        .allow = &.{ 0, 1, 175 }, // read, write, init_module (dangerous!)
        .deny = &.{},
        .broker = &.{},
    };

    const result = try auditSeccompPolicy(std.testing.allocator, policy);
    defer std.testing.allocator.free(result.findings);

    try std.testing.expect(!result.passed);
    try std.testing.expect(result.critical_count > 0);
}

test "audit namespace config - secure" {
    const config = containment.Config{
        .namespaces = &.{ .user, .pid, .mount, .network, .ipc },
        .capabilities_keep = &.{},
        .rootfs_readonly = true,
        .no_new_privileges = true,
    };

    const result = auditNamespaceConfig(config);
    try std.testing.expect(result.passed);
}

test "audit namespace config - insecure" {
    const config = containment.Config{
        .namespaces = &.{.ipc}, // Missing critical namespaces
        .capabilities_keep = &.{},
        .rootfs_readonly = false,
        .no_new_privileges = false,
    };

    const result = auditNamespaceConfig(config);
    try std.testing.expect(!result.passed);
    try std.testing.expect(result.critical_count > 0);
}

test "audit resource limits" {
    const limits = cgroup.Limits{
        .memory_max = 512 * 1024 * 1024, // 512MB
        .pids_max = 100,
        .cpu_quota = "100000 100000",
    };

    const result = auditResourceLimits(limits);
    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(u32, 0), result.warning_count);
}

test "audit resource limits - no limits" {
    const limits = cgroup.Limits{};

    const result = auditResourceLimits(limits);
    try std.testing.expect(result.passed); // Warnings don't fail
    try std.testing.expect(result.warning_count > 0);
}

test "check host security" {
    // Just ensure it doesn't crash
    try checkHostSecurity();
}
