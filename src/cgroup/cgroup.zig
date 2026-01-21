const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");

/// Cgroup v2 controllers
pub const Controller = enum {
    cpu,
    memory,
    io,
    pids,

    pub fn filename(self: Controller) []const u8 {
        return switch (self) {
            .cpu => "cpu.max",
            .memory => "memory.max",
            .io => "io.max",
            .pids => "pids.max",
        };
    }
};

/// Resource limits configuration
pub const Limits = struct {
    /// CPU quota (e.g., "200000 100000" for 2 CPUs)
    cpu_quota: ?[]const u8 = null,
    cpu_period: u64 = 100000,

    /// Memory limit in bytes
    memory_max: ?u64 = null,
    memory_swap_max: ?u64 = null,

    /// Maximum number of PIDs
    pids_max: ?u32 = null,

    /// I/O limits (device major:minor rbps wbps riops wiops)
    io_max: ?[]const u8 = null,
};

/// Base cgroup path for zviz containers (root mode)
pub const BASE_PATH = "/sys/fs/cgroup/zviz";

/// Get the user's delegated cgroup path for rootless mode
fn getUserCgroupPath(allocator: std.mem.Allocator) !?[]const u8 {
    // In cgroupv2, we need to create our cgroups at a level where controllers are enabled
    // The user@<uid>.service cgroup typically has controllers enabled for child cgroups

    // First, get current user ID
    const uid = std.os.linux.getuid();

    // Try the standard systemd user service path first
    const user_service_path = try std.fmt.allocPrint(
        allocator,
        "/sys/fs/cgroup/user.slice/user-{d}.slice/user@{d}.service/zviz",
        .{ uid, uid },
    );

    // Check if we can write to the parent (user service level)
    const parent_path = try std.fmt.allocPrint(
        allocator,
        "/sys/fs/cgroup/user.slice/user-{d}.slice/user@{d}.service",
        .{ uid, uid },
    );
    defer allocator.free(parent_path);

    // Verify parent exists and has controllers
    std.fs.accessAbsolute(parent_path, .{}) catch {
        allocator.free(user_service_path);
        // Fallback: Read from /proc/self/cgroup
        return try getUserCgroupPathFromProc(allocator);
    };

    return user_service_path;
}

/// Fallback: get cgroup path from /proc/self/cgroup
fn getUserCgroupPathFromProc(allocator: std.mem.Allocator) !?[]const u8 {
    const cgroup_file = std.fs.openFileAbsolute("/proc/self/cgroup", .{ .mode = .read_only }) catch {
        return null;
    };
    defer cgroup_file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = cgroup_file.readAll(&buf) catch return null;
    const content = buf[0..bytes_read];

    // Format for cgroups v2: "0::<path>"
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) {
            const cgroup_path = std.mem.trim(u8, line[3..], " \t\r\n");
            if (cgroup_path.len > 0) {
                // Try to find a parent cgroup that has subtree_control enabled
                // Walk up the path until we find one
                var path_buf: [4096]u8 = undefined;
                var current_path = cgroup_path;

                while (current_path.len > 1) {
                    const subtree_ctrl_path = std.fmt.bufPrint(
                        &path_buf,
                        "/sys/fs/cgroup{s}/cgroup.subtree_control",
                        .{current_path},
                    ) catch break;

                    // Check if this level has subtree_control with memory
                    const file = std.fs.openFileAbsolute(subtree_ctrl_path, .{ .mode = .read_only }) catch {
                        // Move up one level
                        if (std.mem.lastIndexOfScalar(u8, current_path, '/')) |idx| {
                            current_path = current_path[0..idx];
                            continue;
                        }
                        break;
                    };
                    defer file.close();

                    var ctrl_buf: [256]u8 = undefined;
                    const ctrl_len = file.readAll(&ctrl_buf) catch break;
                    const controllers = ctrl_buf[0..ctrl_len];

                    if (std.mem.indexOf(u8, controllers, "memory") != null) {
                        // Found a level with memory controller enabled
                        return try std.fmt.allocPrint(
                            allocator,
                            "/sys/fs/cgroup{s}/zviz",
                            .{current_path},
                        );
                    }

                    // Move up one level
                    if (std.mem.lastIndexOfScalar(u8, current_path, '/')) |idx| {
                        current_path = current_path[0..idx];
                    } else {
                        break;
                    }
                }
            }
        }
    }
    return null;
}

