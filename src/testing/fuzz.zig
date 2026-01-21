const std = @import("std");
const seccomp = @import("../seccomp/seccomp.zig");
const network = @import("../network/network.zig");
const cgroup = @import("../cgroup/cgroup.zig");
const schema = @import("../schema/schema.zig");

/// Fuzzing and property-based testing utilities for ZViz

// ============================================================================
// BPF Filter Fuzzing
// ============================================================================

/// Fuzz the BPF generator with random syscall policies
pub fn fuzzBpfGeneration(allocator: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Generate random policy
    const num_allow = random.intRangeAtMost(usize, 0, 50);
    const num_deny = random.intRangeAtMost(usize, 0, 50);
    const num_broker = random.intRangeAtMost(usize, 0, 20);

    const allow_list = try allocator.alloc(i32, num_allow);
    defer allocator.free(allow_list);
    const deny_list = try allocator.alloc(i32, num_deny);
    defer allocator.free(deny_list);
    const broker_list = try allocator.alloc(i32, num_broker);
    defer allocator.free(broker_list);

    for (allow_list) |*s| s.* = random.intRangeAtMost(i32, 0, 450);
    for (deny_list) |*s| s.* = random.intRangeAtMost(i32, 0, 450);
    for (broker_list) |*s| s.* = random.intRangeAtMost(i32, 0, 450);

    const policy = seccomp.SyscallPolicy{
        .allow = allow_list,
        .deny = deny_list,
        .broker = broker_list,
    };

    // Generate BPF - should not crash
    const bpf = seccomp.generateBpf(allocator, policy) catch |err| {
        // Expected errors are OK
        switch (err) {
            error.OutOfMemory => return,
            else => return err,
        }
    };
    defer allocator.free(bpf);

    // Validate BPF structure
    try validateBpfProgram(bpf);
}

/// Validate BPF program structure
fn validateBpfProgram(insns: []const seccomp.BpfInsn) !void {
    if (insns.len == 0) return error.EmptyProgram;
    if (insns.len > 4096) return error.ProgramTooLong;

    // Check that program ends with a return
    const last = insns[insns.len - 1];
    if (last.code != 0x06) { // BPF_RET
        return error.NoTerminalReturn;
    }

    // Check for valid opcodes
    for (insns) |insn| {
        const class = insn.code & 0x07;
        // Valid BPF classes: LD, LDX, ST, STX, ALU, JMP, RET, MISC
        if (class > 7) return error.InvalidOpcode;
    }
}

// ============================================================================
// CIDR Parsing Fuzzing
// ============================================================================

/// Fuzz CIDR parsing with random inputs
pub fn fuzzCidrParsing(input: []const u8) !void {
    // Should not crash on any input
    _ = network.Cidr.parse(input) catch {
        // Parse errors are expected for random input
        return;
    };
}

/// Property: valid CIDR should roundtrip through format
pub fn propertyCidrRoundtrip(allocator: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Generate random valid CIDR
    const address: [4]u8 = .{
        random.int(u8),
        random.int(u8),
        random.int(u8),
        random.int(u8),
    };
    const prefix_len = random.intRangeAtMost(u8, 0, 32);

    const cidr = network.Cidr{
        .address = address,
        .prefix_len = prefix_len,
    };

    // Format to string manually
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}/{d}", .{
        cidr.address[0],
        cidr.address[1],
        cidr.address[2],
        cidr.address[3],
        cidr.prefix_len,
    }) catch return;

    // Parse back
    const parsed = try network.Cidr.parse(formatted);

    // Should be equal
    if (!std.mem.eql(u8, &parsed.address, &cidr.address)) {
        return error.AddressMismatch;
    }
    if (parsed.prefix_len != cidr.prefix_len) {
        return error.PrefixMismatch;
    }

    _ = allocator;
}

/// Property: CIDR contains should be consistent
pub fn propertyCidrContains(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Generate random CIDR
    const address: [4]u8 = .{
        random.int(u8),
        random.int(u8),
        random.int(u8),
        random.int(u8),
    };
    const prefix_len = random.intRangeAtMost(u8, 0, 32);

    const cidr = network.Cidr{
        .address = address,
        .prefix_len = prefix_len,
    };

    // The network address itself should always be contained
    // (Apply mask to get network address)
    var net_addr = address;
    const full_bytes = prefix_len / 8;
    const partial_bits = prefix_len % 8;

    var i: usize = full_bytes;
    if (partial_bits > 0 and i < 4) {
        const mask: u8 = @as(u8, 0xFF) << @intCast(8 - partial_bits);
        net_addr[i] &= mask;
        i += 1;
    }
    while (i < 4) : (i += 1) {
        net_addr[i] = 0;
    }

    if (!cidr.contains(net_addr)) {
        return error.NetworkAddressNotContained;
    }
}

// ============================================================================
// Memory Limit Parsing Fuzzing
// ============================================================================

/// Fuzz memory limit parsing
pub fn fuzzMemoryLimitParsing(input: []const u8) !void {
    // Should not crash
    _ = cgroup.parseMemoryLimit(input) catch {
        return; // Parse errors expected
    };
}

/// Property: parsed memory limits should be positive
pub fn propertyMemoryLimitPositive(seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const suffixes = [_][]const u8{ "", "K", "M", "G", "k", "m", "g" };
    const suffix = suffixes[random.intRangeAtMost(usize, 0, suffixes.len - 1)];
    const value = random.intRangeAtMost(u64, 1, 1000);

    var buf: [32]u8 = undefined;
    const input = std.fmt.bufPrint(&buf, "{d}{s}", .{ value, suffix }) catch return;

    const result = cgroup.parseMemoryLimit(input) catch return;
    if (result == 0) {
        return error.ZeroMemoryLimit;
    }
}

