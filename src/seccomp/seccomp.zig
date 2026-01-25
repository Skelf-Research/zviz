const std = @import("std");
const log = @import("../log.zig");
const errors = @import("../errors.zig");
const linux = @import("../syscalls/linux.zig");

/// Seccomp actions
pub const Action = enum(u32) {
    kill_process = 0x80000000,
    kill_thread = 0x00000000,
    trap = 0x00030000,
    errno = 0x00050000,
    user_notif = 0x7fc00000, // SECCOMP_RET_USER_NOTIF
    trace = 0x7ff00000,
    log = 0x7ffc0000,
    allow = 0x7fff0000,

    pub fn withErrno(errno: u16) u32 {
        return 0x00050000 | @as(u32, errno);
    }
};

/// Seccomp comparison operations
pub const Op = enum(u8) {
    ne = 0,
    lt = 1,
    le = 2,
    eq = 3,
    ge = 4,
    gt = 5,
    masked_eq = 6,
};

/// BPF instruction
pub const BpfInsn = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

/// BPF instruction codes
const BPF = struct {
    // Instruction classes
    const LD = 0x00;
    const LDX = 0x01;
    const ST = 0x02;
    const STX = 0x03;
    const ALU = 0x04;
    const JMP = 0x05;
    const RET = 0x06;
    const MISC = 0x07;

    // LD/LDX fields
    const W = 0x00; // Word (32-bit)
    const H = 0x08; // Halfword (16-bit)
    const B = 0x10; // Byte

    // LD/LDX source
    const IMM = 0x00; // Immediate
    const ABS = 0x20; // Absolute offset
    const IND = 0x40; // Indirect offset
    const MEM = 0x60; // Memory

    // JMP codes
    const JA = 0x00;
    const JEQ = 0x10;
    const JGT = 0x20;
    const JGE = 0x30;
    const JSET = 0x40;

    // Source for JMP/ALU
    const K = 0x00; // Use k
    const X = 0x08; // Use X register

    // Architecture (x86_64)
    const AUDIT_ARCH_X86_64 = 0xc000003e;

    // seccomp_data offsets
    const OFFSET_NR = 0; // Syscall number
    const OFFSET_ARCH = 4; // Architecture
    const OFFSET_INSTRUCTION_POINTER = 8;
    const OFFSET_ARGS = 16; // args[0]
};

/// BPF program (for seccomp)
pub const BpfProg = extern struct {
    len: c_ushort,
    filter: [*]const BpfInsn,
};

/// Syscall policy tiers
pub const SyscallPolicy = struct {
    /// Fast-path allowed syscalls (no mediation)
    allow: []const i32,
    /// Hard-denied syscalls (always blocked)
    deny: []const i32,
    /// Routed to broker via USER_NOTIF
    broker: []const i32,

    pub fn lookup(self: SyscallPolicy, syscall_nr: i32) Action {
        for (self.allow) |nr| {
            if (nr == syscall_nr) return .allow;
        }
        for (self.deny) |nr| {
            if (nr == syscall_nr) return .errno; // EPERM
        }
        for (self.broker) |nr| {
            if (nr == syscall_nr) return .user_notif;
        }
        // Default deny
        return .errno;
    }
};

/// BPF instruction builder helper
const BpfBuilder = struct {
    insns: std.ArrayList(BpfInsn),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) BpfBuilder {
        return .{
            .insns = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *BpfBuilder) void {
        self.insns.deinit(self.allocator);
    }

    fn len(self: *const BpfBuilder) usize {
        return self.insns.items.len;
    }

    /// Load word from seccomp_data at absolute offset
    fn ldAbsW(self: *BpfBuilder, offset: u32) !void {
        try self.insns.append(self.allocator, .{
            .code = BPF.LD | BPF.W | BPF.ABS,
            .jt = 0,
            .jf = 0,
            .k = offset,
        });
    }

    /// Jump if equal to immediate value
    fn jeqK(self: *BpfBuilder, k: u32, jt: u8, jf: u8) !void {
        try self.insns.append(self.allocator, .{
            .code = BPF.JMP | BPF.JEQ | BPF.K,
            .jt = jt,
            .jf = jf,
            .k = k,
        });
    }

    /// Unconditional jump
    fn ja(self: *BpfBuilder, k: u32) !void {
        try self.insns.append(self.allocator, .{
            .code = BPF.JMP | BPF.JA,
            .jt = 0,
            .jf = 0,
            .k = k,
        });
    }

    /// Return with immediate value
    fn retK(self: *BpfBuilder, k: u32) !void {
        try self.insns.append(self.allocator, .{
            .code = BPF.RET | BPF.K,
            .jt = 0,
            .jf = 0,
            .k = k,
        });
    }

    fn toOwnedSlice(self: *BpfBuilder) ![]BpfInsn {
        return self.insns.toOwnedSlice(self.allocator);
    }
};

