const std = @import("std");

/// Linux syscall numbers (x86_64)
pub const SYS = struct {
    pub const read = 0;
    pub const write = 1;
    pub const open = 2;
    pub const close = 3;
    pub const stat = 4;
    pub const fstat = 5;
    pub const lstat = 6;
    pub const poll = 7;
    pub const lseek = 8;
    pub const mmap = 9;
    pub const mprotect = 10;
    pub const munmap = 11;
    pub const brk = 12;
    pub const ioctl = 16;
    pub const access = 21;
    pub const pipe = 22;
    pub const dup = 32;
    pub const dup2 = 33;
    pub const socket = 41;
    pub const connect = 42;
    pub const accept = 43;
    pub const sendto = 44;
    pub const recvfrom = 45;
    pub const bind = 49;
    pub const listen = 50;
    pub const socketpair = 53;
    pub const clone = 56;
    pub const fork = 57;
    pub const vfork = 58;
    pub const execve = 59;
    pub const exit = 60;
    pub const wait4 = 61;
    pub const kill = 62;
    pub const fcntl = 72;
    pub const flock = 73;
    pub const fsync = 74;
    pub const truncate = 76;
    pub const ftruncate = 77;
    pub const getdents = 78;
    pub const getcwd = 79;
    pub const chdir = 80;
    pub const fchdir = 81;
    pub const rename = 82;
    pub const mkdir = 83;
    pub const rmdir = 84;
    pub const creat = 85;
    pub const link = 86;
    pub const unlink = 87;
    pub const symlink = 88;
    pub const readlink = 89;
    pub const chmod = 90;
    pub const fchmod = 91;
    pub const chown = 92;
    pub const fchown = 93;
    pub const lchown = 94;
    pub const umask = 95;
    pub const ptrace = 101;
    pub const getuid = 102;
    pub const getgid = 104;
    pub const setuid = 105;
    pub const setgid = 106;
    pub const geteuid = 107;
    pub const getegid = 108;
    pub const setpgid = 109;
    pub const getppid = 110;
    pub const getpgrp = 111;
    pub const setsid = 112;
    pub const setreuid = 113;
    pub const setregid = 114;
    pub const getgroups = 115;
    pub const setgroups = 116;
    pub const setresuid = 117;
    pub const getresuid = 118;
    pub const setresgid = 119;
    pub const getresgid = 120;
    pub const getpgid = 121;
    pub const setfsuid = 122;
    pub const setfsgid = 123;
    pub const getsid = 124;
    pub const capget = 125;
    pub const capset = 126;
    pub const prctl = 157;
    pub const mount = 165;
    pub const umount2 = 166;
    pub const pivot_root = 155;
    pub const sethostname = 170;
    pub const setdomainname = 171;
    pub const init_module = 175;
    pub const delete_module = 176;
    pub const kexec_load = 246;
    pub const openat = 257;
    pub const mkdirat = 258;
    pub const mknodat = 259;
    pub const fchownat = 260;
    pub const unlinkat = 263;
    pub const renameat = 264;
    pub const linkat = 265;
    pub const symlinkat = 266;
    pub const readlinkat = 267;
    pub const fchmodat = 268;
    pub const faccessat = 269;
    pub const unshare = 272;
    pub const setns = 308;
    pub const seccomp = 317;
    pub const bpf = 321;
    pub const execveat = 322;
    pub const userfaultfd = 323;
    pub const perf_event_open = 298;
    pub const clone3 = 435;
    pub const openat2 = 437;
    pub const pidfd_open = 434;
    pub const faccessat2 = 439;
};

