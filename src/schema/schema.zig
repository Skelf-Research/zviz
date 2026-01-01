const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");

/// ZigViz profile (matches docs/profile-schema.md)
pub const Profile = struct {
    name: []const u8,
    version: []const u8,
    mode: Mode = .high_density,
    description: ?[]const u8 = null,

    requirements: Requirements = .{},
    syscalls: Syscalls = .{},
    ioctl: IoctlConfig = .{},
    filesystem: FilesystemConfig = .{},
    lsm: LsmConfig = .{},
    network: NetworkConfig = .{},
    resources: ResourceConfig = .{},
    broker: BrokerConfig = .{},
    audit: AuditConfig = .{},
};

/// Operational mode
pub const Mode = enum {
    high_density,
    hostile_tenant,
};

/// Host requirements
pub const Requirements = struct {
    lsm: Requirement = .optional,
    seccomp_notify: Requirement = .required,
    network_policy: Requirement = .optional,

    pub const Requirement = enum {
        required,
        optional,
        none,
    };
};

/// Syscall policy tiers
pub const Syscalls = struct {
    allow: []const i32 = &.{},
    deny: []const i32 = &.{},
    broker: []const i32 = &.{},
};

/// Ioctl configuration
pub const IoctlConfig = struct {
    allowlists: []const IoctlAllowlist = &.{},

    pub const IoctlAllowlist = struct {
        subsystem: []const u8,
        commands: []const u32,
    };
};

/// Filesystem configuration
pub const FilesystemConfig = struct {
    rootfs: RootfsMode = .readonly,
    writable: []const []const u8 = &.{},
    tmpfs: []const []const u8 = &.{},

    pub const RootfsMode = enum {
        readonly,
        readwrite,
    };
};

/// LSM configuration
pub const LsmConfig = struct {
    type: LsmType = .apparmor,
    profile: ?[]const u8 = null,
    context: ?[]const u8 = null,
    ruleset: ?[]const u8 = null,

    pub const LsmType = enum {
        apparmor,
        selinux,
        landlock,
    };
};

/// Network configuration
pub const NetworkConfig = struct {
    mode: NetworkMode = .deny_all,
    allow_cidrs: []const []const u8 = &.{},
    allow_domains: []const []const u8 = &.{},

    pub const NetworkMode = enum {
        allow_all,
        deny_all,
        allow_cidr,
    };
};

/// Resource limits
pub const ResourceConfig = struct {
    cpu_max: ?[]const u8 = null,
    memory_max: ?[]const u8 = null,
    pids_max: ?u32 = null,
};

/// Broker configuration
pub const BrokerConfig = struct {
    max_inflight: u32 = 256,
    timeout_ms: u32 = 200,
};

/// Audit configuration
pub const AuditConfig = struct {
    level: AuditLevel = .minimal,

    pub const AuditLevel = enum {
        none,
        minimal,
        full,
    };
};

