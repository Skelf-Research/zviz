const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const linux = @import("../syscalls/linux.zig");

/// Linux namespace types
pub const NamespaceType = enum(u32) {
    user = linux.CLONE.NEWUSER,
    pid = linux.CLONE.NEWPID,
    mount = linux.CLONE.NEWNS,
    network = linux.CLONE.NEWNET,
    ipc = linux.CLONE.NEWIPC,
    uts = linux.CLONE.NEWUTS,
    cgroup = linux.CLONE.NEWCGROUP,

    pub fn all() u32 {
        return @intFromEnum(NamespaceType.user) |
            @intFromEnum(NamespaceType.pid) |
            @intFromEnum(NamespaceType.mount) |
            @intFromEnum(NamespaceType.network) |
            @intFromEnum(NamespaceType.ipc) |
            @intFromEnum(NamespaceType.uts) |
            @intFromEnum(NamespaceType.cgroup);
    }
};

/// Mount flags
const MS = struct {
    const RDONLY: u32 = 1;
    const NOSUID: u32 = 2;
    const NODEV: u32 = 4;
    const NOEXEC: u32 = 8;
    const REMOUNT: u32 = 32;
    const BIND: u32 = 4096;
    const REC: u32 = 16384;
    const PRIVATE: u32 = 262144;
    const SLAVE: u32 = 524288;
};

/// Linux capabilities
pub const Capability = enum(u8) {
    chown = 0,
    dac_override = 1,
    dac_read_search = 2,
    fowner = 3,
    fsetid = 4,
    kill = 5,
    setgid = 6,
    setuid = 7,
    setpcap = 8,
    linux_immutable = 9,
    net_bind_service = 10,
    net_broadcast = 11,
    net_admin = 12,
    net_raw = 13,
    ipc_lock = 14,
    ipc_owner = 15,
    sys_module = 16,
    sys_rawio = 17,
    sys_chroot = 18,
    sys_ptrace = 19,
    sys_pacct = 20,
    sys_admin = 21,
    sys_boot = 22,
    sys_nice = 23,
    sys_resource = 24,
    sys_time = 25,
    sys_tty_config = 26,
    mknod = 27,
    lease = 28,
    audit_write = 29,
    audit_control = 30,
    setfcap = 31,
    // ... more capabilities as needed
};

/// Container containment configuration
pub const Config = struct {
    namespaces: []const NamespaceType = &.{
        .user,
        .pid,
        .mount,
        .network,
        .ipc,
    },
    capabilities_keep: []const Capability = &.{},
    rootfs_readonly: bool = true,
    no_new_privileges: bool = true,
};

/// Set up container namespaces using unshare
pub fn setupNamespaces(config: Config) !void {
    log.info("Setting up namespaces", .{});

    // Build namespace flags
    var flags: u32 = 0;
    for (config.namespaces) |ns| {
        flags |= @intFromEnum(ns);
        log.debug("Adding namespace: {s}", .{@tagName(ns)});
    }

    // Unshare namespaces
    const result = std.os.linux.syscall1(.unshare, flags);
    const signed_result: isize = @bitCast(result);
    if (signed_result < 0) {
        log.err("Failed to unshare namespaces: {d}", .{signed_result});
        return errors.Error.NamespaceCreationFailed;
    }

    log.info("Namespaces created successfully", .{});
}

/// Write uid/gid mappings for user namespace
pub fn writeIdMappings(pid: i32, uid_map: []const u8, gid_map: []const u8) !void {
    var path_buf: [64]u8 = undefined;

    // Write uid_map
    const uid_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/uid_map", .{pid}) catch return error.InvalidPath;
    writeFile(uid_path, uid_map) catch |err| {
        log.err("Failed to write uid_map: {any}", .{err});
        return errors.Error.NamespaceCreationFailed;
    };

    // Disable setgroups (required before gid_map in unprivileged containers)
    const setgroups_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/setgroups", .{pid}) catch return error.InvalidPath;
    writeFile(setgroups_path, "deny") catch {
        // May fail if not supported, continue anyway
    };

    // Write gid_map
    const gid_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/gid_map", .{pid}) catch return error.InvalidPath;
    writeFile(gid_path, gid_map) catch |err| {
        log.err("Failed to write gid_map: {any}", .{err});
        return errors.Error.NamespaceCreationFailed;
    };

    log.debug("ID mappings written for pid {d}", .{pid});
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
    defer file.close();
    try file.writeAll(content);
}