/// Socket address families
pub const AF = struct {
    pub const UNSPEC = 0;
    pub const UNIX = 1;
    pub const LOCAL = 1;
    pub const INET = 2;
    pub const AX25 = 3;
    pub const IPX = 4;
    pub const APPLETALK = 5;
    pub const NETROM = 6;
    pub const BRIDGE = 7;
    pub const ATMPVC = 8;
    pub const X25 = 9;
    pub const INET6 = 10;
    pub const ROSE = 11;
    pub const DECnet = 12;
    pub const NETBEUI = 13;
    pub const SECURITY = 14;
    pub const KEY = 15;
    pub const NETLINK = 16;
    pub const PACKET = 17;
    pub const ASH = 18;
    pub const ECONET = 19;
    pub const ATMSVC = 20;
    pub const RDS = 21;
    pub const SNA = 22;
    pub const IRDA = 23;
    pub const PPPOX = 24;
    pub const WANPIPE = 25;
    pub const LLC = 26;
    pub const IB = 27;
    pub const MPLS = 28;
    pub const CAN = 29;
    pub const TIPC = 30;
    pub const BLUETOOTH = 31;
    pub const IUCV = 32;
    pub const RXRPC = 33;
    pub const ISDN = 34;
    pub const PHONET = 35;
    pub const IEEE802154 = 36;
    pub const CAIF = 37;
    pub const ALG = 38;
    pub const NFC = 39;
    pub const VSOCK = 40;
    pub const KCM = 41;
    pub const QIPCRTR = 42;
    pub const SMC = 43;
    pub const XDP = 44;
};

/// Socket types
pub const SOCK = struct {
    pub const STREAM = 1;
    pub const DGRAM = 2;
    pub const RAW = 3;
    pub const RDM = 4;
    pub const SEQPACKET = 5;
    pub const DCCP = 6;
    pub const PACKET = 10;
    pub const NONBLOCK = 0o4000;
    pub const CLOEXEC = 0o2000000;
};

/// Clone flags
pub const CLONE = struct {
    pub const VM = 0x00000100;
    pub const FS = 0x00000200;
    pub const FILES = 0x00000400;
    pub const SIGHAND = 0x00000800;
    pub const PIDFD = 0x00001000;
    pub const PTRACE = 0x00002000;
    pub const VFORK = 0x00004000;
    pub const PARENT = 0x00008000;
    pub const THREAD = 0x00010000;
    pub const NEWNS = 0x00020000;
    pub const SYSVSEM = 0x00040000;
    pub const SETTLS = 0x00080000;
    pub const PARENT_SETTID = 0x00100000;
    pub const CHILD_CLEARTID = 0x00200000;
    pub const DETACHED = 0x00400000;
    pub const UNTRACED = 0x00800000;
    pub const CHILD_SETTID = 0x01000000;
    pub const NEWCGROUP = 0x02000000;
    pub const NEWUTS = 0x04000000;
    pub const NEWIPC = 0x08000000;
    pub const NEWUSER = 0x10000000;
    pub const NEWPID = 0x20000000;
    pub const NEWNET = 0x40000000;
    pub const IO = 0x80000000;

    /// All namespace flags combined
    pub const NEWNS_ALL = NEWNS | NEWCGROUP | NEWUTS | NEWIPC | NEWUSER | NEWPID | NEWNET;

    /// Thread-like clone flags (allowed)
    pub const THREAD_FLAGS = VM | FS | FILES | SIGHAND | THREAD | SYSVSEM;
};

/// openat2 resolve flags
pub const RESOLVE = struct {
    pub const NO_XDEV = 0x01;
    pub const NO_MAGICLINKS = 0x02;
    pub const NO_SYMLINKS = 0x04;
    pub const BENEATH = 0x08;
    pub const IN_ROOT = 0x10;
    pub const CACHED = 0x20;
};

/// open flags
pub const O = struct {
    pub const RDONLY = 0o0;
    pub const WRONLY = 0o1;
    pub const RDWR = 0o2;
    pub const CREAT = 0o100;
    pub const EXCL = 0o200;
    pub const NOCTTY = 0o400;
    pub const TRUNC = 0o1000;
    pub const APPEND = 0o2000;
    pub const NONBLOCK = 0o4000;
    pub const DSYNC = 0o10000;
    pub const SYNC = 0o4010000;
    pub const RSYNC = 0o4010000;
    pub const DIRECTORY = 0o200000;
    pub const NOFOLLOW = 0o400000;
    pub const CLOEXEC = 0o2000000;
    pub const PATH = 0o10000000;
    pub const NOATIME = 0o1000000;
    pub const TMPFILE = 0o20200000;
};

