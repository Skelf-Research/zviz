const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const linux = @import("../syscalls/linux.zig");
const syscalls = @import("../syscalls/syscalls.zig");

/// Broker configuration from profile
pub const Config = struct {
    max_inflight: u32 = 256,
    timeout_ms: u32 = 200,
};

/// Syscall mediation result
pub const Decision = enum {
    allow,
    deny,
    error_response,
};

/// Brokered syscall handler
pub const Broker = struct {
    allocator: std.mem.Allocator,
    config: Config,
    notify_fd: ?std.posix.fd_t = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Statistics
    stats: Stats = .{},

    // Rule tables (loaded from compiled profile)
    openat_rules: ?*const OpenatRules = null,
    ioctl_rules: ?*const IoctlRules = null,
    socket_rules: ?*const SocketRules = null,
    clone_rules: ?*const CloneRules = null,

    pub const Stats = struct {
        requests_received: u64 = 0,
        requests_allowed: u64 = 0,
        requests_denied: u64 = 0,
        requests_error: u64 = 0,
        total_latency_ns: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) Broker {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Broker) void {
        if (self.notify_fd) |fd| {
            std.posix.close(fd);
        }
    }

    /// Set the notification file descriptor (from seccomp filter setup)
    pub fn setNotifyFd(self: *Broker, fd: std.posix.fd_t) void {
        self.notify_fd = fd;
    }

    /// Start the broker event loop
    pub fn run(self: *Broker) !void {
        const fd = self.notify_fd orelse {
            log.err("Broker started without notify_fd", .{});
            return errors.Error.SeccompNotifyFailed;
        };

        self.running.store(true, .release);
        log.info("Broker started with notify_fd={d}, max_inflight={d}, timeout_ms={d}", .{
            fd,
            self.config.max_inflight,
            self.config.timeout_ms,
        });

        // Use poll for efficient waiting with timeout
        var pollfds = [1]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        while (self.running.load(.acquire)) {
            // Wait for notification with timeout
            const poll_result = std.posix.poll(&pollfds, @intCast(self.config.timeout_ms)) catch |err| {
                log.err("Poll error: {any}", .{err});
                continue;
            };

            if (poll_result == 0) {
                // Timeout - check if we should continue running
                continue;
            }

            if (pollfds[0].revents & std.posix.POLL.IN != 0) {
                self.processOneRequest(fd) catch |err| {
                    switch (err) {
                        error.WouldBlock => {
                            // Spurious wakeup, continue
                        },
                        error.BrokerTimeout => {
                            log.warn("Broker timeout processing notification", .{});
                            self.stats.requests_error += 1;
                        },
                        else => {
                            log.err("Broker error: {any}", .{err});
                            self.stats.requests_error += 1;
                        },
                    }
                };
            }

            if (pollfds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
                log.info("Notify FD closed, stopping broker", .{});
                break;
            }
        }

        log.info("Broker stopped. Stats: recv={d}, allow={d}, deny={d}, err={d}", .{
            self.stats.requests_received,
            self.stats.requests_allowed,
            self.stats.requests_denied,
            self.stats.requests_error,
        });
    }

    /// Process a single notification request
    fn processOneRequest(self: *Broker, fd: std.posix.fd_t) !void {
        var req: linux.seccomp_notif = undefined;
        const start_time = std.time.nanoTimestamp();

        // Receive notification
        const recv_result = std.os.linux.ioctl(fd, linux.SECCOMP.IOCTL_NOTIF_RECV, @intFromPtr(&req));
        if (recv_result != 0) {
            const err = std.posix.errno(recv_result);
            if (err == .WOULDBLOCK or err == .AGAIN) {
                return error.WouldBlock;
            }
            return error.SeccompNotifyFailed;
        }

        self.stats.requests_received += 1;

        // Build context
        const ctx = syscalls.Context{
            .id = req.id,
            .pid = @intCast(req.pid),
            .nr = req.data.nr,
            .args = req.data.args,
            .allocator = self.allocator,
        };

        // Route to handler based on syscall number
        const result = self.handleSyscall(ctx);

        // Build response
        var resp: linux.seccomp_notif_resp = .{
            .id = req.id,
            .val = 0,
            .@"error" = 0,
            .flags = 0,
        };

        switch (result) {
            .allow => {
                // Allow the syscall to proceed with continue flag
                resp.flags = 1; // SECCOMP_USER_NOTIF_FLAG_CONTINUE
                self.stats.requests_allowed += 1;
            },
            .deny => |errno| {
                resp.val = -1;
                resp.@"error" = -errno;
                self.stats.requests_denied += 1;
            },
            .value => |val| {
                resp.val = val;
                self.stats.requests_allowed += 1;
            },
            .@"continue" => {
                // Default deny if no handler claimed it
                resp.val = -1;
                resp.@"error" = -1; // EPERM
                self.stats.requests_denied += 1;
            },
        }

        // Send response
        const send_result = std.os.linux.ioctl(fd, linux.SECCOMP.IOCTL_NOTIF_SEND, @intFromPtr(&resp));
        if (send_result != 0) {
            self.stats.requests_error += 1;
            log.err("Failed to send seccomp response for id={d}", .{req.id});
        }

        // Record latency
        const end_time = std.time.nanoTimestamp();
        const latency: u64 = @intCast(end_time - start_time);
        self.stats.total_latency_ns += latency;

        // Audit log
        const audit = log.AuditEntry{
            .timestamp = @intCast(@divFloor(start_time, std.time.ns_per_s)),
            .syscall_nr = ctx.nr,
            .pid = ctx.pid,
            .decision = switch (result) {
                .allow, .value => .broker_allow,
                .deny, .@"continue" => .broker_deny,
            },
            .rule_id = getSyscallName(ctx.nr),
            .latency_ns = latency,
            .error_code = if (resp.@"error" != 0) @as(?i32, resp.@"error") else null,
        };
        audit.log();
    }

    /// Route syscall to appropriate handler
    fn handleSyscall(self: *Broker, ctx: syscalls.Context) syscalls.Result {
        return switch (ctx.nr) {
            linux.SYS.openat, linux.SYS.openat2 => self.handleOpenat(ctx),
            linux.SYS.ioctl => self.handleIoctl(ctx),
            linux.SYS.socket, linux.SYS.socketpair => self.handleSocket(ctx),
            linux.SYS.clone, linux.SYS.clone3 => self.handleClone(ctx),
            linux.SYS.execve, linux.SYS.execveat => self.handleExec(ctx),
            linux.SYS.prctl => self.handlePrctl(ctx),
            else => {
                log.warn("Unhandled brokered syscall: {d}", .{ctx.nr});
                return .{ .deny = 1 }; // EPERM
            },
        };
    }

    /// Handle openat/openat2 syscalls
    pub fn handleOpenat(self: *Broker, ctx: syscalls.Context) syscalls.Result {
        var path_buf: [4096]u8 = undefined;

        // Arg layout for openat: dirfd, pathname, flags, mode
        // Arg layout for openat2: dirfd, pathname, how, size
        const dirfd = ctx.getArgFd(0) catch return .{ .deny = 22 }; // EINVAL
        const path = ctx.readStringArg(1, &path_buf) catch |err| {
            log.debug("Failed to read path: {any}", .{err});
            return .{ .deny = 14 }; // EFAULT
        };

        var flags: u32 = 0;
        var resolve_flags: u64 = 0;

        if (ctx.nr == linux.SYS.openat2) {
            // Read open_how structure from process memory
            const how_addr = ctx.args[2];
            const how = linux.readOpenHow(ctx.pid, how_addr) catch |err| {
                log.debug("Failed to read open_how: {any}", .{err});
                return .{ .deny = 14 }; // EFAULT
            };
            flags = @truncate(how.flags);
            resolve_flags = how.resolve;

            log.debug("openat2: dirfd={d}, path={s}, flags=0x{x}, resolve=0x{x}", .{ dirfd, path, flags, resolve_flags });

            // Enforce RESOLVE_* flags for TOCTOU resistance
            // For paths under monitored directories, we want RESOLVE_BENEATH or RESOLVE_IN_ROOT
            if (self.openat_rules) |rules| {
                if (rules.require_resolve_beneath) {
                    if (resolve_flags & linux.RESOLVE.BENEATH == 0 and resolve_flags & linux.RESOLVE.IN_ROOT == 0) {
                        // Path traversal not constrained - check if it's a sensitive path
                        for (rules.sensitive_paths) |sensitive| {
                            if (std.mem.startsWith(u8, path, sensitive)) {
                                log.info("openat2 DENIED: {s} (requires RESOLVE_BENEATH)", .{path});
                                return .{ .deny = 40 }; // ELOOP
                            }
                        }
                    }
                }
            }
        } else {
            flags = ctx.getArgFlags(2) catch return .{ .deny = 22 };
            log.debug("openat: dirfd={d}, path={s}, flags=0x{x}", .{ dirfd, path, flags });
        }

        // Check against rules
        if (self.openat_rules) |rules| {
            // Check denied paths first
            for (rules.denied_paths) |denied| {
                if (std.mem.startsWith(u8, path, denied)) {
                    log.info("openat DENIED: {s} (matches denied prefix {s})", .{ path, denied });
                    return .{ .deny = 13 }; // EACCES
                }
            }

            // Check if write access requested
            const is_write = (flags & (linux.O.WRONLY | linux.O.RDWR | linux.O.CREAT | linux.O.TRUNC)) != 0;
            if (is_write) {
                var allowed = false;
                for (rules.writable_paths) |writable| {
                    if (std.mem.startsWith(u8, path, writable)) {
                        allowed = true;
                        break;
                    }
                }
                if (!allowed) {
                    log.info("openat DENIED: {s} (write not allowed)", .{path});
                    return .{ .deny = 30 }; // EROFS
                }
            }

            // Check allowed paths
            for (rules.allowed_paths) |allowed| {
                if (std.mem.startsWith(u8, path, allowed)) {
                    log.debug("openat ALLOWED: {s} (matches {s})", .{ path, allowed });
                    return .allow;
                }
            }
        }

        // Default: allow for now (will be configurable)
        return .allow;
    }

    /// Open file on behalf of tracee and inject FD using SECCOMP_ADDFD
    pub fn openAndInjectFd(self: *Broker, ctx: syscalls.Context, path: []const u8, flags: u32, mode: u32) syscalls.Result {
        const notify_fd = self.notify_fd orelse return .{ .deny = 1 };

        // Open the file in broker context
        const open_flags: std.posix.O = @bitCast(flags);
        const file = std.fs.openFileAbsolute(path, .{
            .mode = if (open_flags.WRONLY or open_flags.RDWR) .read_write else .read_only,
        }) catch |err| {
            log.debug("Broker open failed for {s}: {any}", .{ path, err });
            return .{ .deny = 13 }; // EACCES
        };

        const src_fd: u32 = @intCast(file.handle);

        // Inject the FD into the target process
        var addfd = linux.seccomp_notif_addfd{
            .id = ctx.id,
            .flags = linux.SECCOMP_ADDFD.FLAG_SETFD | linux.SECCOMP_ADDFD.FLAG_SEND,
            .srcfd = src_fd,
            .newfd = 0, // Let kernel choose
            .newfd_flags = if (flags & linux.O.CLOEXEC != 0) linux.O.CLOEXEC else 0,
        };
        _ = mode;

        const result = std.os.linux.ioctl(notify_fd, linux.SECCOMP.IOCTL_NOTIF_ADDFD, @intFromPtr(&addfd));
        file.close(); // Close our copy

        if (result < 0) {
            log.err("SECCOMP_ADDFD failed for {s}", .{path});
            return .{ .deny = 1 }; // EPERM
        }

        // Return the new FD number
        return .{ .value = @intCast(result) };
    }

    /// Handle ioctl syscalls
    pub fn handleIoctl(self: *Broker, ctx: syscalls.Context) syscalls.Result {
        const fd = ctx.getArgFd(0) catch return .{ .deny = 22 };
        const cmd = ctx.getArgFlags(1) catch return .{ .deny = 22 };

        log.debug("ioctl: fd={d}, cmd=0x{x}", .{ fd, cmd });

        if (self.ioctl_rules) |rules| {
            // Check against allowed commands
            for (rules.subsystems) |subsystem| {
                for (subsystem.allowed_cmds) |allowed_cmd| {
                    if (cmd == allowed_cmd) {
                        log.debug("ioctl ALLOWED: cmd=0x{x} (subsystem: {s})", .{ cmd, subsystem.name });
                        return .allow;
                    }
                }
            }
            // Not in any allowlist
            log.info("ioctl DENIED: fd={d}, cmd=0x{x}", .{ fd, cmd });
            return .{ .deny = 25 }; // ENOTTY
        }

        // Default allow list for common terminal/file ioctls
        const default_allowed = [_]u32{
            linux.IOCTL.TIOCGWINSZ,
            linux.IOCTL.TIOCGPGRP,
            linux.IOCTL.TIOCSPGRP,
            linux.IOCTL.FIONREAD,
            linux.IOCTL.FIONBIO,
            linux.IOCTL.TCGETS,
        };

        for (default_allowed) |allowed_cmd| {
            if (cmd == allowed_cmd) {
                return .allow;
            }
        }

        log.info("ioctl DENIED (default): fd={d}, cmd=0x{x}", .{ fd, cmd });
        return .{ .deny = 25 }; // ENOTTY
    }

    /// Handle socket/socketpair syscalls
    pub fn handleSocket(self: *Broker, ctx: syscalls.Context) syscalls.Result {
        const domain = ctx.getArgFd(0) catch return .{ .deny = 22 };
        const sock_type = ctx.getArgFlags(1) catch return .{ .deny = 22 };
        const protocol = ctx.getArgFd(2) catch return .{ .deny = 22 };

        log.debug("socket: domain={d}, type={d}, protocol={d}", .{ domain, sock_type, protocol });

        // Strip SOCK_NONBLOCK and SOCK_CLOEXEC flags for comparison
        const base_type = sock_type & ~@as(u32, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);

        if (self.socket_rules) |rules| {
            // Check denied domains first
            for (rules.denied_domains) |denied| {
                if (domain == denied) {
                    log.info("socket DENIED: domain={d} (in denied list)", .{domain});
                    return .{ .deny = 97 }; // EAFNOSUPPORT
                }
            }

            // Check allowed domains
            var domain_allowed = false;
            for (rules.allowed_domains) |allowed| {
                if (domain == allowed) {
                    domain_allowed = true;
                    break;
                }
            }

            if (!domain_allowed) {
                log.info("socket DENIED: domain={d} (not in allowed list)", .{domain});
                return .{ .deny = 97 }; // EAFNOSUPPORT
            }

            // Check allowed types
            for (rules.allowed_types) |allowed| {
                if (base_type == @as(u32, @intCast(allowed))) {
                    log.debug("socket ALLOWED: domain={d}, type={d}", .{ domain, sock_type });
                    return .allow;
                }
            }

            log.info("socket DENIED: type={d} (not in allowed list)", .{sock_type});
            return .{ .deny = 94 }; // ESOCKTNOSUPPORT
        }

        // Default policy: allow AF_UNIX and AF_INET/AF_INET6 with STREAM/DGRAM
        const allowed_domains = [_]i32{ linux.AF.UNIX, linux.AF.INET, linux.AF.INET6 };
        const allowed_types = [_]u32{ linux.SOCK.STREAM, linux.SOCK.DGRAM };

        var domain_ok = false;
        for (allowed_domains) |d| {
            if (domain == d) {
                domain_ok = true;
                break;
            }
        }

        if (!domain_ok) {
            log.info("socket DENIED (default): domain={d}", .{domain});
            return .{ .deny = 97 }; // EAFNOSUPPORT
        }

        for (allowed_types) |t| {
            if (base_type == t) {
                return .allow;
            }
        }

        // Deny RAW sockets by default
        if (base_type == linux.SOCK.RAW) {
            log.info("socket DENIED: RAW socket", .{});
            return .{ .deny = 1 }; // EPERM
        }

        return .allow;
    }

    /// Handle clone/clone3 syscalls
    pub fn handleClone(self: *Broker, ctx: syscalls.Context) syscalls.Result {
        const flags: u64 = ctx.getArgUnsigned(0) catch return .{ .deny = 22 };

        log.debug("clone: flags=0x{x}", .{flags});

        // Check for namespace creation flags - these should be denied
        const namespace_flags = linux.CLONE.NEWNS_ALL;

        if (flags & namespace_flags != 0) {
            log.info("clone DENIED: namespace flags present (0x{x})", .{flags & namespace_flags});
            return .{ .deny = 1 }; // EPERM
        }

        if (self.clone_rules) |rules| {
            // Check denied flags
            if (flags & rules.denied_flags != 0) {
                log.info("clone DENIED: denied flags present", .{});
                return .{ .deny = 1 }; // EPERM
            }

            // Check if only allowed flags are used
            if (flags & ~rules.allowed_flags != 0) {
                log.info("clone DENIED: unknown flags present", .{});
                return .{ .deny = 22 }; // EINVAL
            }
        }

        // Thread-like clone is allowed
        return .allow;
    }

    /// Handle execve/execveat syscalls
    pub fn handleExec(self: *Broker, ctx: syscalls.Context) syscalls.Result {
        var path_buf: [4096]u8 = undefined;

        // For execve: pathname is arg 0
        // For execveat: dirfd is arg 0, pathname is arg 1
        const path_arg: usize = if (ctx.nr == linux.SYS.execveat) 1 else 0;

        const path = ctx.readStringArg(path_arg, &path_buf) catch |err| {
            log.debug("Failed to read exec path: {any}", .{err});
            return .{ .deny = 14 }; // EFAULT
        };

        log.debug("exec: path={s}", .{path});

        // Default allowed paths for binaries
        const allowed_prefixes = [_][]const u8{
            "/usr/bin/",
            "/usr/sbin/",
            "/bin/",
            "/sbin/",
            "/usr/local/bin/",
        };

        for (allowed_prefixes) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) {
                log.debug("exec ALLOWED: {s}", .{path});
                return .allow;
            }
        }

        // Check if it's a relative path in work directory (for builds)
        if (!std.mem.startsWith(u8, path, "/")) {
            // Relative paths - allow by default for now
            return .allow;
        }

        log.info("exec DENIED: {s}", .{path});
        _ = self;
        return .{ .deny = 13 }; // EACCES
    }

    /// Handle prctl syscalls
    pub fn handlePrctl(self: *Broker, ctx: syscalls.Context) syscalls.Result {
        const option = ctx.getArgFd(0) catch return .{ .deny = 22 };

        log.debug("prctl: option={d}", .{option});

        // Deny dangerous prctl operations
        for (linux.PR.DANGEROUS) |dangerous| {
            if (option == dangerous) {
                log.info("prctl DENIED: option={d} (dangerous)", .{option});
                return .{ .deny = 1 }; // EPERM
            }
        }

        _ = self;
        return .allow;
    }

    /// Stop the broker
    pub fn stop(self: *Broker) void {
        self.running.store(false, .release);
    }

    /// Get average latency in nanoseconds
    pub fn getAverageLatencyNs(self: *const Broker) u64 {
        if (self.stats.requests_received == 0) return 0;
        return self.stats.total_latency_ns / self.stats.requests_received;
    }
};