/// Check if we're running as root
fn isRoot() bool {
    return std.os.linux.geteuid() == 0;
}

/// Cgroup manager for a container
pub const CgroupManager = struct {
    allocator: std.mem.Allocator,
    cgroup_path: []const u8,
    container_id: []const u8,
    base_path: []const u8,
    owns_base_path: bool,

    pub fn init(allocator: std.mem.Allocator, container_id: []const u8) !CgroupManager {
        return initWithRootless(allocator, container_id, !isRoot());
    }

    pub fn initWithRootless(allocator: std.mem.Allocator, container_id: []const u8, rootless: bool) !CgroupManager {
        // Determine base path
        var base_path: []const u8 = undefined;
        var owns_base_path = false;

        if (rootless) {
            // Try to get user's delegated cgroup
            if (try getUserCgroupPath(allocator)) |user_path| {
                base_path = user_path;
                owns_base_path = true;
                log.info("Using rootless cgroup path: {s}", .{base_path});
            } else {
                // Fallback to default (will likely fail, but let's try)
                base_path = BASE_PATH;
                log.warn("Could not detect user cgroup, using default path (may fail)", .{});
            }
        } else {
            base_path = BASE_PATH;
        }

        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ base_path, container_id },
        );
        const id_copy = try allocator.dupe(u8, container_id);
        return .{
            .allocator = allocator,
            .cgroup_path = path,
            .container_id = id_copy,
            .base_path = base_path,
            .owns_base_path = owns_base_path,
        };
    }

    pub fn deinit(self: *CgroupManager) void {
        self.allocator.free(self.cgroup_path);
        self.allocator.free(self.container_id);
        if (self.owns_base_path) {
            self.allocator.free(@constCast(self.base_path));
        }
    }

    /// Create the cgroup directory and enable controllers
    pub fn create(self: *CgroupManager) !void {
        log.info("Creating cgroup: {s}", .{self.cgroup_path});

        // First ensure parent zviz cgroup exists
        std.fs.makeDirAbsolute(self.base_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.err("Failed to create base cgroup: {s}", .{self.base_path});
                return errors.Error.CgroupCreationFailed;
            }
        };

        // Enable controllers in parent before creating child
        try self.enableControllersInParent();

        // Create container cgroup
        std.fs.makeDirAbsolute(self.cgroup_path) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.err("Failed to create cgroup: {s}", .{self.cgroup_path});
                return errors.Error.CgroupCreationFailed;
            }
        };
    }

    /// Enable required controllers in the parent cgroup
    fn enableControllersInParent(self: *CgroupManager) !void {
        // First, read available controllers
        const controllers_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cgroup.controllers",
            .{self.base_path},
        );
        defer self.allocator.free(controllers_path);

        var available_buf: [256]u8 = undefined;
        var available_controllers: []const u8 = "";

        if (std.fs.openFileAbsolute(controllers_path, .{ .mode = .read_only })) |file| {
            defer file.close();
            const bytes_read = file.readAll(&available_buf) catch 0;
            available_controllers = std.mem.trim(u8, available_buf[0..bytes_read], " \t\r\n");
        } else |_| {}

        // Build the subtree_control string with only available controllers
        var enable_buf: [128]u8 = undefined;
        var pos: usize = 0;

        const controllers_to_enable = [_][]const u8{ "cpu", "memory", "pids", "io" };
        for (controllers_to_enable) |ctrl| {
            if (std.mem.indexOf(u8, available_controllers, ctrl) != null) {
                if (pos > 0) {
                    enable_buf[pos] = ' ';
                    pos += 1;
                }
                enable_buf[pos] = '+';
                pos += 1;
                @memcpy(enable_buf[pos..][0..ctrl.len], ctrl);
                pos += ctrl.len;
            }
        }

        if (pos == 0) {
            log.debug("No controllers available to enable", .{});
            return;
        }

        const enable_str = enable_buf[0..pos];
        log.info("Enabling controllers: {s}", .{enable_str});

        const subtree_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cgroup.subtree_control",
            .{self.base_path},
        );
        defer self.allocator.free(subtree_path);

        const file = std.fs.openFileAbsolute(subtree_path, .{ .mode = .write_only }) catch |err| {
            log.debug("Could not open subtree_control: {any}", .{err});
            return;
        };
        defer file.close();

        file.writeAll(enable_str) catch |err| {
            log.debug("Could not enable controllers: {any}", .{err});
        };
    }

    /// Apply resource limits
    pub fn applyLimits(self: *CgroupManager, limits: Limits) !void {
        var buf: [32]u8 = undefined;

        if (limits.memory_max) |mem| {
            const mem_str = std.fmt.bufPrint(&buf, "{d}", .{mem}) catch return errors.Error.CgroupCreationFailed;
            try self.writeController(.memory, mem_str);
        }

        if (limits.pids_max) |pids| {
            const pids_str = std.fmt.bufPrint(&buf, "{d}", .{pids}) catch return errors.Error.CgroupCreationFailed;
            try self.writeController(.pids, pids_str);
        }

        if (limits.cpu_quota) |quota| {
            try self.writeController(.cpu, quota);
        }

        if (limits.io_max) |io| {
            try self.writeController(.io, io);
        }
    }

    /// Write to a cgroup controller file
    fn writeController(self: *CgroupManager, controller: Controller, value: []const u8) !void {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.cgroup_path, controller.filename() },
        );
        defer self.allocator.free(path);

        log.debug("Writing cgroup {s} = {s}", .{ path, value });

        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| {
            log.err("Failed to open cgroup file: {s}: {any}", .{ path, err });
            return errors.Error.CgroupCreationFailed;
        };
        defer file.close();

        file.writeAll(value) catch |err| {
            log.err("Failed to write cgroup value: {any}", .{err});
            return errors.Error.CgroupCreationFailed;
        };
    }

    /// Add a process to this cgroup
    pub fn addProcess(self: *CgroupManager, pid: i32) !void {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/cgroup.procs",
            .{self.cgroup_path},
        );
        defer self.allocator.free(path);

        log.debug("Adding pid {d} to cgroup {s}", .{ pid, self.cgroup_path });

        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch {
            return errors.Error.CgroupCreationFailed;
        };
        defer file.close();

        var buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch unreachable;
        file.writeAll(pid_str) catch {
            return errors.Error.CgroupCreationFailed;
        };
    }

    /// Remove the cgroup (must be empty)
    pub fn destroy(self: *CgroupManager) !void {
        log.info("Destroying cgroup: {s}", .{self.cgroup_path});
        std.fs.deleteDirAbsolute(self.cgroup_path) catch |err| {
            log.warn("Failed to remove cgroup: {any}", .{err});
        };
    }

    /// Read current memory usage in bytes
    pub fn getMemoryUsage(self: *CgroupManager) !u64 {
        return try self.readU64("memory.current");
    }

    /// Read current memory limit in bytes
    pub fn getMemoryLimit(self: *CgroupManager) !u64 {
        return try self.readU64("memory.max");
    }

    /// Read current CPU usage in microseconds
    pub fn getCpuUsage(self: *CgroupManager) !u64 {
        // cpu.stat contains "usage_usec <value>"
        var buf: [4096]u8 = undefined;
        const content = try self.readFile("cpu.stat", &buf);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "usage_usec ")) {
                const value_str = line["usage_usec ".len..];
                return std.fmt.parseInt(u64, std.mem.trim(u8, value_str, " \t\r\n"), 10) catch 0;
            }
        }
        return 0;
    }

    /// Read current process count
    pub fn getPidsCount(self: *CgroupManager) !u32 {
        return @intCast(try self.readU64("pids.current"));
    }

    /// Freeze all processes in the cgroup
    pub fn freeze(self: *CgroupManager) !void {
        try self.writeControllerPath("cgroup.freeze", "1");
        log.debug("Cgroup frozen: {s}", .{self.cgroup_path});
    }

    /// Unfreeze all processes in the cgroup
    pub fn unfreeze(self: *CgroupManager) !void {
        try self.writeControllerPath("cgroup.freeze", "0");
        log.debug("Cgroup unfrozen: {s}", .{self.cgroup_path});
    }

    /// Kill all processes in the cgroup
    pub fn killAll(self: *CgroupManager) !void {
        self.writeControllerPath("cgroup.kill", "1") catch |err| {
            log.debug("cgroup.kill not available: {any}", .{err});
            // Fall back to signaling each process
            try self.signalAllProcesses(9); // SIGKILL
        };
        log.debug("All processes killed in: {s}", .{self.cgroup_path});
    }

    /// Signal all processes in the cgroup
    fn signalAllProcesses(self: *CgroupManager, signal: i32) !void {
        var buf: [8192]u8 = undefined;
        const content = self.readFile("cgroup.procs", &buf) catch return;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const pid = std.fmt.parseInt(i32, std.mem.trim(u8, line, " \t\r\n"), 10) catch continue;
            _ = std.os.linux.kill(pid, signal);
        }
    }

    fn readU64(self: *CgroupManager, filename: []const u8) !u64 {
        var buf: [64]u8 = undefined;
        const content = try self.readFile(filename, &buf);
        const trimmed = std.mem.trim(u8, content, " \t\r\n");

        // Handle "max" as maximum value
        if (std.mem.eql(u8, trimmed, "max")) {
            return std.math.maxInt(u64);
        }

        return std.fmt.parseInt(u64, trimmed, 10) catch error.InvalidFormat;
    }

    fn readFile(self: *CgroupManager, filename: []const u8, buf: []u8) ![]const u8 {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.cgroup_path, filename },
        );
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |err| {
            log.debug("Failed to open cgroup file: {s}: {any}", .{ path, err });
            return err;
        };
        defer file.close();

        const bytes_read = file.readAll(buf) catch |err| {
            log.debug("Failed to read cgroup file: {any}", .{err});
            return err;
        };

        return buf[0..bytes_read];
    }

    fn writeControllerPath(self: *CgroupManager, filename: []const u8, value: []const u8) !void {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.cgroup_path, filename },
        );
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| {
            return err;
        };
        defer file.close();

        file.writeAll(value) catch |err| {
            return err;
        };
    }
};