/// prctl operations
pub const PR = struct {
    pub const SET_PDEATHSIG = 1;
    pub const GET_PDEATHSIG = 2;
    pub const GET_DUMPABLE = 3;
    pub const SET_DUMPABLE = 4;
    pub const GET_UNALIGN = 5;
    pub const SET_UNALIGN = 6;
    pub const GET_KEEPCAPS = 7;
    pub const SET_KEEPCAPS = 8;
    pub const GET_FPEMU = 9;
    pub const SET_FPEMU = 10;
    pub const GET_FPEXC = 11;
    pub const SET_FPEXC = 12;
    pub const GET_TIMING = 13;
    pub const SET_TIMING = 14;
    pub const SET_NAME = 15;
    pub const GET_NAME = 16;
    pub const GET_ENDIAN = 19;
    pub const SET_ENDIAN = 20;
    pub const GET_SECCOMP = 21;
    pub const SET_SECCOMP = 22;
    pub const CAPBSET_READ = 23;
    pub const CAPBSET_DROP = 24;
    pub const GET_TSC = 25;
    pub const SET_TSC = 26;
    pub const GET_SECUREBITS = 27;
    pub const SET_SECUREBITS = 28;
    pub const SET_TIMERSLACK = 29;
    pub const GET_TIMERSLACK = 30;
    pub const SET_NO_NEW_PRIVS = 38;
    pub const GET_NO_NEW_PRIVS = 39;
    pub const SET_CHILD_SUBREAPER = 36;
    pub const GET_CHILD_SUBREAPER = 37;

    /// Dangerous prctl operations that should be denied
    pub const DANGEROUS = [_]c_int{
        SET_SECCOMP,
        CAPBSET_DROP,
        SET_SECUREBITS,
        SET_NO_NEW_PRIVS, // After initial setup
    };
};

/// Seccomp constants
pub const SECCOMP = struct {
    pub const MODE_DISABLED = 0;
    pub const MODE_STRICT = 1;
    pub const MODE_FILTER = 2;

    pub const SET_MODE_STRICT = 0;
    pub const SET_MODE_FILTER = 1;
    pub const GET_ACTION_AVAIL = 2;
    pub const GET_NOTIF_SIZES = 3;

    pub const FILTER_FLAG_TSYNC = 1 << 0;
    pub const FILTER_FLAG_LOG = 1 << 1;
    pub const FILTER_FLAG_SPEC_ALLOW = 1 << 2;
    pub const FILTER_FLAG_NEW_LISTENER = 1 << 3;
    pub const FILTER_FLAG_TSYNC_ESRCH = 1 << 4;

    pub const RET_KILL_PROCESS = 0x80000000;
    pub const RET_KILL_THREAD = 0x00000000;
    pub const RET_TRAP = 0x00030000;
    pub const RET_ERRNO = 0x00050000;
    pub const RET_USER_NOTIF = 0x7fc00000;
    pub const RET_TRACE = 0x7ff00000;
    pub const RET_LOG = 0x7ffc0000;
    pub const RET_ALLOW = 0x7fff0000;

    /// IOCTL commands for seccomp notification
    pub const IOCTL_NOTIF_RECV = 0xc0502100;
    pub const IOCTL_NOTIF_SEND = 0xc0182101;
    pub const IOCTL_NOTIF_ID_VALID = 0x40082102;
    pub const IOCTL_NOTIF_ADDFD = 0x40182103;
};

/// Seccomp notification request (kernel -> userspace)
pub const seccomp_notif = extern struct {
    id: u64,
    pid: u32,
    flags: u32,
    data: seccomp_data,
};

/// Seccomp data passed with notification
pub const seccomp_data = extern struct {
    nr: c_int,
    arch: u32,
    instruction_pointer: u64,
    args: [6]u64,
};