/// Profile parser for JSON format
pub const ProfileParser = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) ProfileParser {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *ProfileParser) void {
        self.arena.deinit();
    }

    /// Parse a profile from JSON content
    pub fn parseJson(self: *ProfileParser, json_content: []const u8) !Profile {
        const arena_allocator = self.arena.allocator();

        const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, json_content, .{}) catch {
            log.err("Failed to parse JSON", .{});
            return errors.Error.ProfileParseError;
        };

        const root = parsed.value;
        if (root != .object) {
            return errors.Error.ProfileParseError;
        }

        var profile = Profile{
            .name = "default",
            .version = "0.1",
        };

        // Parse required fields
        if (root.object.get("name")) |name| {
            if (name == .string) {
                profile.name = name.string;
            }
        }

        if (root.object.get("version")) |version| {
            if (version == .string) {
                profile.version = version.string;
            }
        }

        // Parse mode
        if (root.object.get("mode")) |mode| {
            if (mode == .string) {
                profile.mode = std.meta.stringToEnum(Mode, mode.string) orelse .high_density;
            }
        }

        // Parse description
        if (root.object.get("description")) |desc| {
            if (desc == .string) {
                profile.description = desc.string;
            }
        }

        // Parse syscalls
        if (root.object.get("syscalls")) |syscalls_obj| {
            if (syscalls_obj == .object) {
                profile.syscalls = try self.parseSyscalls(syscalls_obj.object);
            }
        }

        // Parse filesystem
        if (root.object.get("filesystem")) |fs_obj| {
            if (fs_obj == .object) {
                profile.filesystem = try self.parseFilesystem(fs_obj.object);
            }
        }

        // Parse network
        if (root.object.get("network")) |net_obj| {
            if (net_obj == .object) {
                profile.network = try self.parseNetwork(net_obj.object);
            }
        }

        // Parse resources
        if (root.object.get("resources")) |res_obj| {
            if (res_obj == .object) {
                profile.resources = try self.parseResources(res_obj.object);
            }
        }

        // Parse broker config
        if (root.object.get("broker")) |broker_obj| {
            if (broker_obj == .object) {
                profile.broker = try self.parseBroker(broker_obj.object);
            }
        }

        return profile;
    }

    fn parseSyscalls(self: *ProfileParser, obj: std.json.ObjectMap) !Syscalls {
        var syscalls = Syscalls{};
        const arena = self.arena.allocator();

        if (obj.get("allow")) |allow| {
            if (allow == .array) {
                var list: std.ArrayList(i32) = .{};
                for (allow.array.items) |item| {
                    if (item == .integer) {
                        try list.append(arena, @intCast(item.integer));
                    }
                }
                syscalls.allow = try list.toOwnedSlice(arena);
            }
        }

        if (obj.get("deny")) |deny| {
            if (deny == .array) {
                var list: std.ArrayList(i32) = .{};
                for (deny.array.items) |item| {
                    if (item == .integer) {
                        try list.append(arena, @intCast(item.integer));
                    }
                }
                syscalls.deny = try list.toOwnedSlice(arena);
            }
        }

        if (obj.get("broker")) |broker| {
            if (broker == .array) {
                var list: std.ArrayList(i32) = .{};
                for (broker.array.items) |item| {
                    if (item == .integer) {
                        try list.append(arena, @intCast(item.integer));
                    }
                }
                syscalls.broker = try list.toOwnedSlice(arena);
            }
        }

        return syscalls;
    }

    fn parseFilesystem(self: *ProfileParser, obj: std.json.ObjectMap) !FilesystemConfig {
        var fs = FilesystemConfig{};
        const arena = self.arena.allocator();

        if (obj.get("rootfs")) |rootfs| {
            if (rootfs == .string) {
                fs.rootfs = std.meta.stringToEnum(FilesystemConfig.RootfsMode, rootfs.string) orelse .readonly;
            }
        }

        if (obj.get("writable")) |writable| {
            if (writable == .array) {
                var list: std.ArrayList([]const u8) = .{};
                for (writable.array.items) |item| {
                    if (item == .string) {
                        try list.append(arena, item.string);
                    }
                }
                fs.writable = try list.toOwnedSlice(arena);
            }
        }

        if (obj.get("tmpfs")) |tmpfs| {
            if (tmpfs == .array) {
                var list: std.ArrayList([]const u8) = .{};
                for (tmpfs.array.items) |item| {
                    if (item == .string) {
                        try list.append(arena, item.string);
                    }
                }
                fs.tmpfs = try list.toOwnedSlice(arena);
            }
        }

        return fs;
    }

    fn parseNetwork(self: *ProfileParser, obj: std.json.ObjectMap) !NetworkConfig {
        var net = NetworkConfig{};
        const arena = self.arena.allocator();

        if (obj.get("mode")) |mode| {
            if (mode == .string) {
                net.mode = std.meta.stringToEnum(NetworkConfig.NetworkMode, mode.string) orelse .deny_all;
            }
        }

        if (obj.get("allow_cidrs")) |cidrs| {
            if (cidrs == .array) {
                var list: std.ArrayList([]const u8) = .{};
                for (cidrs.array.items) |item| {
                    if (item == .string) {
                        try list.append(arena, item.string);
                    }
                }
                net.allow_cidrs = try list.toOwnedSlice(arena);
            }
        }

        return net;
    }

    fn parseResources(self: *ProfileParser, obj: std.json.ObjectMap) !ResourceConfig {
        var res = ResourceConfig{};
        _ = self;

        if (obj.get("cpu_max")) |cpu| {
            if (cpu == .string) {
                res.cpu_max = cpu.string;
            }
        }

        if (obj.get("memory_max")) |mem| {
            if (mem == .string) {
                res.memory_max = mem.string;
            }
        }

        if (obj.get("pids_max")) |pids| {
            if (pids == .integer) {
                res.pids_max = @intCast(pids.integer);
            }
        }

        return res;
    }

    fn parseBroker(self: *ProfileParser, obj: std.json.ObjectMap) !BrokerConfig {
        var broker = BrokerConfig{};
        _ = self;

        if (obj.get("max_inflight")) |max| {
            if (max == .integer) {
                broker.max_inflight = @intCast(max.integer);
            }
        }

        if (obj.get("timeout_ms")) |timeout| {
            if (timeout == .integer) {
                broker.timeout_ms = @intCast(timeout.integer);
            }
        }

        return broker;
    }
};