/// Socket domain constants for BPF filtering
const AF_UNIX: u32 = 1;
const AF_INET: u32 = 2;
const AF_INET6: u32 = 10;

/// Number of additional BPF instructions for socket domain filtering
const SOCKET_FILTER_INSNS: usize = 5;

/// Generate BPF program from syscall policy
/// When verbose=true, denied syscalls are routed through USER_NOTIF for logging
pub fn generateBpf(allocator: std.mem.Allocator, policy: SyscallPolicy, verbose: bool) ![]BpfInsn {
    log.debug("Generating BPF: {d} allow, {d} deny, {d} broker, verbose={}", .{
        policy.allow.len,
        policy.deny.len,
        policy.broker.len,
        verbose,
    });

    var builder = BpfBuilder.init(allocator);
    errdefer builder.deinit();

    // Structure:
    // [0] Load arch
    // [1] Check arch, fail if not x86_64
    // [2] Load syscall nr
    // [3..3+allow] Check allow list → jump to RET ALLOW
    // [3+allow..3+allow+deny] Check deny list → jump to RET ERRNO
    // [3+allow+deny..3+allow+deny+broker] Check broker list → jump to RET USER_NOTIF
    // [socket filter: 5 insns] Check socket domain args
    // RET ERRNO (default deny / denied domains)
    // RET ALLOW (allowed syscalls / allowed domains)
    // RET USER_NOTIF (broker)
    // RET KILL (arch mismatch)

    const allow_count = policy.allow.len;
    const deny_count = policy.deny.len;
    const broker_count = policy.broker.len;
    const total_checks = allow_count + deny_count + broker_count;

    // Extra offset for the socket filter section between checks and returns
    const sf: u8 = SOCKET_FILTER_INSNS;

    // Load architecture
    try builder.ldAbsW(BPF.OFFSET_ARCH);

    // Check architecture (kill if not x86_64)
    const kill_offset: u8 = @intCast(1 + total_checks + sf + 3); // All checks + socket filter + 3 returns before KILL
    try builder.jeqK(BPF.AUDIT_ARCH_X86_64, 0, kill_offset);

    // Load syscall number
    try builder.ldAbsW(BPF.OFFSET_NR);

    // Generate allow list checks: if match, jump to RET ALLOW
    for (policy.allow, 0..) |syscall_nr, i| {
        const remaining: u8 = @intCast(total_checks - i - 1);
        const allow_ret_offset: u8 = remaining + sf + 1; // Past remaining checks + socket filter + RET ERRNO
        try builder.jeqK(@intCast(syscall_nr), allow_ret_offset, 0);
    }

    // Generate deny list checks: if match, jump to RET ERRNO (or USER_NOTIF if verbose)
    for (policy.deny, 0..) |syscall_nr, i| {
        const remaining: u8 = @intCast(total_checks - allow_count - i - 1);
        if (verbose) {
            // Verbose mode: route denies through broker for logging
            const deny_ret_offset: u8 = remaining + sf + 2; // Past socket filter + ERRNO + ALLOW to USER_NOTIF
            try builder.jeqK(@intCast(syscall_nr), deny_ret_offset, 0);
        } else {
            // Normal mode: immediate EPERM
            const deny_ret_offset: u8 = remaining + sf; // Past remaining checks + socket filter to RET ERRNO
            try builder.jeqK(@intCast(syscall_nr), deny_ret_offset, 0);
        }
    }

    // Generate broker list checks: if match, jump to RET USER_NOTIF
    for (policy.broker, 0..) |syscall_nr, i| {
        const remaining: u8 = @intCast(total_checks - allow_count - deny_count - i - 1);
        const broker_ret_offset: u8 = remaining + sf + 2; // Past socket filter + ERRNO + ALLOW
        try builder.jeqK(@intCast(syscall_nr), broker_ret_offset, 0);
    }

    // Socket domain filter section (5 instructions)
    // At this point, A register still has the syscall number.
    // Check if it's socket (41). If yes, filter by domain. If no, deny.
    try builder.jeqK(41, 0, 4); // JEQ socket: if match continue, else skip 4 to RET ERRNO
    try builder.ldAbsW(BPF.OFFSET_ARGS); // Load args[0] low 32 bits = domain
    try builder.jeqK(AF_UNIX, 3, 0); // AF_UNIX → skip 3 to RET ALLOW
    try builder.jeqK(AF_INET, 2, 0); // AF_INET → skip 2 to RET ALLOW
    try builder.jeqK(AF_INET6, 1, 0); // AF_INET6 → skip 1 to RET ALLOW
    // Fall through: denied domain → RET ERRNO

    // Return instructions
    try builder.retK(Action.withErrno(1)); // RET ERRNO (default deny + denied socket domains)
    try builder.retK(@intFromEnum(Action.allow)); // RET ALLOW (allowed syscalls + allowed socket domains)
    try builder.retK(@intFromEnum(Action.user_notif)); // RET USER_NOTIF (broker)
    try builder.retK(@intFromEnum(Action.kill_process)); // RET KILL (arch mismatch)

    return builder.toOwnedSlice();
}

