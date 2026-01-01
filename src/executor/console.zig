const std = @import("std");
const log = @import("../log.zig");

/// PTY/console support for container execution
/// Provides pseudo-terminal allocation and handling for interactive containers

// ============================================================================
// PTY Master/Slave pair
// ============================================================================

pub const Pty = struct {
    master_fd: i32,
    slave_fd: i32,
    slave_path: [108]u8,
    slave_path_len: usize,

    pub fn open() !Pty {
        // Open the PTY master
        const master_fd = std.os.linux.syscall2(
            .openat,
            @as(usize, @bitCast(@as(isize, std.os.linux.AT.FDCWD))),
            @intFromPtr("/dev/ptmx"),
        );

        if (@as(isize, @bitCast(master_fd)) < 0) {
            return error.PtyOpenFailed;
        }

        const master: i32 = @intCast(master_fd);

        // Grant access to slave (grantpt equivalent)
        // In modern Linux with devpts, this is automatic

        // Unlock the slave (unlockpt equivalent)
        var unlock: i32 = 0;
        const ioctl_result = std.os.linux.ioctl(@intCast(master), TIOCSPTLCK, @intFromPtr(&unlock));
        if (@as(isize, @bitCast(ioctl_result)) < 0) {
            _ = std.os.linux.close(@intCast(master));
            return error.PtyUnlockFailed;
        }

        // Get slave PTY number
        var pty_num: i32 = undefined;
        const num_result = std.os.linux.ioctl(@intCast(master), TIOCGPTN, @intFromPtr(&pty_num));
        if (@as(isize, @bitCast(num_result)) < 0) {
            _ = std.os.linux.close(@intCast(master));
            return error.PtyGetNumFailed;
        }

        // Build slave path
        var slave_path: [108]u8 = undefined;
        const path_slice = std.fmt.bufPrint(&slave_path, "/dev/pts/{d}", .{pty_num}) catch {
            _ = std.os.linux.close(@intCast(master));
            return error.PtyPathFailed;
        };

        return .{
            .master_fd = master,
            .slave_fd = -1,
            .slave_path = slave_path,
            .slave_path_len = path_slice.len,
        };
    }

    /// Open the slave side of the PTY
    pub fn openSlave(self: *Pty) !void {
        if (self.slave_fd >= 0) return;

        // Build null-terminated path
        var path_z: [109]u8 = undefined;
        const path = self.slave_path[0..self.slave_path_len];
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const slave_fd = std.os.linux.open(@ptrCast(&path_z), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);

        if (@as(isize, @bitCast(slave_fd)) < 0) {
            return error.PtySlaveOpenFailed;
        }

        self.slave_fd = @intCast(slave_fd);
    }

    /// Get the slave path as a slice
    pub fn getSlavePath(self: *const Pty) []const u8 {
        return self.slave_path[0..self.slave_path_len];
    }

    /// Close the master fd
    pub fn closeMaster(self: *Pty) void {
        if (self.master_fd >= 0) {
            _ = std.os.linux.close(@intCast(self.master_fd));
            self.master_fd = -1;
        }
    }

    /// Close the slave fd
    pub fn closeSlave(self: *Pty) void {
        if (self.slave_fd >= 0) {
            _ = std.os.linux.close(@intCast(self.slave_fd));
            self.slave_fd = -1;
        }
    }

    /// Close all fds
    pub fn close(self: *Pty) void {
        self.closeMaster();
        self.closeSlave();
    }

    /// Set up slave as controlling terminal for current process
    pub fn makeControllingTerminal(self: *Pty) !void {
        // Create new session (become session leader)
        const sid = std.os.linux.syscall0(.setsid);
        if (@as(isize, @bitCast(sid)) < 0) {
            return error.SetsidFailed;
        }

        // Open slave if not already open
        try self.openSlave();

        // Set as controlling terminal
        const ioctl_result = std.os.linux.ioctl(@intCast(self.slave_fd), TIOCSCTTY, 1);
        if (@as(isize, @bitCast(ioctl_result)) < 0) {
            log.warn("TIOCSCTTY failed, continuing anyway", .{});
        }
    }

    /// Redirect stdin/stdout/stderr to the slave PTY
    pub fn redirectStdio(self: *Pty) !void {
        try self.openSlave();

        // Duplicate slave to stdin, stdout, stderr
        inline for ([_]i32{ 0, 1, 2 }) |fd| {
            const result = std.os.linux.dup2(@intCast(self.slave_fd), fd);
            if (@as(isize, @bitCast(result)) < 0) {
                return error.Dup2Failed;
            }
        }

        // Close original slave fd if it's not 0, 1, or 2
        if (self.slave_fd > 2) {
            self.closeSlave();
        }
    }

    /// Set terminal window size
    pub fn setWinsize(self: *Pty, rows: u16, cols: u16) !void {
        const ws = Winsize{
            .ws_row = rows,
            .ws_col = cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const fd = if (self.slave_fd >= 0) self.slave_fd else self.master_fd;
        const result = std.os.linux.ioctl(@intCast(fd), TIOCSWINSZ, @intFromPtr(&ws));
        if (@as(isize, @bitCast(result)) < 0) {
            return error.SetWinsizeFailed;
        }
    }

    /// Get terminal window size
    pub fn getWinsize(self: *Pty) !Winsize {
        var ws: Winsize = undefined;
        const fd = if (self.slave_fd >= 0) self.slave_fd else self.master_fd;
        const result = std.os.linux.ioctl(@intCast(fd), TIOCGWINSZ, @intFromPtr(&ws));
        if (@as(isize, @bitCast(result)) < 0) {
            return error.GetWinsizeFailed;
        }
        return ws;
    }
};

// ============================================================================
// Terminal window size
// ============================================================================

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// ============================================================================
// Terminal I/O structures
// ============================================================================

pub const Termios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_line: u8,
    c_cc: [32]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

// ============================================================================
// IOCTL constants
// ============================================================================

const TIOCSPTLCK: u32 = 0x40045431; // Lock/unlock PTY
const TIOCGPTN: u32 = 0x80045430; // Get PTY number
const TIOCSCTTY: u32 = 0x540E; // Set controlling terminal
const TIOCGWINSZ: u32 = 0x5413; // Get window size
const TIOCSWINSZ: u32 = 0x5414; // Set window size

// ============================================================================
// Console handler for container I/O
// ============================================================================

pub const Console = struct {
    pty: ?Pty = null,
    socket_path: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Console {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Console) void {
        if (self.pty) |*pty| pty.close();
    }

    /// Create a new PTY for the container
    pub fn createPty(self: *Console) !void {
        self.pty = try Pty.open();
        log.debug("Created PTY: {s}", .{self.pty.?.getSlavePath()});
    }

    /// Set up the console for the child process
    pub fn setupForChild(self: *Console) !void {
        if (self.pty) |*pty| {
            // Close the master in child
            pty.closeMaster();

            // Set up as controlling terminal
            try pty.makeControllingTerminal();

            // Redirect stdio
            try pty.redirectStdio();
        }
    }

    /// Set up the console for the parent process
    pub fn setupForParent(self: *Console) void {
        if (self.pty) |*pty| {
            // Close the slave in parent
            pty.closeSlave();
        }
    }

    /// Get the master fd for I/O
    pub fn getMasterFd(self: *Console) ?i32 {
        if (self.pty) |pty| {
            return pty.master_fd;
        }
        return null;
    }

    /// Relay data from stdin to master
    pub fn relayInput(self: *Console, data: []const u8) !void {
        if (self.pty) |pty| {
            const result = std.os.linux.write(@intCast(pty.master_fd), data.ptr, data.len);
            if (@as(isize, @bitCast(result)) < 0) {
                return error.WriteFailed;
            }
        }
    }

    /// Relay data from master to stdout
    pub fn relayOutput(self: *Console, buf: []u8) !usize {
        if (self.pty) |pty| {
            const result = std.os.linux.read(@intCast(pty.master_fd), buf.ptr, buf.len);
            const signed: isize = @bitCast(result);
            if (signed < 0) {
                return error.ReadFailed;
            }
            return @intCast(signed);
        }
        return 0;
    }

    /// Set window size
    pub fn setSize(self: *Console, rows: u16, cols: u16) !void {
        if (self.pty) |*pty| {
            try pty.setWinsize(rows, cols);
        }
    }
};

// ============================================================================
// Console socket for OCI console socket support
// ============================================================================

pub const ConsoleSocket = struct {
    path: []const u8,
    fd: i32 = -1,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) ConsoleSocket {
        return .{
            .allocator = allocator,
            .path = path,
        };
    }

    pub fn deinit(self: *ConsoleSocket) void {
        if (self.fd >= 0) {
            _ = std.os.linux.close(@intCast(self.fd));
            self.fd = -1;
        }
    }

    /// Send master FD over unix socket to consumer
    pub fn sendMasterFd(self: *ConsoleSocket, master_fd: i32) !void {
        // Create unix socket
        const sock_fd = std.os.linux.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0);
        if (@as(isize, @bitCast(sock_fd)) < 0) {
            return error.SocketCreationFailed;
        }
        defer _ = std.os.linux.close(@intCast(sock_fd));

        // Connect to socket
        var addr: std.os.linux.sockaddr.un = .{
            .family = std.os.linux.AF.UNIX,
            .path = undefined,
        };

        if (self.path.len >= addr.path.len) {
            return error.PathTooLong;
        }

        @memcpy(addr.path[0..self.path.len], self.path);
        addr.path[self.path.len] = 0;

        const connect_result = std.os.linux.connect(
            @intCast(sock_fd),
            @ptrCast(&addr),
            @sizeOf(std.os.linux.sockaddr.un),
        );
        if (@as(isize, @bitCast(connect_result)) < 0) {
            return error.ConnectFailed;
        }

        // Send master FD using SCM_RIGHTS
        try sendFd(@intCast(sock_fd), master_fd);

        log.debug("Sent PTY master fd to console socket: {s}", .{self.path});
    }
};