/// Parse a profile from JSON content (convenience function)
pub fn parseJson(allocator: std.mem.Allocator, json_content: []const u8) !Profile {
    var parser = ProfileParser.init(allocator);
    // Note: caller should manage parser lifetime if profile strings need to persist
    return parser.parseJson(json_content);
}

/// Load and parse a profile from a file
pub fn loadProfile(allocator: std.mem.Allocator, path: []const u8) !Profile {
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return errors.Error.ProfileNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return errors.Error.ProfileParseError;
    };
    defer allocator.free(content);

    // Detect format by extension or content
    if (std.mem.endsWith(u8, path, ".json") or (content.len > 0 and content[0] == '{')) {
        return parseJson(allocator, content);
    }

    // YAML not yet supported
    log.warn("YAML parsing not yet implemented, using defaults", .{});
    return Profile{
        .name = "default",
        .version = "0.1",
    };
}

/// Validate a profile against the schema
pub fn validate(profile: Profile) !void {
    // Name is required
    if (profile.name.len == 0) {
        log.err("Profile name is required", .{});
        return errors.Error.ProfileValidationFailed;
    }

    // Version is required
    if (profile.version.len == 0) {
        log.err("Profile version is required", .{});
        return errors.Error.ProfileValidationFailed;
    }

    // Validate syscall lists don't overlap
    for (profile.syscalls.allow) |allow_nr| {
        for (profile.syscalls.deny) |deny_nr| {
            if (allow_nr == deny_nr) {
                log.err("Syscall {d} appears in both allow and deny lists", .{allow_nr});
                return errors.Error.ProfileValidationFailed;
            }
        }
    }

    log.debug("Profile validation passed: {s}", .{profile.name});
}

/// Default CI runner profile (matches docs/profile-ci-runner.md)
pub fn defaultCiRunner() Profile {
    return .{
        .name = "zigviz-ci",
        .version = "0.1",
        .mode = .high_density,
        .description = "CI runner profile for build and test workloads",
        .requirements = .{
            .lsm = .required,
            .seccomp_notify = .required,
            .network_policy = .required,
        },
        .syscalls = .{
            .allow = &.{
                0, // read
                1, // write
                3, // close
                5, // fstat
                8, // lseek
                9, // mmap
                10, // mprotect
                11, // munmap
                12, // brk
                202, // futex
                228, // clock_gettime
            },
            .deny = &.{
                101, // ptrace
                165, // mount
                246, // kexec_load
                298, // perf_event_open
                321, // bpf
            },
            .broker = &.{
                257, // openat
                437, // openat2
                16, // ioctl
                41, // socket
                56, // clone
                59, // execve
            },
        },
        .filesystem = .{
            .rootfs = .readonly,
            .writable = &.{ "/work", "/tmp" },
            .tmpfs = &.{"/tmp"},
        },
        .network = .{
            .mode = .allow_cidr,
            .allow_cidrs = &.{ "10.0.0.0/8", "172.16.0.0/12" },
        },
        .resources = .{
            .cpu_max = "2",
            .memory_max = "4G",
            .pids_max = 512,
        },
    };
}

