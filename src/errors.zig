const std = @import("std");

/// Exit codes following OCI runtime spec conventions
pub const ExitCode = struct {
    pub const SUCCESS: u8 = 0;
    pub const GENERAL_ERROR: u8 = 1;
    pub const INVALID_ARGUMENT: u8 = 2;
    pub const CONTAINER_NOT_FOUND: u8 = 3;
    pub const CONTAINER_ALREADY_EXISTS: u8 = 4;
    pub const CONTAINER_NOT_RUNNING: u8 = 5;
    pub const CONTAINER_ALREADY_RUNNING: u8 = 6;
    pub const PERMISSION_DENIED: u8 = 7;
    pub const RESOURCE_EXHAUSTED: u8 = 8;
    pub const NAMESPACE_ERROR: u8 = 10;
    pub const SECCOMP_ERROR: u8 = 11;
    pub const CGROUP_ERROR: u8 = 12;
    pub const NETWORK_ERROR: u8 = 13;
    pub const PROFILE_ERROR: u8 = 14;
    pub const BROKER_ERROR: u8 = 15;
    pub const LSM_ERROR: u8 = 16;
    pub const HOOK_ERROR: u8 = 17;
    pub const SYSTEM_ERROR: u8 = 126;
    pub const COMMAND_NOT_FOUND: u8 = 127;
};

/// ZigViz error categories
pub const Error = error{
    // Container lifecycle errors
    ContainerNotFound,
    ContainerAlreadyExists,
    ContainerNotRunning,
    ContainerAlreadyRunning,
    InvalidContainerId,
    InvalidBundlePath,

    // Namespace errors
    NamespaceCreationFailed,
    NamespaceJoinFailed,
    CapabilityDropFailed,

    // Seccomp errors
    SeccompLoadFailed,
    SeccompNotifyFailed,
    SeccompFilterInvalid,

    // Broker errors
    BrokerTimeout,
    BrokerOverloaded,
    SyscallDenied,
    InvalidSyscallArgs,

    // LSM errors
    LsmNotAvailable,
    LsmProfileLoadFailed,
    LsmPolicyViolation,

    // Cgroup errors
    CgroupNotAvailable,
    CgroupCreationFailed,
    CgroupLimitExceeded,

    // Network errors
    NetworkSetupFailed,
    NetworkPolicyViolation,

    // Profile/Policy errors
    ProfileNotFound,
    ProfileParseError,
    ProfileValidationFailed,
    HostRequirementNotMet,

    // Hook errors
    HookError,
    HookTimeout,

    // Generic errors
    PermissionDenied,
    ResourceExhausted,
    SystemError,
};

/// Error context with additional information
pub const ErrorContext = struct {
    err: Error,
    message: []const u8,
    syscall: ?[]const u8 = null,
    errno: ?i32 = null,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}: {s}", .{ @errorName(self.err), self.message });
        if (self.syscall) |sc| {
            try writer.print(" (syscall: {s})", .{sc});
        }
        if (self.errno) |e| {
            try writer.print(" (errno: {d})", .{e});
        }
    }
};

/// Convert OS error to ZigViz error
pub fn fromOsError(err: std.posix.E) Error {
    return switch (err) {
        .PERM, .ACCES => Error.PermissionDenied,
        .NOMEM, .NOSPC => Error.ResourceExhausted,
        .NOENT => Error.ContainerNotFound,
        .EXIST => Error.ContainerAlreadyExists,
        else => Error.SystemError,
    };
}

/// Get errno from the last system call
pub fn getErrno() i32 {
    return @intFromEnum(std.posix.errno(std.posix.system.getErrno()));
}