// Control message header for SCM_RIGHTS
const cmsghdr = extern struct {
    len: usize,
    level: i32,
    type: i32,
};

const SOL_SOCKET: i32 = 1;
const SCM_RIGHTS: i32 = 1;

/// Send a file descriptor over a unix socket
fn sendFd(sock_fd: i32, fd_to_send: i32) !void {
    const cmsg_size = @sizeOf(cmsghdr) + @sizeOf(i32);
    var cmsg_buf: [cmsg_size]u8 align(@alignOf(cmsghdr)) = undefined;

    const cmsg: *cmsghdr = @ptrCast(&cmsg_buf);
    cmsg.* = .{
        .len = @intCast(cmsg_size),
        .level = SOL_SOCKET,
        .type = SCM_RIGHTS,
    };

    const fd_ptr: *i32 = @ptrCast(@alignCast(cmsg_buf[@sizeOf(cmsghdr)..]));
    fd_ptr.* = fd_to_send;

    const dummy: [1]u8 = .{0};
    var iov = [_]std.posix.iovec_const{.{
        .base = &dummy,
        .len = 1,
    }};

    var msg: std.os.linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &cmsg_buf,
        .controllen = cmsg_size,
        .flags = 0,
    };

    const result = std.os.linux.sendmsg(@intCast(sock_fd), &msg, 0);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.SendmsgFailed;
    }
}

// ============================================================================
// Tests
// ============================================================================

test "pty open and close" {
    // This test may fail if /dev/ptmx is not available
    const pty = Pty.open() catch |err| {
        // Skip if PTY not available
        log.debug("PTY not available: {s}", .{@errorName(err)});
        return;
    };
    var pty_mut = pty;
    defer pty_mut.close();

    try std.testing.expect(pty_mut.master_fd >= 0);
    try std.testing.expect(pty_mut.slave_path_len > 0);
}

test "console init" {
    var console = Console.init(std.testing.allocator);
    defer console.deinit();

    try std.testing.expect(console.pty == null);
}

test "winsize struct layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Winsize));
}