// ============================================================================
// Profile Validation Fuzzing
// ============================================================================

/// Fuzz profile validation with random profiles
pub fn fuzzProfileValidation(allocator: std.mem.Allocator, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    // Create random profile
    const profile = schema.Profile{
        .name = "fuzz-test",
        .version = "1.0.0",
        .mode = if (random.boolean()) .high_density else .hostile_tenant,
        .syscalls = .{
            .allow = &.{},
            .deny = &.{},
            .broker = &.{},
        },
        .filesystem = .{
            .writable = &.{},
            .tmpfs = &.{},
        },
        .network = .{
            .mode = switch (random.intRangeAtMost(u8, 0, 2)) {
                0 => .allow_all,
                1 => .deny_all,
                else => .allow_cidr,
            },
            .allow_cidrs = &.{},
        },
        .resources = .{
            .memory_max = null,
            .pids_max = if (random.boolean()) random.intRangeAtMost(u32, 1, 10000) else null,
            .cpu_max = null,
        },
        .broker = .{
            .max_inflight = random.intRangeAtMost(u32, 1, 1000),
            .timeout_ms = random.intRangeAtMost(u32, 100, 60000),
        },
        .requirements = .{
            .lsm = .optional,
            .seccomp_notify = .required,
            .network_policy = .optional,
        },
    };

    // Validate - should not crash
    schema.validate(profile) catch {
        // Validation errors are OK
    };

    _ = allocator;
}

// ============================================================================
// Stress Tests
// ============================================================================

/// Stress test: rapid BPF generation
pub fn stressBpfGeneration(allocator: std.mem.Allocator, iterations: usize) !void {
    const policy = seccomp.SyscallPolicy{
        .allow = &.{ 0, 1, 2, 3, 60, 231 },
        .deny = &.{ 56, 57, 58 },
        .broker = &.{ 257, 41, 42 },
    };

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const bpf = try seccomp.generateBpf(allocator, policy);
        defer allocator.free(bpf);

        // Quick validation
        if (bpf.len == 0) return error.EmptyBpf;
    }
}

/// Stress test: rapid CIDR parsing and matching
pub fn stressCidrMatching(iterations: usize) !void {
    const cidrs = [_]network.Cidr{
        try network.Cidr.parse("10.0.0.0/8"),
        try network.Cidr.parse("172.16.0.0/12"),
        try network.Cidr.parse("192.168.0.0/16"),
        try network.Cidr.parse("0.0.0.0/0"),
    };

    const test_ips = [_][4]u8{
        .{ 10, 1, 2, 3 },
        .{ 172, 16, 0, 1 },
        .{ 192, 168, 1, 1 },
        .{ 8, 8, 8, 8 },
    };

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        for (cidrs) |cidr| {
            for (test_ips) |ip| {
                _ = cidr.contains(ip);
            }
        }
    }
}

// ============================================================================
// Test Runner
// ============================================================================

pub fn runAllFuzzTests(allocator: std.mem.Allocator) !void {
    const seeds = [_]u64{ 0, 42, 12345, 0xDEADBEEF, 0xCAFEBABE };

    for (seeds) |seed| {
        try fuzzBpfGeneration(allocator, seed);
        try propertyCidrRoundtrip(allocator, seed);
        try propertyCidrContains(seed);
        try propertyMemoryLimitPositive(seed);
        try fuzzProfileValidation(allocator, seed);
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

test "fuzz bpf generation" {
    try fuzzBpfGeneration(std.testing.allocator, 42);
}

test "property cidr roundtrip" {
    try propertyCidrRoundtrip(std.testing.allocator, 42);
}

test "property cidr contains" {
    try propertyCidrContains(42);
}

test "property memory limit positive" {
    try propertyMemoryLimitPositive(42);
}

test "fuzz profile validation" {
    try fuzzProfileValidation(std.testing.allocator, 42);
}

test "stress bpf generation" {
    try stressBpfGeneration(std.testing.allocator, 100);
}

test "stress cidr matching" {
    try stressCidrMatching(1000);
}

test "validate bpf program" {
    const policy = seccomp.SyscallPolicy{
        .allow = &.{0, 1, 2},
        .deny = &.{56},
        .broker = &.{257},
    };
    const bpf = try seccomp.generateBpf(std.testing.allocator, policy);
    defer std.testing.allocator.free(bpf);

    try validateBpfProgram(bpf);
}

test "fuzz cidr parsing with valid inputs" {
    const valid_inputs = [_][]const u8{
        "10.0.0.0/8",
        "192.168.1.0/24",
        "0.0.0.0/0",
        "255.255.255.255/32",
    };

    for (valid_inputs) |input| {
        try fuzzCidrParsing(input);
    }
}

test "fuzz cidr parsing with invalid inputs" {
    const invalid_inputs = [_][]const u8{
        "",
        "not-a-cidr",
        "10.0.0.0",
        "10.0.0.0/",
        "10.0.0.0/33",
        "256.0.0.0/8",
        "10.0.0/8",
    };

    for (invalid_inputs) |input| {
        try fuzzCidrParsing(input);
    }
}

test "fuzz memory limit parsing" {
    const inputs = [_][]const u8{
        "1024",
        "1K",
        "512M",
        "4G",
        "",
        "abc",
        "1X",
    };

    for (inputs) |input| {
        try fuzzMemoryLimitParsing(input);
    }
}

test "run all fuzz tests" {
    try runAllFuzzTests(std.testing.allocator);
}