/// Load seccomp filter for the current process (without notification)
pub fn loadFilter(bpf: []const BpfInsn) !void {
    log.info("Loading seccomp filter with {d} instructions", .{bpf.len});

    const prog = BpfProg{
        .len = @intCast(bpf.len),
        .filter = bpf.ptr,
    };

    // First, set PR_SET_NO_NEW_PRIVS (required for unprivileged seccomp)
    const nnp_result = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (nnp_result != 0) {
        log.err("Failed to set NO_NEW_PRIVS: {d}", .{nnp_result});
        return errors.Error.SeccompLoadFailed;
    }

    // Load the filter using prctl
    const result = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_SECCOMP), linux.SECCOMP.MODE_FILTER, @intFromPtr(&prog), 0, 0);
    if (result != 0) {
        log.err("Failed to load seccomp filter: {d}", .{result});
        return errors.Error.SeccompLoadFailed;
    }

    log.info("Seccomp filter loaded successfully", .{});
}

/// Load filter and get notification fd for broker
pub fn loadFilterWithNotify(bpf: []const BpfInsn) !std.posix.fd_t {
    log.info("Loading seccomp filter with notify fd ({d} instructions)", .{bpf.len});

    const prog = BpfProg{
        .len = @intCast(bpf.len),
        .filter = bpf.ptr,
    };

    // First, set PR_SET_NO_NEW_PRIVS (required for unprivileged seccomp)
    const nnp_result = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (nnp_result != 0) {
        log.err("Failed to set NO_NEW_PRIVS: {d}", .{nnp_result});
        return errors.Error.SeccompLoadFailed;
    }

    // Use seccomp syscall with SECCOMP_FILTER_FLAG_NEW_LISTENER
    const flags = linux.SECCOMP.FILTER_FLAG_NEW_LISTENER;
    const result = std.os.linux.syscall3(
        .seccomp,
        linux.SECCOMP.SET_MODE_FILTER,
        flags,
        @intFromPtr(&prog),
    );

    const signed_result: isize = @bitCast(result);
    if (signed_result < 0) {
        log.err("Failed to load seccomp filter with notify: {d}", .{signed_result});
        return errors.Error.SeccompNotifyFailed;
    }

    const notify_fd: std.posix.fd_t = @intCast(result);
    log.info("Seccomp filter loaded, notify_fd={d}", .{notify_fd});
    return notify_fd;
}