/// Merge two profiles, with child overriding parent
pub fn mergeProfiles(parent: Profile, child: Profile) Profile {
    return .{
        .name = child.name,
        .version = child.version,
        .mode = child.mode,
        .description = child.description orelse parent.description,
        .requirements = .{
            .lsm = if (child.requirements.lsm != .optional) child.requirements.lsm else parent.requirements.lsm,
            .seccomp_notify = if (child.requirements.seccomp_notify != .optional) child.requirements.seccomp_notify else parent.requirements.seccomp_notify,
            .network_policy = if (child.requirements.network_policy != .optional) child.requirements.network_policy else parent.requirements.network_policy,
        },
        .syscalls = .{
            .allow = if (child.syscalls.allow.len > 0) child.syscalls.allow else parent.syscalls.allow,
            .deny = if (child.syscalls.deny.len > 0) child.syscalls.deny else parent.syscalls.deny,
            .broker = if (child.syscalls.broker.len > 0) child.syscalls.broker else parent.syscalls.broker,
        },
        .ioctl = if (child.ioctl.allowlists.len > 0) child.ioctl else parent.ioctl,
        .filesystem = .{
            .rootfs = child.filesystem.rootfs,
            .writable = if (child.filesystem.writable.len > 0) child.filesystem.writable else parent.filesystem.writable,
            .tmpfs = if (child.filesystem.tmpfs.len > 0) child.filesystem.tmpfs else parent.filesystem.tmpfs,
        },
        .lsm = .{
            .type = child.lsm.type,
            .profile = child.lsm.profile orelse parent.lsm.profile,
            .context = child.lsm.context orelse parent.lsm.context,
            .ruleset = child.lsm.ruleset orelse parent.lsm.ruleset,
        },
        .network = .{
            .mode = child.network.mode,
            .allow_cidrs = if (child.network.allow_cidrs.len > 0) child.network.allow_cidrs else parent.network.allow_cidrs,
            .allow_domains = if (child.network.allow_domains.len > 0) child.network.allow_domains else parent.network.allow_domains,
        },
        .resources = .{
            .cpu_max = child.resources.cpu_max orelse parent.resources.cpu_max,
            .memory_max = child.resources.memory_max orelse parent.resources.memory_max,
            .pids_max = child.resources.pids_max orelse parent.resources.pids_max,
        },
        .broker = child.broker,
        .audit = child.audit,
    };
}

/// Built-in base profiles
pub const BaseProfiles = struct {
    /// Minimal profile with just seccomp
    pub fn minimal() Profile {
        return .{
            .name = "zigviz-minimal",
            .version = "0.1",
            .mode = .high_density,
            .description = "Minimal profile with basic syscall filtering",
            .syscalls = .{
                .allow = &.{ 0, 1, 3, 5, 8, 9, 10, 11, 12 }, // read, write, close, fstat, lseek, mmap, mprotect, munmap, brk
                .deny = &.{ 101, 165, 246, 298, 321 }, // ptrace, mount, kexec_load, perf_event_open, bpf
                .broker = &.{},
            },
        };
    }

    /// Standard CI runner profile
    pub fn ciRunner() Profile {
        return defaultCiRunner();
    }

    /// Restricted profile for hostile tenants
    pub fn hostile() Profile {
        var profile = defaultCiRunner();
        profile.name = "zigviz-hostile";
        profile.mode = .hostile_tenant;
        profile.network.mode = .deny_all;
        profile.resources.memory_max = "2G";
        profile.resources.pids_max = 128;
        return profile;
    }
};

test "default profile validation" {
    const profile = Profile{
        .name = "test",
        .version = "0.1",
    };
    try validate(profile);
}

test "ci runner profile" {
    const profile = defaultCiRunner();
    try validate(profile);
    try std.testing.expectEqualStrings("zigviz-ci", profile.name);
}

test "json parsing" {
    const json =
        \\{
        \\  "name": "test-profile",
        \\  "version": "1.0",
        \\  "mode": "high_density",
        \\  "syscalls": {
        \\    "allow": [0, 1, 3],
        \\    "deny": [101],
        \\    "broker": [257]
        \\  },
        \\  "filesystem": {
        \\    "rootfs": "readonly",
        \\    "writable": ["/tmp", "/work"]
        \\  },
        \\  "network": {
        \\    "mode": "allow_cidr",
        \\    "allow_cidrs": ["10.0.0.0/8"]
        \\  },
        \\  "resources": {
        \\    "memory_max": "4G",
        \\    "pids_max": 256
        \\  }
        \\}
    ;

    var parser = ProfileParser.init(std.testing.allocator);
    defer parser.deinit();

    const profile = try parser.parseJson(json);
    try std.testing.expectEqualStrings("test-profile", profile.name);
    try std.testing.expectEqualStrings("1.0", profile.version);
    try std.testing.expectEqual(Mode.high_density, profile.mode);
    try std.testing.expectEqual(@as(usize, 3), profile.syscalls.allow.len);
    try std.testing.expectEqual(@as(usize, 2), profile.filesystem.writable.len);
}

test "profile inheritance" {
    const parent = BaseProfiles.minimal();
    const child = Profile{
        .name = "child-profile",
        .version = "1.0",
        .resources = .{
            .memory_max = "8G",
        },
    };

    const merged = mergeProfiles(parent, child);
    try std.testing.expectEqualStrings("child-profile", merged.name);
    try std.testing.expectEqualStrings("8G", merged.resources.memory_max.?);
    // Should inherit syscalls from parent
    try std.testing.expect(merged.syscalls.allow.len > 0);
}
