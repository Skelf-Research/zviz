const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const schema = @import("../schema/schema.zig");
const seccomp = @import("../seccomp/seccomp.zig");
const lsm = @import("../lsm/lsm.zig");
const network = @import("../network/network.zig");

/// Compiled policy artifacts
pub const CompiledProfile = struct {
    allocator: std.mem.Allocator,

    /// Profile metadata
    name: []const u8,
    version: []const u8,

    /// Seccomp BPF program
    seccomp_bpf: []const seccomp.BpfInsn,

    /// LSM policy (AppArmor, SELinux, or Landlock)
    lsm_policy: ?[]const u8,
    lsm_type: lsm.LsmType,

    /// Network rules (nftables format)
    network_rules: ?[]const u8,

    /// Broker rule tables
    broker_rules: BrokerRules,

    /// Manifest linking rules to intent
    manifest: Manifest,

    pub fn deinit(self: *CompiledProfile) void {
        self.allocator.free(self.seccomp_bpf);
        if (self.lsm_policy) |p| self.allocator.free(p);
        if (self.network_rules) |n| self.allocator.free(n);
        self.manifest.deinit();
    }
};

/// Broker rule tables
pub const BrokerRules = struct {
    openat: OpenatRules,
    ioctl: IoctlRules,
    socket: SocketRules,
    clone: CloneRules,
    exec: ExecRules,

    pub const OpenatRules = struct {
        writable_paths: []const []const u8,
        readonly_paths: []const []const u8,
        denied_paths: []const []const u8,
    };

    pub const IoctlRules = struct {
        subsystems: []const Subsystem,

        pub const Subsystem = struct {
            name: []const u8,
            allowed_cmds: []const u32,
        };
    };

    pub const SocketRules = struct {
        allowed_domains: []const i32,
        allowed_types: []const i32,
    };

    pub const CloneRules = struct {
        allowed_flags: u64,
        denied_flags: u64,
    };

    pub const ExecRules = struct {
        allowed_paths: []const []const u8,
    };
};

/// Build manifest for auditing
pub const Manifest = struct {
    allocator: std.mem.Allocator,
    input_hash: [32]u8,
    rules: []RuleMapping,
    rules_count: usize,
    rules_capacity: usize,

    pub const RuleMapping = struct {
        rule_id: []const u8,
        intent: []const u8,
        source_line: u32,
    };

    pub fn init(allocator: std.mem.Allocator) Manifest {
        return .{
            .allocator = allocator,
            .input_hash = undefined,
            .rules = &[_]RuleMapping{},
            .rules_count = 0,
            .rules_capacity = 0,
        };
    }

    pub fn deinit(self: *Manifest) void {
        if (self.rules_capacity > 0) {
            self.allocator.free(self.rules[0..self.rules_capacity]);
        }
    }

    pub fn addRule(self: *Manifest, rule_id: []const u8, intent: []const u8, line: u32) !void {
        if (self.rules_count >= self.rules_capacity) {
            const new_capacity = if (self.rules_capacity == 0) 8 else self.rules_capacity * 2;
            const new_rules = try self.allocator.alloc(RuleMapping, new_capacity);
            if (self.rules_count > 0) {
                @memcpy(new_rules[0..self.rules_count], self.rules[0..self.rules_count]);
                self.allocator.free(self.rules[0..self.rules_capacity]);
            }
            self.rules = new_rules;
            self.rules_capacity = new_capacity;
        }
        self.rules[self.rules_count] = .{
            .rule_id = rule_id,
            .intent = intent,
            .source_line = line,
        };
        self.rules_count += 1;
    }
};

/// Compiler configuration
pub const CompilerConfig = struct {
    /// Fail if host requirements are not met
    strict: bool = true,
    /// Target LSM type (auto-detect if null)
    target_lsm: ?lsm.LsmType = null,
    /// Output directory for artifacts
    output_dir: ?[]const u8 = null,
};

/// Compile a profile from YAML to enforcement artifacts
pub fn compile(
    allocator: std.mem.Allocator,
    profile: schema.Profile,
    config: CompilerConfig,
) !CompiledProfile {
    log.info("Compiling profile: {s} v{s}", .{ profile.name, profile.version });

    // Check host requirements
    if (config.strict) {
        try checkRequirements(profile.requirements);
    }

    // Generate seccomp BPF
    const bpf = try generateSeccompBpf(allocator, profile.syscalls);

    // Determine and generate LSM policy
    const target_lsm = config.target_lsm orelse lsm.detectLsm();
    const lsm_policy = try generateLsmPolicy(allocator, profile, target_lsm);

    // Generate network rules
    const network_rules = try generateNetworkRules(allocator, profile.network);

    // Build broker rules
    const broker_rules = buildBrokerRules(profile);

    // Create manifest
    var manifest = Manifest.init(allocator);
    try manifest.addRule("seccomp.allow", "Fast-path syscalls", 0);
    try manifest.addRule("seccomp.deny", "Blocked syscalls", 0);
    try manifest.addRule("seccomp.broker", "Brokered syscalls", 0);

    return .{
        .allocator = allocator,
        .name = profile.name,
        .version = profile.version,
        .seccomp_bpf = bpf,
        .lsm_policy = lsm_policy,
        .lsm_type = target_lsm,
        .network_rules = network_rules,
        .broker_rules = broker_rules,
        .manifest = manifest,
    };
}

