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

/// Apply Landlock ruleset
fn applyLandlockRules(ruleset_name: ?[]const u8) !void {
    log.info("Applying Landlock ruleset: {s}", .{ruleset_name orelse "default"});

    // TODO: Phase 2 implementation
    // 1. landlock_create_ruleset()
    // 2. landlock_add_rule() for each path
    // 3. landlock_restrict_self()
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