/// Get syscall name for audit logging
fn getSyscallName(nr: i32) ?[]const u8 {
    return switch (nr) {
        linux.SYS.openat => "openat",
        linux.SYS.openat2 => "openat2",
        linux.SYS.ioctl => "ioctl",
        linux.SYS.socket => "socket",
        linux.SYS.socketpair => "socketpair",
        linux.SYS.clone => "clone",
        linux.SYS.clone3 => "clone3",
        linux.SYS.execve => "execve",
        linux.SYS.execveat => "execveat",
        linux.SYS.prctl => "prctl",
        else => null,
    };
}

/// Rules for openat/openat2 mediation
pub const OpenatRules = struct {
    allowed_paths: []const []const u8,
    denied_paths: []const []const u8,
    writable_paths: []const []const u8,
    /// Paths that require RESOLVE_BENEATH or RESOLVE_IN_ROOT for TOCTOU resistance
    sensitive_paths: []const []const u8 = &.{},
    /// Whether to require RESOLVE_BENEATH for sensitive paths (openat2 only)
    require_resolve_beneath: bool = false,
};

/// Rules for ioctl mediation
pub const IoctlRules = struct {
    pub const Subsystem = struct {
        name: []const u8,
        allowed_cmds: []const u32,
    };

    subsystems: []const Subsystem,
};