/// Drop capabilities to minimal set using capset
pub fn dropCapabilities(keep: []const Capability) !void {
    log.info("Dropping capabilities, keeping {d}", .{keep.len});

    // Build capability bitmask for caps to keep
    var inheritable: u64 = 0;
    var permitted: u64 = 0;
    var effective: u64 = 0;

    for (keep) |cap| {
        const bit: u64 = @as(u64, 1) << @intFromEnum(cap);
        inheritable |= bit;
        permitted |= bit;
        effective |= bit;
    }

    // Use prctl to drop bounding set capabilities
    const CAP_LAST_CAP = 40; // Current max capability
    var cap: u8 = 0;
    while (cap <= CAP_LAST_CAP) : (cap += 1) {
        const bit: u64 = @as(u64, 1) << cap;
        if (permitted & bit == 0) {
            // Drop from bounding set
            const result = std.os.linux.prctl(.CAPBSET_DROP, cap, 0, 0, 0);
            if (result != 0 and result != @as(usize, @bitCast(@as(isize, -22)))) { // EINVAL means already dropped
                log.debug("Failed to drop cap {d}: {d}", .{ cap, result });
            }
        }
    }

    log.info("Capabilities dropped", .{});
}

/// Set up filesystem isolation with pivot_root
pub fn setupFilesystem(rootfs: []const u8, readonly: bool) !void {
    log.info("Setting up filesystem: {s}, readonly={any}", .{ rootfs, readonly });

    // Make the mount namespace private so mounts don't propagate
    const private_result = mount(null, "/", null, MS.REC | MS.PRIVATE, null);
    if (private_result != 0) {
        log.warn("Failed to make / private: {d}", .{private_result});
    }

    // Bind mount the new root to itself (required for pivot_root)
    const bind_result = mount(rootfs, rootfs, null, MS.BIND | MS.REC, null);
    if (bind_result != 0) {
        log.err("Failed to bind mount rootfs: {d}", .{bind_result});
        return errors.Error.NamespaceCreationFailed;
    }

    // Create oldroot directory inside new root
    var oldroot_path: [4096]u8 = undefined;
    const oldroot = std.fmt.bufPrint(&oldroot_path, "{s}/.oldroot", .{rootfs}) catch return error.InvalidPath;

    std.fs.makeDirAbsolute(oldroot) catch |err| {
        if (err != error.PathAlreadyExists) {
            log.err("Failed to create oldroot: {any}", .{err});
            return errors.Error.NamespaceCreationFailed;
        }
    };

    // Pivot root
    const pivot_result = pivotRoot(rootfs, oldroot);
    if (pivot_result != 0) {
        log.err("pivot_root failed: {d}", .{pivot_result});
        return errors.Error.NamespaceCreationFailed;
    }

    // Change to new root
    std.posix.chdir("/") catch |err| {
        log.err("Failed to chdir to /: {any}", .{err});
        return errors.Error.NamespaceCreationFailed;
    };

    // Unmount old root
    const umount_result = umount2("/.oldroot", 2); // MNT_DETACH
    if (umount_result != 0) {
        log.warn("Failed to unmount oldroot: {d}", .{umount_result});
    }

    // Remove oldroot directory
    std.fs.deleteTreeAbsolute("/.oldroot") catch {};

    // Remount root as readonly if configured
    if (readonly) {
        const ro_result = mount(null, "/", null, MS.REMOUNT | MS.RDONLY | MS.BIND, null);
        if (ro_result != 0) {
            log.warn("Failed to remount / as readonly: {d}", .{ro_result});
        }
    }

    // Mount essential filesystems
    try mountEssentials();

    log.info("Filesystem setup complete", .{});
}

