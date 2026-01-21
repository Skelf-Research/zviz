const std = @import("std");
const log = @import("log.zig");
const errors = @import("errors.zig");

/// ZViz runtime configuration
/// Can be loaded from a config file or environment variables

pub const Config = struct {
    /// Runtime settings
    runtime: RuntimeConfig = .{},

    /// Logging settings
    logging: LoggingConfig = .{},

    /// Broker settings
    broker: BrokerConfig = .{},

    /// Resource defaults
    resources: ResourceDefaults = .{},

    /// Security settings
    security: SecurityConfig = .{},
};

pub const RuntimeConfig = struct {
    /// State directory for container metadata
    state_dir: []const u8 = "/run/zviz",

    /// Root directory for container rootfs
    root_dir: []const u8 = "/var/lib/zviz",

    /// Default profile to use if none specified
    default_profile: []const u8 = "ci-runner",

    /// Enable rootless mode
    rootless: bool = false,

    /// Timeout for container operations (ms)
    operation_timeout_ms: u32 = 30000,
};

pub const LoggingConfig = struct {
    /// Log level: debug, info, warn, error
    level: LogLevel = .info,

    /// Log format: text, json
    format: LogFormat = .text,

    /// Log file path (null for stderr)
    file: ?[]const u8 = null,

    /// Include timestamps
    timestamps: bool = true,

    /// Include source location
    source_location: bool = false,

    pub const LogLevel = enum {
        debug,
        info,
        warn,
        @"error",

        pub fn fromString(s: []const u8) ?LogLevel {
            const map = std.StaticStringMap(LogLevel).initComptime(.{
                .{ "debug", .debug },
                .{ "info", .info },
                .{ "warn", .warn },
                .{ "warning", .warn },
                .{ "error", .@"error" },
            });
            return map.get(s);
        }
    };

    pub const LogFormat = enum {
        text,
        json,

        pub fn fromString(s: []const u8) ?LogFormat {
            if (std.mem.eql(u8, s, "text")) return .text;
            if (std.mem.eql(u8, s, "json")) return .json;
            return null;
        }
    };
};

pub const BrokerConfig = struct {
    /// Maximum in-flight broker requests
    max_inflight: u32 = 256,

    /// Timeout for broker requests (ms)
    timeout_ms: u32 = 200,

    /// Enable broker metrics
    metrics_enabled: bool = true,

    /// Audit log path (null to disable)
    audit_log: ?[]const u8 = null,
};

pub const ResourceDefaults = struct {
    /// Default memory limit
    memory_max: ?[]const u8 = "512M",

    /// Default PID limit
    pids_max: ?u32 = 100,

    /// Default CPU quota (as percentage, e.g., 200 = 2 CPUs)
    cpu_percent: ?u32 = null,
};

pub const SecurityConfig = struct {
    /// Require seccomp
    require_seccomp: bool = true,

    /// Require user namespaces
    require_userns: bool = true,

    /// Enable AppArmor/SELinux if available
    enable_lsm: bool = true,

    /// No new privileges
    no_new_privs: bool = true,

    /// Readonly rootfs by default
    readonly_rootfs: bool = true,

    /// Drop all capabilities by default
    drop_all_caps: bool = true,
};

/// Configuration file locations (in order of priority)
const CONFIG_PATHS = [_][]const u8{
    "/etc/zviz/config.json",
    "/etc/zviz.json",
};

/// Environment variable prefix
const ENV_PREFIX = "ZVIZ_";

/// Load configuration from file and environment
pub fn load(allocator: std.mem.Allocator) !Config {
    var config = Config{};

    // Try to load from file
    for (CONFIG_PATHS) |path| {
        if (loadFromFile(allocator, path)) |file_config| {
            config = mergeConfig(config, file_config);
            log.debug("Loaded config from {s}", .{path});
            break;
        } else |_| {
            // File not found or parse error, continue
        }
    }

    // Override with environment variables
    config = loadFromEnv(config);

    return config;
}

/// Load configuration from a specific file
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return errors.Error.ProfileParseError;
    };
    defer allocator.free(content);

    return parseJson(content);
}

/// Parse JSON configuration
fn parseJson(content: []const u8) !Config {
    var config = Config{};

    // Simple JSON parsing for key config values
    // In production, would use a proper JSON parser

    if (std.mem.indexOf(u8, content, "\"state_dir\"")) |_| {
        if (extractJsonString(content, "state_dir")) |val| {
            config.runtime.state_dir = val;
        }
    }

    if (std.mem.indexOf(u8, content, "\"log_level\"")) |_| {
        if (extractJsonString(content, "log_level")) |val| {
            if (LoggingConfig.LogLevel.fromString(val)) |level| {
                config.logging.level = level;
            }
        }
    }

    if (std.mem.indexOf(u8, content, "\"rootless\"")) |_| {
        config.runtime.rootless = std.mem.indexOf(u8, content, "\"rootless\": true") != null or
            std.mem.indexOf(u8, content, "\"rootless\":true") != null;
    }

    return config;
}