/// Resource usage statistics
pub const Stats = struct {
    memory_usage: u64,
    memory_limit: u64,
    cpu_usage_usec: u64,
    pids_count: u32,
    pids_limit: u32,

    pub fn fromCgroup(cgroup: *CgroupManager) Stats {
        return .{
            .memory_usage = cgroup.getMemoryUsage() catch 0,
            .memory_limit = cgroup.getMemoryLimit() catch std.math.maxInt(u64),
            .cpu_usage_usec = cgroup.getCpuUsage() catch 0,
            .pids_count = cgroup.getPidsCount() catch 0,
            .pids_limit = @intCast(cgroup.readU64("pids.max") catch std.math.maxInt(u64)),
        };
    }
};

/// Check if cgroups v2 is available
pub fn checkCgroupsV2() bool {
    std.fs.accessAbsolute("/sys/fs/cgroup/cgroup.controllers", .{}) catch {
        return false;
    };
    return true;
}

/// Parse memory limit string (e.g., "4G", "512M", "1024K")
pub fn parseMemoryLimit(limit: []const u8) !u64 {
    if (limit.len == 0) return error.InvalidFormat;

    const last = limit[limit.len - 1];
    const multiplier: u64 = switch (last) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        'T', 't' => 1024 * 1024 * 1024 * 1024,
        else => 1,
    };

    const numeric_part = if (multiplier > 1) limit[0 .. limit.len - 1] else limit;
    const value = std.fmt.parseInt(u64, numeric_part, 10) catch {
        return error.InvalidFormat;
    };

    return value * multiplier;
}

test "parse memory limit" {
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), try parseMemoryLimit("4G"));
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), try parseMemoryLimit("512M"));
    try std.testing.expectEqual(@as(u64, 1024), try parseMemoryLimit("1024"));
}

test "check cgroups v2" {
    // Just ensure it runs without error
    _ = checkCgroupsV2();
}