/// Mount essential filesystems (/proc, /dev, /sys)
fn mountEssentials() !void {
    // Mount /proc
    std.fs.makeDirAbsolute("/proc") catch {};
    const proc_result = mount("proc", "/proc", "proc", MS.NOSUID | MS.NOEXEC | MS.NODEV, null);
    if (proc_result != 0) {
        log.warn("Failed to mount /proc: {d}", .{proc_result});
    }

    // Mount /dev as tmpfs with minimal devices
    std.fs.makeDirAbsolute("/dev") catch {};
    const dev_result = mount("tmpfs", "/dev", "tmpfs", MS.NOSUID | MS.NOEXEC, "mode=755,size=65536k");
    if (dev_result != 0) {
        log.warn("Failed to mount /dev: {d}", .{dev_result});
    }

    // Create essential device nodes or symlinks
    // /dev/null, /dev/zero, /dev/random, /dev/urandom, /dev/tty
    createDeviceNodes() catch |err| {
        log.warn("Failed to create device nodes: {any}", .{err});
    };

    // Mount /sys (readonly)
    std.fs.makeDirAbsolute("/sys") catch {};
    const sys_result = mount("sysfs", "/sys", "sysfs", MS.NOSUID | MS.NOEXEC | MS.NODEV | MS.RDONLY, null);
    if (sys_result != 0) {
        log.warn("Failed to mount /sys: {d}", .{sys_result});
    }
}

fn createDeviceNodes() !void {
    // Create /dev/pts for pseudo-terminals
    std.fs.makeDirAbsolute("/dev/pts") catch {};
    _ = mount("devpts", "/dev/pts", "devpts", MS.NOSUID | MS.NOEXEC, "newinstance,ptmxmode=0666,mode=620");

    // Symlink /dev/ptmx -> /dev/pts/ptmx
    std.fs.symLinkAbsolute("pts/ptmx", "/dev/ptmx") catch {};

    // Symlinks for standard streams
    std.fs.symLinkAbsolute("/proc/self/fd", "/dev/fd") catch {};
    std.fs.symLinkAbsolute("/proc/self/fd/0", "/dev/stdin") catch {};
    std.fs.symLinkAbsolute("/proc/self/fd/1", "/dev/stdout") catch {};
    std.fs.symLinkAbsolute("/proc/self/fd/2", "/dev/stderr") catch {};
}

fn mount(source: ?[]const u8, target: []const u8, fstype: ?[]const u8, flags: u32, data: ?[]const u8) isize {
    const src_ptr: usize = if (source) |s| @intFromPtr(s.ptr) else 0;
    const tgt_ptr: usize = @intFromPtr(target.ptr);
    const fs_ptr: usize = if (fstype) |f| @intFromPtr(f.ptr) else 0;
    const data_ptr: usize = if (data) |d| @intFromPtr(d.ptr) else 0;

    const result = std.os.linux.syscall5(.mount, src_ptr, tgt_ptr, fs_ptr, flags, data_ptr);
    return @bitCast(result);
}

fn umount2(target: []const u8, flags: u32) isize {
    const result = std.os.linux.syscall2(.umount2, @intFromPtr(target.ptr), flags);
    return @bitCast(result);
}

fn pivotRoot(new_root: []const u8, put_old: []const u8) isize {
    const result = std.os.linux.syscall2(.pivot_root, @intFromPtr(new_root.ptr), @intFromPtr(put_old.ptr));
    return @bitCast(result);
}

/// Set no_new_privs for the process
pub fn setNoNewPrivs() !void {
    const result = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (result != 0) {
        log.err("Failed to set no_new_privs: {d}", .{result});
        return errors.Error.CapabilityDropFailed;
    }
    log.debug("no_new_privs set", .{});
}

/// Full container setup sequence
pub fn setupContainer(config: Config, rootfs: []const u8) !void {
    log.info("Setting up container with rootfs: {s}", .{rootfs});

    // 1. Create namespaces
    try setupNamespaces(config);

    // 2. Set up filesystem isolation
    try setupFilesystem(rootfs, config.rootfs_readonly);

    // 3. Drop capabilities
    try dropCapabilities(config.capabilities_keep);

    // 4. Set no_new_privs
    if (config.no_new_privileges) {
        try setNoNewPrivs();
    }

    log.info("Container setup complete", .{});
}

test "namespace flags" {
    const all = NamespaceType.all();
    try std.testing.expect(all > 0);
    try std.testing.expect(all & @intFromEnum(NamespaceType.user) != 0);
    try std.testing.expect(all & @intFromEnum(NamespaceType.pid) != 0);
}

test "default config" {
    const config = Config{};
    try std.testing.expect(config.rootfs_readonly);
    try std.testing.expect(config.no_new_privileges);
}
