const std = @import("std");
const log = @import("../log.zig");

/// ZViz Testing and Validation Framework
///
/// This module provides:
/// - Fuzzing infrastructure for seccomp, network, and cgroup code
/// - Property-based testing for core data structures
/// - Security auditing and hardening validation
/// - Stress testing for performance validation
/// - Escape-class tests for sandbox validation

pub const fuzz = @import("fuzz.zig");
pub const security = @import("security.zig");
pub const escape = @import("escape.zig");
pub const benchmark = @import("benchmark.zig");
pub const comparison = @import("comparison.zig");

/// Run all validation tests
pub fn runAll(allocator: std.mem.Allocator) !void {
    // Run fuzz tests
    try fuzz.runAllFuzzTests(allocator);

    // Run security checks
    try security.checkHostSecurity();
}

/// Run escape tests (requires sandbox environment)
pub fn runEscapeTests(allocator: std.mem.Allocator) !bool {
    log.info("Running escape-class tests...", .{});
    var suite = try escape.runAllTests(allocator);
    defer suite.deinit();

    return suite.failed == 0;
}

test {
    std.testing.refAllDecls(@This());
}