/// Rules for socket mediation
pub const SocketRules = struct {
    allowed_domains: []const i32,
    allowed_types: []const i32,
    denied_domains: []const i32,
};

/// Rules for clone mediation
pub const CloneRules = struct {
    allowed_flags: u64,
    denied_flags: u64,
};

/// Default rules for CI runner profile
pub const DefaultRules = struct {
    pub const openat = OpenatRules{
        .allowed_paths = &.{ "/", "/usr", "/lib", "/bin", "/etc", "/tmp", "/work", "/proc", "/sys", "/dev" },
        .denied_paths = &.{ "/etc/shadow", "/etc/gshadow", "/root/.ssh" },
        .writable_paths = &.{ "/tmp", "/work", "/dev/null", "/dev/zero" },
    };

    pub const ioctl = IoctlRules{
        .subsystems = &.{
            .{ .name = "tty", .allowed_cmds = &.{ linux.IOCTL.TIOCGWINSZ, linux.IOCTL.TIOCGPGRP, linux.IOCTL.TIOCSPGRP, linux.IOCTL.TCGETS } },
            .{ .name = "file", .allowed_cmds = &.{ linux.IOCTL.FIONREAD, linux.IOCTL.FIONBIO } },
        },
    };

    pub const socket = SocketRules{
        .allowed_domains = &.{ linux.AF.UNIX, linux.AF.INET, linux.AF.INET6 },
        .allowed_types = &.{ linux.SOCK.STREAM, linux.SOCK.DGRAM },
        .denied_domains = &.{ linux.AF.NETLINK, linux.AF.PACKET },
    };

    pub const clone = CloneRules{
        .allowed_flags = linux.CLONE.THREAD_FLAGS | linux.CLONE.CHILD_CLEARTID | linux.CLONE.CHILD_SETTID | linux.CLONE.PARENT_SETTID,
        .denied_flags = linux.CLONE.NEWNS_ALL,
    };
};