/// Convert ZigViz error to exit code
pub fn toExitCode(err: Error) u8 {
    return switch (err) {
        Error.ContainerNotFound => ExitCode.CONTAINER_NOT_FOUND,
        Error.ContainerAlreadyExists => ExitCode.CONTAINER_ALREADY_EXISTS,
        Error.ContainerNotRunning => ExitCode.CONTAINER_NOT_RUNNING,
        Error.ContainerAlreadyRunning => ExitCode.CONTAINER_ALREADY_RUNNING,
        Error.InvalidContainerId, Error.InvalidBundlePath => ExitCode.INVALID_ARGUMENT,
        Error.NamespaceCreationFailed, Error.NamespaceJoinFailed, Error.CapabilityDropFailed => ExitCode.NAMESPACE_ERROR,
        Error.SeccompLoadFailed, Error.SeccompNotifyFailed, Error.SeccompFilterInvalid => ExitCode.SECCOMP_ERROR,
        Error.BrokerTimeout, Error.BrokerOverloaded, Error.SyscallDenied, Error.InvalidSyscallArgs => ExitCode.BROKER_ERROR,
        Error.LsmNotAvailable, Error.LsmProfileLoadFailed, Error.LsmPolicyViolation => ExitCode.LSM_ERROR,
        Error.CgroupNotAvailable, Error.CgroupCreationFailed, Error.CgroupLimitExceeded => ExitCode.CGROUP_ERROR,
        Error.NetworkSetupFailed, Error.NetworkPolicyViolation => ExitCode.NETWORK_ERROR,
        Error.ProfileNotFound, Error.ProfileParseError, Error.ProfileValidationFailed, Error.HostRequirementNotMet => ExitCode.PROFILE_ERROR,
        Error.HookError, Error.HookTimeout => ExitCode.HOOK_ERROR,
        Error.PermissionDenied => ExitCode.PERMISSION_DENIED,
        Error.ResourceExhausted => ExitCode.RESOURCE_EXHAUSTED,
        Error.SystemError => ExitCode.SYSTEM_ERROR,
    };
}

/// Get human-readable error description
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        Error.ContainerNotFound => "Container not found",
        Error.ContainerAlreadyExists => "Container already exists",
        Error.ContainerNotRunning => "Container is not running",
        Error.ContainerAlreadyRunning => "Container is already running",
        Error.InvalidContainerId => "Invalid container ID",
        Error.InvalidBundlePath => "Invalid bundle path",
        Error.NamespaceCreationFailed => "Failed to create namespace",
        Error.NamespaceJoinFailed => "Failed to join namespace",
        Error.CapabilityDropFailed => "Failed to drop capabilities",
        Error.SeccompLoadFailed => "Failed to load seccomp filter",
        Error.SeccompNotifyFailed => "Seccomp notification failed",
        Error.SeccompFilterInvalid => "Invalid seccomp filter",
        Error.BrokerTimeout => "Broker request timed out",
        Error.BrokerOverloaded => "Broker is overloaded",
        Error.SyscallDenied => "Syscall denied by policy",
        Error.InvalidSyscallArgs => "Invalid syscall arguments",
        Error.LsmNotAvailable => "LSM not available on this system",
        Error.LsmProfileLoadFailed => "Failed to load LSM profile",
        Error.LsmPolicyViolation => "LSM policy violation",
        Error.CgroupNotAvailable => "Cgroups not available",
        Error.CgroupCreationFailed => "Failed to create cgroup",
        Error.CgroupLimitExceeded => "Cgroup limit exceeded",
        Error.NetworkSetupFailed => "Network setup failed",
        Error.NetworkPolicyViolation => "Network policy violation",
        Error.ProfileNotFound => "Profile not found",
        Error.ProfileParseError => "Failed to parse profile",
        Error.ProfileValidationFailed => "Profile validation failed",
        Error.HostRequirementNotMet => "Host requirement not met",
        Error.HookError => "Hook execution failed",
        Error.HookTimeout => "Hook execution timed out",
        Error.PermissionDenied => "Permission denied",
        Error.ResourceExhausted => "Resource exhausted",
        Error.SystemError => "System error",
    };
}

test "error context formatting" {
    const ctx = ErrorContext{
        .err = Error.SyscallDenied,
        .message = "openat blocked by policy",
        .syscall = "openat",
        .errno = 1,
    };

    var buf: [256]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{any}", .{ctx}) catch unreachable;
    try std.testing.expect(result.len > 0);
}