/// Seccomp notification response (userspace -> kernel)
pub const seccomp_notif_resp = extern struct {
    id: u64,
    val: i64,
    @"error": i32,
    flags: u32,
};

/// Seccomp notification sizes
pub const seccomp_notif_sizes = extern struct {
    seccomp_notif: u16,
    seccomp_notif_resp: u16,
    seccomp_data: u16,
};

/// Add file descriptor to target process
pub const seccomp_notif_addfd = extern struct {
    id: u64,
    flags: u32,
    srcfd: u32,
    newfd: u32,
    newfd_flags: u32,
};

/// Common ioctl commands
pub const IOCTL = struct {
    // Terminal ioctls
    pub const TIOCGWINSZ = 0x5413;
    pub const TIOCSWINSZ = 0x5414;
    pub const TIOCGPGRP = 0x540F;
    pub const TIOCSPGRP = 0x5410;
    pub const TIOCSCTTY = 0x540E;
    pub const TIOCNOTTY = 0x5422;
    pub const TIOCGPTN = 0x80045430;
    pub const TIOCSPTLCK = 0x40045431;

    // File ioctls
    pub const FIONREAD = 0x541B;
    pub const FIONBIO = 0x5421;
    pub const FIOCLEX = 0x5451;
    pub const FIONCLEX = 0x5450;

    // Generic
    pub const TCGETS = 0x5401;
    pub const TCSETS = 0x5402;
};

/// openat2 structure (how argument)
pub const open_how = extern struct {
    flags: u64,
    mode: u64,
    resolve: u64,
};

/// Seccomp ADDFD flags
pub const SECCOMP_ADDFD = struct {
    pub const FLAG_SETFD = 1 << 0; // Set close-on-exec
    pub const FLAG_SEND = 1 << 1; // Send as notification response
};

/// AT constants for *at syscalls
pub const AT = struct {
    pub const FDCWD: i32 = -100;
    pub const SYMLINK_NOFOLLOW = 0x100;
    pub const REMOVEDIR = 0x200;
    pub const SYMLINK_FOLLOW = 0x400;
    pub const NO_AUTOMOUNT = 0x800;
    pub const EMPTY_PATH = 0x1000;
};

/// Read open_how structure from process memory
pub fn readOpenHow(pid: i32, addr: u64) !open_how {
    var how: open_how = undefined;
    const bytes = std.mem.asBytes(&how);
    const read_bytes = try readProcessMemory(pid, addr, bytes);
    if (read_bytes < @sizeOf(open_how)) {
        return error.IncompleteRead;
    }
    return how;
}

/// Process memory reading via /proc/pid/mem
pub fn readProcessMemory(pid: i32, remote_addr: u64, buf: []u8) !usize {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/mem", .{pid}) catch return error.InvalidPath;

    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch {
        return error.ProcessMemoryReadFailed;
    };
    defer file.close();

    file.seekTo(remote_addr) catch {
        return error.ProcessMemoryReadFailed;
    };

    return file.read(buf) catch error.ProcessMemoryReadFailed;
}

/// Read null-terminated string from process memory
pub fn readProcessString(pid: i32, remote_addr: u64, buf: []u8) ![]const u8 {
    const bytes_read = try readProcessMemory(pid, remote_addr, buf);
    if (bytes_read == 0) return error.EmptyString;

    // Find null terminator
    for (buf[0..bytes_read], 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }

    // No null terminator found, string is truncated
    return buf[0..bytes_read];
}

test "syscall constants" {
    try std.testing.expectEqual(@as(c_int, 257), SYS.openat);
    try std.testing.expectEqual(@as(c_int, 437), SYS.openat2);
    try std.testing.expectEqual(@as(c_int, 56), SYS.clone);
}

test "clone flags" {
    // Thread flags should not include namespace flags
    try std.testing.expect(CLONE.THREAD_FLAGS & CLONE.NEWNS_ALL == 0);
}