fn checkRequirements(reqs: schema.Requirements) !void {
    if (reqs.lsm == .required and lsm.detectLsm() == .none) {
        log.err("Profile requires LSM but none available", .{});
        return errors.Error.HostRequirementNotMet;
    }

    // TODO: Check seccomp_notify and network_policy
}

fn generateSeccompBpf(allocator: std.mem.Allocator, syscalls: schema.Syscalls) ![]seccomp.BpfInsn {
    const policy = seccomp.SyscallPolicy{
        .allow = syscalls.allow,
        .deny = syscalls.deny,
        .broker = syscalls.broker,
    };
    return seccomp.generateBpf(allocator, policy);
}

fn generateLsmPolicy(
    allocator: std.mem.Allocator,
    profile: schema.Profile,
    lsm_type: lsm.LsmType,
) !?[]u8 {
    return switch (lsm_type) {
        .apparmor => try lsm.generateAppArmorProfile(
            allocator,
            profile.name,
            profile.filesystem.writable,
            &.{ "/usr", "/lib", "/bin", "/etc" },
        ),
        .selinux => null, // TODO: Generate SELinux policy
        .landlock => null, // TODO: Generate Landlock ruleset
        .none => null,
    };
}

fn generateNetworkRules(allocator: std.mem.Allocator, net_config: schema.NetworkConfig) !?[]u8 {
    if (net_config.mode == .allow_all) return null;

    // Convert schema CIDRs to network.Cidr
    const cidrs = try allocator.alloc(network.Cidr, net_config.allow_cidrs.len);
    defer allocator.free(cidrs);

    var count: usize = 0;
    for (net_config.allow_cidrs) |cidr_str| {
        const cidr = network.Cidr.parse(cidr_str) catch continue;
        cidrs[count] = cidr;
        count += 1;
    }

    const config = network.Config{
        .mode = switch (net_config.mode) {
            .allow_all => .allow_all,
            .deny_all => .deny_all,
            .allow_cidr => .allow_cidr,
        },
        .allow_cidrs = cidrs[0..count],
    };

    const rules = try network.generateNftRules(allocator, config);
    return rules;
}

fn buildBrokerRules(profile: schema.Profile) BrokerRules {
    return .{
        .openat = .{
            .writable_paths = profile.filesystem.writable,
            .readonly_paths = &.{ "/usr", "/lib", "/bin" },
            .denied_paths = &.{ "/etc/shadow", "/etc/passwd" },
        },
        .ioctl = .{
            .subsystems = &.{},
        },
        .socket = .{
            .allowed_domains = &.{ 1, 2 }, // AF_UNIX, AF_INET
            .allowed_types = &.{ 1, 2 }, // SOCK_STREAM, SOCK_DGRAM
        },
        .clone = .{
            .allowed_flags = 0x00010000, // CLONE_VM (threads)
            .denied_flags = 0x7E020000, // Namespace flags
        },
        .exec = .{
            .allowed_paths = &.{ "/usr/bin", "/bin" },
        },
    };
}

/// CLI entry point for profile compilation
pub fn compileProfile(alloc: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("Usage: zviz compile <profile.yaml> [--output <dir>]", .{});
        return errors.Error.ProfileNotFound;
    }

    const profile_path = args[0];
    log.info("Compiling profile: {s}", .{profile_path});

    // TODO: Parse YAML and compile using alloc
    // For now, just validate the file exists
    std.fs.accessAbsolute(profile_path, .{}) catch {
        log.err("Profile not found: {s}", .{profile_path});
        return errors.Error.ProfileNotFound;
    };

    // Placeholder to use allocator
    const default_profile = schema.defaultCiRunner();
    _ = try compile(alloc, default_profile, .{});

    log.warn("Profile compilation not yet fully implemented", .{});
}

test "manifest creation" {
    var manifest = Manifest.init(std.testing.allocator);
    defer manifest.deinit();

    try manifest.addRule("test.rule", "Test intent", 42);
    try std.testing.expectEqual(@as(usize, 1), manifest.rules_count);
}