/// Validate notification ID is still valid (process hasn't died/been killed)
pub fn validateNotifId(notify_fd: std.posix.fd_t, id: u64) bool {
    var id_copy = id;
    const result = std.os.linux.ioctl(notify_fd, linux.SECCOMP.IOCTL_NOTIF_ID_VALID, @intFromPtr(&id_copy));
    return result == 0;
}

/// Common syscall numbers (x86_64)
pub const Syscall = struct {
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
    pub const socket = 41;
    pub const clone = 56;
    pub const fork = 57;
    pub const execve = 59;
    pub const exit = 60;
    pub const openat = 257;
    pub const openat2 = 437;
    pub const clone3 = 435;

    // Dangerous syscalls
    pub const ptrace = 101;
    pub const mount = 165;
    pub const umount2 = 166;
    pub const pivot_root = 155;
    pub const init_module = 175;
    pub const delete_module = 176;
    pub const kexec_load = 246;
    pub const perf_event_open = 298;
    pub const bpf = 321;
    pub const userfaultfd = 323;
    pub const unshare = 272;
    pub const setns = 308;
};

/// Get human-readable syscall name from number (x86_64)
pub fn getSyscallName(nr: i32) []const u8 {
    return switch (nr) {
        0 => "read",
        1 => "write",
        2 => "open",
        3 => "close",
        4 => "stat",
        5 => "fstat",
        6 => "lstat",
        7 => "poll",
        8 => "lseek",
        9 => "mmap",
        10 => "mprotect",
        11 => "munmap",
        12 => "brk",
        16 => "ioctl",
        24 => "sched_yield",
        41 => "socket",
        56 => "clone",
        57 => "fork",
        59 => "execve",
        60 => "exit",
        97 => "getrlimit",
        101 => "ptrace",
        135 => "personality",
        155 => "pivot_root",
        157 => "prctl",
        160 => "setrlimit",
        163 => "acct",
        165 => "mount",
        166 => "umount2",
        167 => "swapon",
        168 => "swapoff",
        169 => "reboot",
        170 => "sethostname",
        171 => "setdomainname",
        172 => "iopl",
        173 => "ioperm",
        175 => "init_module",
        176 => "delete_module",
        179 => "quotactl",
        203 => "sched_setaffinity",
        204 => "sched_getaffinity",
        246 => "kexec_load",
        248 => "add_key",
        249 => "request_key",
        257 => "openat",
        272 => "unshare",
        298 => "perf_event_open",
        308 => "setns",
        309 => "getcpu",
        313 => "finit_module",
        321 => "bpf",
        323 => "userfaultfd",
        435 => "clone3",
        437 => "openat2",
        else => "unknown",
    };
}

test "syscall policy lookup" {
    const policy = SyscallPolicy{
        .allow = &.{ Syscall.read, Syscall.write },
        .deny = &.{ Syscall.ptrace, Syscall.bpf },
        .broker = &.{ Syscall.openat, Syscall.ioctl },
    };

    try std.testing.expectEqual(Action.allow, policy.lookup(Syscall.read));
    try std.testing.expectEqual(Action.user_notif, policy.lookup(Syscall.openat));
}

test "bpf generation" {
    const policy = SyscallPolicy{
        .allow = &.{Syscall.read},
        .deny = &.{Syscall.ptrace},
        .broker = &.{Syscall.openat},
    };

    const bpf = try generateBpf(std.testing.allocator, policy, false);
    defer std.testing.allocator.free(bpf);
    try std.testing.expect(bpf.len > 0);
}

test "bpf generation verbose mode" {
    const policy = SyscallPolicy{
        .allow = &.{Syscall.read},
        .deny = &.{Syscall.ptrace},
        .broker = &.{Syscall.openat},
    };

    const bpf = try generateBpf(std.testing.allocator, policy, true);
    defer std.testing.allocator.free(bpf);
    try std.testing.expect(bpf.len > 0);
}

test "getSyscallName" {
    try std.testing.expectEqualStrings("read", getSyscallName(0));
    try std.testing.expectEqualStrings("ptrace", getSyscallName(101));
    try std.testing.expectEqualStrings("mount", getSyscallName(165));
    try std.testing.expectEqualStrings("unknown", getSyscallName(9999));
}