/// Extract a string value from JSON (simple implementation)
fn extractJsonString(content: []const u8, key: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&buf, "\"{s}\": \"", .{key}) catch return null;

    const start_idx = std.mem.indexOf(u8, content, pattern) orelse {
        // Try without space
        const pattern2 = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
        const start2 = std.mem.indexOf(u8, content, pattern2) orelse return null;
        const value_start = start2 + pattern2.len;
        const value_end = std.mem.indexOfPos(u8, content, value_start, "\"") orelse return null;
        return content[value_start..value_end];
    };

    const value_start = start_idx + pattern.len;
    const value_end = std.mem.indexOfPos(u8, content, value_start, "\"") orelse return null;
    return content[value_start..value_end];
}

/// Load configuration from environment variables
fn loadFromEnv(config: Config) Config {
    var result = config;

    // ZVIZ_STATE_DIR
    if (std.posix.getenv("ZVIZ_STATE_DIR")) |val| {
        result.runtime.state_dir = val;
    }

    // ZVIZ_LOG_LEVEL
    if (std.posix.getenv("ZVIZ_LOG_LEVEL")) |val| {
        if (LoggingConfig.LogLevel.fromString(val)) |level| {
            result.logging.level = level;
        }
    }

    // ZVIZ_LOG_FORMAT
    if (std.posix.getenv("ZVIZ_LOG_FORMAT")) |val| {
        if (LoggingConfig.LogFormat.fromString(val)) |fmt| {
            result.logging.format = fmt;
        }
    }

    // ZVIZ_ROOTLESS
    if (std.posix.getenv("ZVIZ_ROOTLESS")) |val| {
        result.runtime.rootless = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
    }

    // ZVIZ_BROKER_TIMEOUT
    if (std.posix.getenv("ZVIZ_BROKER_TIMEOUT")) |val| {
        if (std.fmt.parseInt(u32, val, 10)) |timeout| {
            result.broker.timeout_ms = timeout;
        } else |_| {}
    }

    // ZVIZ_MEMORY_MAX
    if (std.posix.getenv("ZVIZ_MEMORY_MAX")) |val| {
        result.resources.memory_max = val;
    }

    // ZVIZ_PIDS_MAX
    if (std.posix.getenv("ZVIZ_PIDS_MAX")) |val| {
        if (std.fmt.parseInt(u32, val, 10)) |pids| {
            result.resources.pids_max = pids;
        } else |_| {}
    }

    return result;
}

/// Merge two configs (second takes priority)
fn mergeConfig(base: Config, overlay: Config) Config {
    var result = base;

    // Merge runtime
    if (!std.mem.eql(u8, overlay.runtime.state_dir, "/run/zviz")) {
        result.runtime.state_dir = overlay.runtime.state_dir;
    }
    if (overlay.runtime.rootless) {
        result.runtime.rootless = true;
    }

    // Merge logging
    if (overlay.logging.level != .info) {
        result.logging.level = overlay.logging.level;
    }
    if (overlay.logging.format != .text) {
        result.logging.format = overlay.logging.format;
    }

    return result;
}

/// Generate a default config file
pub fn generateDefault() []const u8 {
    return
        \\{
        \\  "runtime": {
        \\    "state_dir": "/run/zviz",
        \\    "root_dir": "/var/lib/zviz",
        \\    "default_profile": "ci-runner",
        \\    "rootless": false,
        \\    "operation_timeout_ms": 30000
        \\  },
        \\  "logging": {
        \\    "level": "info",
        \\    "format": "text",
        \\    "timestamps": true
        \\  },
        \\  "broker": {
        \\    "max_inflight": 256,
        \\    "timeout_ms": 200,
        \\    "metrics_enabled": true
        \\  },
        \\  "resources": {
        \\    "memory_max": "512M",
        \\    "pids_max": 100
        \\  },
        \\  "security": {
        \\    "require_seccomp": true,
        \\    "require_userns": true,
        \\    "enable_lsm": true,
        \\    "no_new_privs": true,
        \\    "readonly_rootfs": true,
        \\    "drop_all_caps": true
        \\  }
        \\}
        \\
    ;
}

// ============================================================================
// Tests
// ============================================================================

test "default config" {
    const config = Config{};
    try std.testing.expectEqualStrings("/run/zviz", config.runtime.state_dir);
    try std.testing.expect(!config.runtime.rootless);
    try std.testing.expectEqual(LoggingConfig.LogLevel.info, config.logging.level);
}

test "parse json config" {
    const json =
        \\{
        \\  "state_dir": "/custom/path",
        \\  "log_level": "debug",
        \\  "rootless": true
        \\}
    ;

    const config = try parseJson(json);
    try std.testing.expectEqualStrings("/custom/path", config.runtime.state_dir);
    try std.testing.expectEqual(LoggingConfig.LogLevel.debug, config.logging.level);
    try std.testing.expect(config.runtime.rootless);
}

test "log level from string" {
    try std.testing.expectEqual(LoggingConfig.LogLevel.debug, LoggingConfig.LogLevel.fromString("debug"));
    try std.testing.expectEqual(LoggingConfig.LogLevel.info, LoggingConfig.LogLevel.fromString("info"));
    try std.testing.expectEqual(LoggingConfig.LogLevel.warn, LoggingConfig.LogLevel.fromString("warn"));
    try std.testing.expectEqual(LoggingConfig.LogLevel.warn, LoggingConfig.LogLevel.fromString("warning"));
    try std.testing.expect(LoggingConfig.LogLevel.fromString("invalid") == null);
}

test "generate default config" {
    const default = generateDefault();
    try std.testing.expect(default.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, default, "state_dir") != null);
}
