const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");

/// Supported LSM types
pub const LsmType = enum {
    apparmor,
    selinux,
    landlock,
    none,
};

/// LSM configuration from profile
pub const Config = struct {
    type: LsmType,
    profile_name: ?[]const u8 = null,
    selinux_context: ?[]const u8 = null,
    landlock_ruleset: ?[]const u8 = null,
};

/// Detect available LSM on the host
pub fn detectLsm() LsmType {
    // Check /sys/kernel/security/lsm
    const lsm_file = std.fs.openFileAbsolute("/sys/kernel/security/lsm", .{}) catch {
        log.warn("Cannot read /sys/kernel/security/lsm", .{});
        return .none;
    };
    defer lsm_file.close();

    var buf: [256]u8 = undefined;
    const len = lsm_file.read(&buf) catch {
        return .none;
    };
    const content = buf[0..len];

    if (std.mem.indexOf(u8, content, "apparmor")) |_| {
        return .apparmor;
    }
    if (std.mem.indexOf(u8, content, "selinux")) |_| {
        return .selinux;
    }
    // Landlock doesn't appear in lsm file, check separately
    if (checkLandlockSupport()) {
        return .landlock;
    }

    return .none;
}

/// Check if Landlock is available
fn checkLandlockSupport() bool {
    // Try to create a Landlock ruleset
    // landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)
    const LANDLOCK_CREATE_RULESET_VERSION = 1 << 0;
    const result = std.os.linux.syscall3(
        .landlock_create_ruleset,
        0,
        0,
        LANDLOCK_CREATE_RULESET_VERSION,
    );
    // Returns version number on success, negative on error
    return @as(isize, @bitCast(result)) > 0;
}

/// Apply LSM policy based on type
pub fn applyPolicy(config: Config) !void {
    switch (config.type) {
        .apparmor => try applyAppArmorProfile(config.profile_name orelse "zviz-default"),
        .selinux => try applySELinuxContext(config.selinux_context orelse "system_u:system_r:container_t:s0"),
        .landlock => try applyLandlockRules(config.landlock_ruleset),
        .none => log.warn("No LSM available, object policy will be reduced", .{}),
    }
}

/// Apply AppArmor profile
fn applyAppArmorProfile(profile_name: []const u8) !void {
    log.info("Applying AppArmor profile: {s}", .{profile_name});

    // TODO: Phase 2 implementation
    // 1. Load profile from /etc/apparmor.d/zviz-{profile}
    // 2. aa_change_profile() or write to /proc/self/attr/apparmor/current
}

/// Apply SELinux context
fn applySELinuxContext(context: []const u8) !void {
    log.info("Applying SELinux context: {s}", .{context});

    // TODO: Phase 2 implementation
    // 1. setexeccon() or write to /proc/self/attr/exec
}

/// Landlock path rule
pub const LandlockPathRule = struct {
    path: []const u8,
    access: u64,
};

/// All filesystem access rights (Landlock ABI v1-v3)
const LANDLOCK_ACCESS_FS_ALL: u64 =
    LandlockAccess.fs_execute |
    LandlockAccess.fs_write_file |
    LandlockAccess.fs_read_file |
    LandlockAccess.fs_read_dir |
    LandlockAccess.fs_remove_dir |
    LandlockAccess.fs_remove_file |
    LandlockAccess.fs_make_char |
    LandlockAccess.fs_make_dir |
    LandlockAccess.fs_make_reg |
    LandlockAccess.fs_make_sock |
    LandlockAccess.fs_make_fifo |
    LandlockAccess.fs_make_block |
    LandlockAccess.fs_make_sym;

/// Read + execute access
pub const LANDLOCK_ACCESS_FS_READ_EXEC: u64 =
    LandlockAccess.fs_execute |
    LandlockAccess.fs_read_file |
    LandlockAccess.fs_read_dir;

/// Read + write + create access
pub const LANDLOCK_ACCESS_FS_READ_WRITE: u64 =
    LandlockAccess.fs_execute |
    LandlockAccess.fs_write_file |
    LandlockAccess.fs_read_file |
    LandlockAccess.fs_read_dir |
    LandlockAccess.fs_remove_dir |
    LandlockAccess.fs_remove_file |
    LandlockAccess.fs_make_dir |
    LandlockAccess.fs_make_reg;

/// Landlock rule type
const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;