// Tests
test "broker initialization" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();
    try std.testing.expect(!broker.running.load(.acquire));
}

test "default rules" {
    // Verify default rules are valid
    try std.testing.expect(DefaultRules.openat.allowed_paths.len > 0);
    try std.testing.expect(DefaultRules.socket.allowed_domains.len > 0);
    try std.testing.expect(DefaultRules.clone.denied_flags & linux.CLONE.NEWNS != 0);
}

test "getSyscallName" {
    try std.testing.expectEqualStrings("openat", getSyscallName(linux.SYS.openat).?);
    try std.testing.expectEqualStrings("clone", getSyscallName(linux.SYS.clone).?);
    try std.testing.expect(getSyscallName(9999) == null);
}

test "handleSocket - allowed domains" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();
    broker.socket_rules = &DefaultRules.socket;

    // Test AF_UNIX + STREAM (allowed)
    const ctx_unix = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.socket,
        .args = .{ @as(u64, @intCast(linux.AF.UNIX)), linux.SOCK.STREAM, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result_unix = broker.handleSocket(ctx_unix);
    try std.testing.expect(result_unix == .allow);

    // Test AF_INET6 + DGRAM (allowed)
    const ctx_inet6 = syscalls.Context{
        .id = 2,
        .pid = 1000,
        .nr = linux.SYS.socket,
        .args = .{ @as(u64, @intCast(linux.AF.INET6)), linux.SOCK.DGRAM, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result_inet6 = broker.handleSocket(ctx_inet6);
    try std.testing.expect(result_inet6 == .allow);
}

test "handleSocket - denied domains" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();
    broker.socket_rules = &DefaultRules.socket;

    // Test AF_NETLINK (denied)
    const ctx_netlink = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.socket,
        .args = .{ @as(u64, @intCast(linux.AF.NETLINK)), linux.SOCK.DGRAM, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result = broker.handleSocket(ctx_netlink);
    try std.testing.expectEqual(@as(i32, 97), result.deny); // EAFNOSUPPORT

    // Test AF_PACKET (denied)
    const ctx_packet = syscalls.Context{
        .id = 2,
        .pid = 1000,
        .nr = linux.SYS.socket,
        .args = .{ @as(u64, @intCast(linux.AF.PACKET)), linux.SOCK.RAW, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result_packet = broker.handleSocket(ctx_packet);
    try std.testing.expectEqual(@as(i32, 97), result_packet.deny);
}

test "handleClone - namespace flags denied" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();
    broker.clone_rules = &DefaultRules.clone;

    // Test CLONE_NEWNS (denied - namespace creation)
    const ctx_newns = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.clone,
        .args = .{ linux.CLONE.NEWNS, 0, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result = broker.handleClone(ctx_newns);
    try std.testing.expectEqual(@as(i32, 1), result.deny); // EPERM

    // Test CLONE_NEWPID (denied)
    const ctx_newpid = syscalls.Context{
        .id = 2,
        .pid = 1000,
        .nr = linux.SYS.clone,
        .args = .{ linux.CLONE.NEWPID, 0, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result_newpid = broker.handleClone(ctx_newpid);
    try std.testing.expectEqual(@as(i32, 1), result_newpid.deny);
}

test "handleClone - thread flags allowed" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();
    broker.clone_rules = &DefaultRules.clone;

    // Test thread-like clone (allowed)
    const thread_flags = linux.CLONE.VM | linux.CLONE.FS | linux.CLONE.FILES | linux.CLONE.SIGHAND | linux.CLONE.THREAD;
    const ctx_thread = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.clone,
        .args = .{ thread_flags, 0, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result = broker.handleClone(ctx_thread);
    try std.testing.expect(result == .allow);
}

test "handleIoctl - default allowed" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    // Test TIOCGWINSZ (allowed by default)
    const ctx = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.ioctl,
        .args = .{ 1, linux.IOCTL.TIOCGWINSZ, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result = broker.handleIoctl(ctx);
    try std.testing.expect(result == .allow);
}

test "handleIoctl - unknown denied" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    // Test unknown ioctl (denied)
    const ctx = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.ioctl,
        .args = .{ 1, 0xDEADBEEF, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result = broker.handleIoctl(ctx);
    try std.testing.expectEqual(@as(i32, 25), result.deny); // ENOTTY
}

test "handlePrctl - dangerous operations denied" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    // Test PR_SET_SECCOMP (dangerous)
    const ctx = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.prctl,
        .args = .{ @as(u64, @intCast(linux.PR.SET_SECCOMP)), 0, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result = broker.handlePrctl(ctx);
    try std.testing.expectEqual(@as(i32, 1), result.deny); // EPERM
}

test "handlePrctl - safe operations allowed" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    // Test PR_SET_NAME (safe)
    const ctx = syscalls.Context{
        .id = 1,
        .pid = 1000,
        .nr = linux.SYS.prctl,
        .args = .{ @as(u64, @intCast(linux.PR.SET_NAME)), 0, 0, 0, 0, 0 },
        .allocator = std.testing.allocator,
    };
    const result = broker.handlePrctl(ctx);
    try std.testing.expect(result == .allow);
}

test "broker statistics" {
    var broker = Broker.init(std.testing.allocator, .{});
    defer broker.deinit();

    try std.testing.expectEqual(@as(u64, 0), broker.stats.requests_received);
    try std.testing.expectEqual(@as(u64, 0), broker.getAverageLatencyNs());
}

test "config defaults" {
    const config = Config{};
    try std.testing.expectEqual(@as(u32, 256), config.max_inflight);
    try std.testing.expectEqual(@as(u32, 200), config.timeout_ms);
}