/// Apply Landlock ruleset with given path rules
pub fn applyLandlockRulesWithPaths(rules: []const LandlockPathRule) !void {
    log.info("Applying Landlock rules ({d} paths)", .{rules.len});

    // Step 1: Create ruleset
    // struct landlock_ruleset_attr { __u64 handled_access_fs; }
    var ruleset_attr = [_]u64{LANDLOCK_ACCESS_FS_ALL};
    const ruleset_fd_raw = std.os.linux.syscall3(
        .landlock_create_ruleset,
        @intFromPtr(&ruleset_attr),
        @sizeOf(@TypeOf(ruleset_attr)),
        0,
    );
    const ruleset_fd_signed: isize = @bitCast(ruleset_fd_raw);
    if (ruleset_fd_signed < 0) {
        log.warn("landlock_create_ruleset failed: {d}", .{ruleset_fd_signed});
        return error.LandlockUnsupported;
    }
    const ruleset_fd: i32 = @intCast(ruleset_fd_signed);
    defer _ = std.os.linux.close(ruleset_fd);

    // Step 2: Add rules for each path
    for (rules) |rule| {
        var path_buf: [512]u8 = undefined;
        if (rule.path.len >= path_buf.len) continue;
        @memcpy(path_buf[0..rule.path.len], rule.path);
        path_buf[rule.path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..rule.path.len :0];

        const O_PATH: u32 = 0x200000;
        const O_CLOEXEC: u32 = 0x80000;
        const fd_raw = std.os.linux.syscall4(
            .openat,
            @bitCast(@as(isize, -100)), // AT_FDCWD
            @intFromPtr(path_z),
            O_PATH | O_CLOEXEC,
            0,
        );
        const fd_signed: isize = @bitCast(fd_raw);
        if (fd_signed < 0) {
            log.debug("Landlock: cannot open {s}: {d}", .{rule.path, fd_signed});
            continue;
        }
        const path_fd: i32 = @intCast(fd_signed);
        defer _ = std.os.linux.close(path_fd);

        // struct landlock_path_beneath_attr { __u64 allowed_access; __s32 parent_fd; }
        const PathBeneathAttr = extern struct {
            allowed_access: u64,
            parent_fd: i32,
        };
        var beneath_attr = PathBeneathAttr{
            .allowed_access = rule.access,
            .parent_fd = path_fd,
        };
        const add_result = std.os.linux.syscall4(
            .landlock_add_rule,
            @intCast(ruleset_fd),
            LANDLOCK_RULE_PATH_BENEATH,
            @intFromPtr(&beneath_attr),
            0,
        );
        const add_signed: isize = @bitCast(add_result);
        if (add_signed < 0) {
            log.debug("Landlock: add_rule failed for {s}: {d}", .{rule.path, add_signed});
        }
    }

    // Step 3: Enforce the ruleset
    const restrict_result = std.os.linux.syscall2(
        .landlock_restrict_self,
        @intCast(ruleset_fd),
        0,
    );
    const restrict_signed: isize = @bitCast(restrict_result);
    if (restrict_signed < 0) {
        log.warn("landlock_restrict_self failed: {d}", .{restrict_signed});
        return error.LandlockEnforceFailed;
    }

    log.info("Landlock ruleset enforced", .{});
}

/// Apply Landlock ruleset (legacy interface)
fn applyLandlockRules(ruleset_name: ?[]const u8) !void {
    log.info("Applying Landlock ruleset: {s}", .{ruleset_name orelse "default"});
    // Default rules: read-only root, read-write /tmp
    const default_rules = [_]LandlockPathRule{
        .{ .path = "/", .access = LANDLOCK_ACCESS_FS_READ_EXEC },
        .{ .path = "/tmp", .access = LANDLOCK_ACCESS_FS_READ_WRITE },
    };
    try applyLandlockRulesWithPaths(&default_rules);
}

/// Landlock access rights
pub const LandlockAccess = struct {
    pub const fs_execute = 1 << 0;
    pub const fs_write_file = 1 << 1;
    pub const fs_read_file = 1 << 2;
    pub const fs_read_dir = 1 << 3;
    pub const fs_remove_dir = 1 << 4;
    pub const fs_remove_file = 1 << 5;
    pub const fs_make_char = 1 << 6;
    pub const fs_make_dir = 1 << 7;
    pub const fs_make_reg = 1 << 8;
    pub const fs_make_sock = 1 << 9;
    pub const fs_make_fifo = 1 << 10;
    pub const fs_make_block = 1 << 11;
    pub const fs_make_sym = 1 << 12;
};

/// Generate AppArmor profile from ZViz profile
pub fn generateAppArmorProfile(
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    writable_paths: []const []const u8,
    readonly_paths: []const []const u8,
) ![]u8 {
    // Estimate buffer size
    const estimated_size = 1024 + (readonly_paths.len + writable_paths.len) * 64;
    var buf = try allocator.alloc(u8, estimated_size);
    var pos: usize = 0;

    // Header
    const header = std.fmt.bufPrint(buf[pos..], "#include <tunables/global>\n\nprofile {s} flags=(attach_disconnected,mediate_deleted) {{\n  #include <abstractions/base>\n\n", .{profile_name}) catch return error.OutOfMemory;
    pos += header.len;

    // Readonly paths
    for (readonly_paths) |path| {
        const line = std.fmt.bufPrint(buf[pos..], "  {s}/** r,\n", .{path}) catch return error.OutOfMemory;
        pos += line.len;
    }

    // Writable paths
    for (writable_paths) |path| {
        const line = std.fmt.bufPrint(buf[pos..], "  {s}/** rwk,\n", .{path}) catch return error.OutOfMemory;
        pos += line.len;
    }

    // Footer
    const footer = std.fmt.bufPrint(buf[pos..], "}}\n", .{}) catch return error.OutOfMemory;
    pos += footer.len;

    // Resize to actual size
    return allocator.realloc(buf, pos);
}

test "detect lsm" {
    const lsm = detectLsm();
    // Just ensure it returns a valid enum value
    _ = @tagName(lsm);
}

test "generate apparmor profile" {
    const profile = try generateAppArmorProfile(
        std.testing.allocator,
        "zviz-test",
        &.{"/work"},
        &.{ "/usr", "/lib" },
    );
    defer std.testing.allocator.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "zviz-test") != null);
}
