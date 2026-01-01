const std = @import("std");
const log = @import("log.zig");
const errors = @import("errors.zig");
const containment = @import("containment/containment.zig");
const seccomp = @import("seccomp/seccomp.zig");
const broker = @import("broker/broker.zig");
const cgroup = @import("cgroup/cgroup.zig");
const network = @import("network/network.zig");
const schema = @import("schema/schema.zig");
const compiler = @import("compiler/compiler.zig");
const executor = @import("executor/mod.zig");

/// OCI container state
pub const State = struct {
    oci_version: []const u8 = "1.0.2",
    id: []const u8,
    status: Status,
    pid: ?i32,
    bundle: []const u8,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,

    pub const Status = enum {
        creating,
        created,
        running,
        stopped,

        pub fn string(self: Status) []const u8 {
            return @tagName(self);
        }
    };
};

/// Container configuration from config.json
pub const Config = struct {
    oci_version: []const u8,
    root: Root,
    process: ?Process = null,
    hostname: ?[]const u8 = null,
    mounts: ?[]Mount = null,
    linux: ?LinuxConfig = null,

    pub const Root = struct {
        path: []const u8,
        readonly: bool = false,
    };

    pub const Process = struct {
        terminal: bool = false,
        cwd: []const u8 = "/",
        args: []const []const u8,
        env: ?[]const []const u8 = null,
        user: ?User = null,

        pub const User = struct {
            uid: u32 = 0,
            gid: u32 = 0,
        };
    };

    pub const Mount = struct {
        destination: []const u8,
        type: ?[]const u8 = null,
        source: ?[]const u8 = null,
        options: ?[]const []const u8 = null,
    };

    pub const LinuxConfig = struct {
        namespaces: ?[]Namespace = null,
        resources: ?Resources = null,

        pub const Namespace = struct {
            type: []const u8,
            path: ?[]const u8 = null,
        };

        pub const Resources = struct {
            memory: ?Memory = null,
            cpu: ?Cpu = null,
            pids: ?Pids = null,

            pub const Memory = struct {
                limit: ?i64 = null,
            };

            pub const Cpu = struct {
                quota: ?i64 = null,
                period: ?u64 = null,
            };

            pub const Pids = struct {
                limit: ?i64 = null,
            };
        };
    };
};

/// Container runtime state directory
pub const STATE_DIR = "/run/zigviz";

/// ZigViz annotation keys for pod configuration
pub const Annotations = struct {
    pub const PREFIX = "zigviz.io/";
    pub const PROFILE = "zigviz.io/profile";
    pub const AUDIT = "zigviz.io/audit";
    pub const BROKER_TIMEOUT = "zigviz.io/broker-timeout";
    pub const STRICT_MODE = "zigviz.io/strict-mode";
};

/// Extract annotation value from JSON content
/// Looks for pattern: "key": "value" in the content
fn extractAnnotationValue(content: []const u8, key: []const u8) ?[]const u8 {
    // Build search pattern: "key":
    var pattern_buf: [128]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return null;

    // Find the key in content
    const key_pos = std.mem.indexOf(u8, content, pattern) orelse return null;
    const value_start = key_pos + pattern.len;

    // Skip whitespace and find opening quote
    var pos = value_start;
    while (pos < content.len and (content[pos] == ' ' or content[pos] == '\t' or content[pos] == '\n')) {
        pos += 1;
    }

    if (pos >= content.len or content[pos] != '"') {
        return null;
    }
    pos += 1; // Skip opening quote

    // Find closing quote
    const value_begin = pos;
    while (pos < content.len and content[pos] != '"') {
        // Handle escaped quotes
        if (content[pos] == '\\' and pos + 1 < content.len) {
            pos += 2;
            continue;
        }
        pos += 1;
    }

    if (pos >= content.len) {
        return null;
    }

    return content[value_begin..pos];
}

/// Container instance that manages the full lifecycle
pub const Container = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    bundle: []const u8,
    status: State.Status,
    pid: ?i32,
    config: ?Config,
    profile: ?schema.Profile,
    cgroup_manager: ?cgroup.CgroupManager,
    broker_instance: ?broker.Broker,

    // Annotation-derived settings
    profile_name: ?[]const u8 = null,
    audit_enabled: bool = false,
    broker_timeout_override: ?u32 = null,

    // Console socket for OCI console protocol
    console_socket: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, bundle: []const u8) !Container {
        return .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .bundle = try allocator.dupe(u8, bundle),
            .status = .creating,
            .pid = null,
            .config = null,
            .profile = null,
            .cgroup_manager = null,
            .broker_instance = null,
            .profile_name = null,
            .audit_enabled = false,
            .broker_timeout_override = null,
        };
    }

    pub fn deinit(self: *Container) void {
        self.allocator.free(self.id);
        self.allocator.free(self.bundle);
        if (self.cgroup_manager) |*cgm| cgm.deinit();
    }

    /// Load OCI config.json from bundle
    pub fn loadConfig(self: *Container) !void {
        var path_buf: [4096]u8 = undefined;
        const config_path = std.fmt.bufPrint(&path_buf, "{s}/config.json", .{self.bundle}) catch {
            return errors.Error.InvalidBundlePath;
        };

        const file = std.fs.openFileAbsolute(config_path, .{}) catch {
            log.err("Cannot open config.json: {s}", .{config_path});
            return errors.Error.InvalidBundlePath;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            return errors.Error.ProfileParseError;
        };
        defer self.allocator.free(content);

        if (content.len == 0) {
            return errors.Error.ProfileParseError;
        }

        // Parse annotations from config.json
        self.parseAnnotations(content);

        log.debug("Config loaded from {s} ({d} bytes)", .{ config_path, content.len });
    }

    /// Parse ZigViz annotations from OCI config content
    fn parseAnnotations(self: *Container, content: []const u8) void {
        // Look for annotations section in JSON
        // Simple string-based parsing for common annotation patterns

        // Parse profile annotation: "zigviz.io/profile": "ci-runner"
        if (extractAnnotationValue(content, Annotations.PROFILE)) |value| {
            self.profile_name = value;
            log.debug("Annotation {s} = {s}", .{ Annotations.PROFILE, value });
        }

        // Parse audit annotation: "zigviz.io/audit": "true"
        if (extractAnnotationValue(content, Annotations.AUDIT)) |value| {
            self.audit_enabled = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1");
            log.debug("Annotation {s} = {}", .{ Annotations.AUDIT, self.audit_enabled });
        }

        // Parse broker timeout: "zigviz.io/broker-timeout": "200"
        if (extractAnnotationValue(content, Annotations.BROKER_TIMEOUT)) |value| {
            if (std.fmt.parseInt(u32, value, 10)) |timeout| {
                self.broker_timeout_override = timeout;
                log.debug("Annotation {s} = {d}", .{ Annotations.BROKER_TIMEOUT, timeout });
            } else |_| {}
        }
    }

    /// Load ZigViz profile
    /// Priority: explicit path > annotation profile > default
    pub fn loadProfile(self: *Container, profile_path: ?[]const u8) !void {
        // 1. Explicit profile path takes priority
        if (profile_path) |path| {
            self.profile = try schema.loadProfile(self.allocator, path);
            log.debug("Profile loaded from path: {s}", .{self.profile.?.name});
            return;
        }

        // 2. Check annotation-derived profile name
        if (self.profile_name) |name| {
            if (self.loadBuiltinProfile(name)) |profile| {
                self.profile = profile;
                log.debug("Profile loaded from annotation: {s}", .{name});
                return;
            }

            // Try loading from standard profile directory
            var path_buf: [256]u8 = undefined;
            const profile_file = std.fmt.bufPrint(&path_buf, "/etc/zigviz/profiles/{s}.json", .{name}) catch null;
            if (profile_file) |path| {
                if (schema.loadProfile(self.allocator, path)) |profile| {
                    self.profile = profile;
                    log.debug("Profile loaded from /etc/zigviz/profiles: {s}", .{name});
                    return;
                } else |_| {
                    log.warn("Profile '{s}' not found, using default", .{name});
                }
            }
        }

        // 3. Default profile
        self.profile = schema.defaultCiRunner();
        log.debug("Using default profile: {s}", .{self.profile.?.name});
    }

    /// Load a built-in profile by name
    fn loadBuiltinProfile(_: *Container, name: []const u8) ?schema.Profile {
        if (std.mem.eql(u8, name, "ci-runner") or std.mem.eql(u8, name, "zigviz-ci")) {
            return schema.BaseProfiles.ciRunner();
        }
        if (std.mem.eql(u8, name, "hostile-tenant") or std.mem.eql(u8, name, "zigviz-hostile")) {
            return schema.BaseProfiles.hostile();
        }
        if (std.mem.eql(u8, name, "minimal") or std.mem.eql(u8, name, "zigviz-minimal")) {
            return schema.BaseProfiles.minimal();
        }
        return null;
    }

    /// Set up cgroups for resource limits
    pub fn setupCgroups(self: *Container) !void {
        var cgm = try cgroup.CgroupManager.init(self.allocator, self.id);
        try cgm.create();

        if (self.profile) |profile| {
            var limits = cgroup.Limits{};
            if (profile.resources.memory_max) |mem_str| {
                limits.memory_max = cgroup.parseMemoryLimit(mem_str) catch null;
            }
            limits.pids_max = profile.resources.pids_max;
            try cgm.applyLimits(limits);
        }

        self.cgroup_manager = cgm;
        log.debug("Cgroup created: {s}", .{cgm.cgroup_path});
    }

    /// Set up the broker for syscall mediation
    pub fn setupBroker(self: *Container) !void {
        if (self.profile) |profile| {
            // Use annotation timeout override if set, otherwise profile default
            const timeout = self.broker_timeout_override orelse profile.broker.timeout_ms;

            self.broker_instance = broker.Broker.init(self.allocator, .{
                .max_inflight = profile.broker.max_inflight,
                .timeout_ms = timeout,
            });

            if (self.broker_timeout_override) |override| {
                log.debug("Broker initialized with annotation timeout: {d}ms", .{override});
            } else {
                log.debug("Broker initialized with profile timeout: {d}ms", .{timeout});
            }
        }
    }

    /// Save state to disk
    pub fn saveState(self: *Container) !void {
        // Ensure state directory exists
        std.fs.makeDirAbsolute(STATE_DIR) catch |err| {
            if (err != error.PathAlreadyExists) {
                log.warn("Cannot create state dir: {any}", .{err});
                return;
            }
        };

        var path_buf: [256]u8 = undefined;
        const state_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ STATE_DIR, self.id }) catch return;

        const file = std.fs.createFileAbsolute(state_path, .{}) catch |err| {
            log.warn("Cannot create state file: {any}", .{err});
            return;
        };
        defer file.close();

        var buf: [1024]u8 = undefined;
        const json = std.fmt.bufPrint(&buf,
            \\{{
            \\  "ociVersion": "1.0.2",
            \\  "id": "{s}",
            \\  "status": "{s}",
            \\  "pid": {?},
            \\  "bundle": "{s}"
            \\}}
        , .{
            self.id,
            self.status.string(),
            self.pid,
            self.bundle,
        }) catch return;

        file.writeAll(json) catch {};
        log.debug("State saved to {s}", .{state_path});
    }

    /// Load state from disk
    pub fn loadState(allocator: std.mem.Allocator, id: []const u8) !Container {
        var path_buf: [256]u8 = undefined;
        const state_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ STATE_DIR, id }) catch {
            return errors.Error.ContainerNotFound;
        };

        const file = std.fs.openFileAbsolute(state_path, .{}) catch {
            return errors.Error.ContainerNotFound;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 64 * 1024) catch {
            return errors.Error.ContainerNotFound;
        };
        defer allocator.free(content);

        // TODO: Parse state JSON properly
        // For now, just verify content exists and return placeholder
        if (content.len == 0) {
            return errors.Error.ContainerNotFound;
        }
        return Container.init(allocator, id, "/unknown");
    }

    /// Delete state from disk
    pub fn deleteState(self: *Container) void {
        var path_buf: [256]u8 = undefined;
        const state_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ STATE_DIR, self.id }) catch return;
        std.fs.deleteFileAbsolute(state_path) catch {};
    }
};

/// Create a new container
pub fn create(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse arguments: create [--console-socket <path>] [--bundle <path>] [--pid-file <path>] <container-id>
    var container_id: ?[]const u8 = null;
    var bundle_path: []const u8 = ".";
    var console_socket: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--console-socket") or std.mem.eql(u8, args[i], "-c")) {
            if (i + 1 < args.len) {
                console_socket = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--bundle") or std.mem.eql(u8, args[i], "-b")) {
            if (i + 1 < args.len) {
                bundle_path = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--pid-file")) {
            // Skip pid-file for now
            if (i + 1 < args.len) i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "-")) {
            container_id = args[i];
        }
    }

    if (container_id == null) {
        log.err("Usage: zigviz create [--console-socket <path>] [--bundle <path>] <container-id>", .{});
        return errors.Error.InvalidContainerId;
    }

    log.info("Creating container: {s} from bundle: {s}", .{ container_id.?, bundle_path });

    // Initialize container
    var container = try Container.init(allocator, container_id.?, bundle_path);
    errdefer container.deinit();

    // Store console socket path for later use
    container.console_socket = console_socket;

    // Load OCI config.json
    try container.loadConfig();

    // Load ZigViz profile (from bundle or default)
    try container.loadProfile(null);

    // Set up cgroups
    try container.setupCgroups();

    // Set up broker
    try container.setupBroker();

    // Update status
    container.status = .created;
    try container.saveState();

    log.info("Container {s} created successfully", .{container_id.?});
}

/// Start a created container
pub fn start(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("Usage: zigviz start <container-id>", .{});
        return errors.Error.InvalidContainerId;
    }

    const container_id = args[0];
    log.info("Starting container: {s}", .{container_id});

    // Load existing container state
    var container = Container.loadState(allocator, container_id) catch {
        log.err("Container not found: {s}", .{container_id});
        return errors.Error.ContainerNotFound;
    };
    defer container.deinit();

    if (container.status != .created) {
        log.err("Container not in created state", .{});
        return errors.Error.ContainerNotRunning;
    }

    // Build rootfs path
    var rootfs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rootfs = std.fmt.bufPrint(&rootfs_buf, "{s}/rootfs", .{container.bundle}) catch {
        return errors.Error.InvalidBundlePath;
    };

    // Get process config from container or use defaults
    const process_args: []const []const u8 = if (container.config) |cfg| blk: {
        if (cfg.process) |proc| break :blk proc.args;
        break :blk &.{"/bin/sh"};
    } else &.{"/bin/sh"};

    const cwd = if (container.config) |cfg| blk: {
        if (cfg.process) |proc| break :blk proc.cwd;
        break :blk "/";
    } else "/";

    const terminal = if (container.config) |cfg| blk: {
        if (cfg.process) |proc| break :blk proc.terminal;
        break :blk false;
    } else false;

    // Build seccomp policy from profile
    var seccomp_policy: ?seccomp.SyscallPolicy = null;
    if (container.profile) |profile| {
        seccomp_policy = seccomp.SyscallPolicy{
            .allow = profile.syscalls.allow,
            .deny = profile.syscalls.deny,
            .broker = profile.syscalls.broker,
        };
    }

    // Get cgroup path
    var cgroup_path: ?[]const u8 = null;
    if (container.cgroup_manager) |cgm| {
        cgroup_path = cgm.cgroup_path;
    }

    // Build executor config
    const exec_config = executor.ExecConfig{
        .container_id = container_id,
        .rootfs = rootfs,
        .args = process_args,
        .cwd = cwd,
        .terminal = terminal,
        .console_socket = container.console_socket,
        .seccomp_policy = seccomp_policy,
        .cgroup_path = cgroup_path,
        .hostname = container.config.?.hostname,
    };

    // Create and run executor
    var container_executor = executor.Executor.init(allocator, exec_config);
    defer container_executor.deinit();

    // Update container status before starting
    container.status = .running;

    // Fork and execute the container process
    const exit_code = container_executor.run() catch |err| {
        log.err("Container execution failed: {s}", .{@errorName(err)});
        container.status = .stopped;
        try container.saveState();
        return err;
    };

    // Record PID
    container.pid = container_executor.child_pid;
    try container.saveState();

    log.info("Container {s} started (pid: {?}, exit_code: {d})", .{ container_id, container.pid, exit_code });

    // Update to stopped after process exits
    container.status = .stopped;
    try container.saveState();
}

/// Send a signal to a container
pub fn kill(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("Usage: zigviz kill <container-id> [signal]", .{});
        return errors.Error.InvalidContainerId;
    }

    const container_id = args[0];
    const signal_str = if (args.len > 1) args[1] else "SIGTERM";
    log.info("Killing container: {s} with signal: {s}", .{ container_id, signal_str });

    // Load container state
    var container = Container.loadState(allocator, container_id) catch {
        log.err("Container not found: {s}", .{container_id});
        return errors.Error.ContainerNotFound;
    };
    defer container.deinit();

    if (container.pid) |pid| {
        // Parse signal
        const signal: i32 = parseSignal(signal_str);

        // Send signal
        const result = std.os.linux.kill(pid, signal);
        if (result != 0) {
            log.warn("Failed to send signal to pid {d}", .{pid});
        }

        container.status = .stopped;
        try container.saveState();
        log.info("Signal sent to container {s}", .{container_id});
    } else {
        log.warn("Container has no PID", .{});
    }
}

/// Delete a stopped container
pub fn delete(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("Usage: zigviz delete <container-id>", .{});
        return errors.Error.InvalidContainerId;
    }

    const container_id = args[0];
    log.info("Deleting container: {s}", .{container_id});

    // Load container state
    var container = Container.loadState(allocator, container_id) catch {
        log.err("Container not found: {s}", .{container_id});
        return errors.Error.ContainerNotFound;
    };
    defer container.deinit();

    if (container.status == .running) {
        log.err("Cannot delete running container", .{});
        return errors.Error.ContainerAlreadyRunning;
    }

    // Clean up cgroup
    if (container.cgroup_manager) |*cgm| {
        try cgm.destroy();
    }

    // Remove state file
    container.deleteState();

    log.info("Container {s} deleted", .{container_id});
}

/// Query container state
pub fn state(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        log.err("Usage: zigviz state <container-id>", .{});
        return errors.Error.InvalidContainerId;
    }

    const container_id = args[0];

    // Try to load actual state
    var container = Container.loadState(allocator, container_id) catch {
        // Return stub if not found
        const stdout = std.fs.File.stdout();
        var buf: [1024]u8 = undefined;

        const json = std.fmt.bufPrint(&buf,
            \\{{
            \\  "ociVersion": "1.0.2",
            \\  "id": "{s}",
            \\  "status": "stopped",
            \\  "bundle": "/unknown"
            \\}}
            \\
        , .{container_id}) catch {
            log.err("Failed to format state", .{});
            return errors.Error.SystemError;
        };

        try stdout.writeAll(json);
        return;
    };
    defer container.deinit();

    const stdout = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;

    const json = std.fmt.bufPrint(&buf,
        \\{{
        \\  "ociVersion": "1.0.2",
        \\  "id": "{s}",
        \\  "status": "{s}",
        \\  "pid": {?},
        \\  "bundle": "{s}"
        \\}}
        \\
    , .{
        container.id,
        container.status.string(),
        container.pid,
        container.bundle,
    }) catch {
        log.err("Failed to format state", .{});
        return errors.Error.SystemError;
    };

    try stdout.writeAll(json);
}

/// Parse signal name to number
fn parseSignal(name: []const u8) i32 {
    const signals = .{
        .{ "SIGHUP", 1 },
        .{ "SIGINT", 2 },
        .{ "SIGQUIT", 3 },
        .{ "SIGKILL", 9 },
        .{ "SIGTERM", 15 },
        .{ "SIGUSR1", 10 },
        .{ "SIGUSR2", 12 },
    };

    inline for (signals) |sig| {
        if (std.mem.eql(u8, name, sig[0])) {
            return sig[1];
        }
    }

    // Try parsing as number
    return std.fmt.parseInt(i32, name, 10) catch 15; // Default to SIGTERM
}

/// Run a container (create + start in one step)
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        log.err("Usage: zigviz run <container-id> <bundle>", .{});
        return errors.Error.InvalidBundlePath;
    }

    // First create
    try create(allocator, args);

    // Then start
    try start(allocator, args[0..1]);
}

/// List all containers
pub fn list(allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();

    // Header
    try stdout.writeAll("CONTAINER ID\tSTATUS\t\tPID\t\tBUNDLE\n");

    // List state files
    var dir = std.fs.openDirAbsolute(STATE_DIR, .{ .iterate = true }) catch {
        // No containers
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        // Extract container ID from filename
        const id = entry.name[0 .. entry.name.len - 5]; // Remove .json

        // Try to load and display state
        var container = Container.loadState(allocator, id) catch continue;
        defer container.deinit();

        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}\t{s}\t\t{?}\t\t{s}\n", .{
            container.id,
            container.status.string(),
            container.pid,
            container.bundle,
        }) catch continue;

        stdout.writeAll(line) catch {};
    }
}

/// Execute a command in a running container
pub fn exec(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        log.err("Usage: zigviz exec <container-id> <command> [args...]", .{});
        return errors.Error.InvalidContainerId;
    }

    const container_id = args[0];
    const cmd_args = args[1..];

    log.info("Executing in container: {s}", .{container_id});

    // Load container state
    var container = Container.loadState(allocator, container_id) catch {
        log.err("Container not found: {s}", .{container_id});
        return errors.Error.ContainerNotFound;
    };
    defer container.deinit();

    if (container.status != .running) {
        log.err("Container is not running", .{});
        return errors.Error.ContainerNotRunning;
    }

    const pid = container.pid orelse {
        log.err("Container has no PID", .{});
        return errors.Error.ContainerNotRunning;
    };

    // Enter container namespaces and execute
    try execInContainer(allocator, pid, cmd_args);
}

/// Enter container namespaces and execute a command
fn execInContainer(allocator: std.mem.Allocator, container_pid: i32, cmd_args: []const []const u8) !void {
    // Fork to execute in container
    const fork_result = std.os.linux.fork();
    const fork_signed: isize = @bitCast(fork_result);

    if (fork_signed < 0) {
        return errors.Error.SystemError;
    }

    if (fork_signed == 0) {
        // Child process - enter namespaces and exec
        enterNamespacesAndExec(allocator, container_pid, cmd_args) catch |err| {
            log.err("Failed to exec in container: {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        unreachable;
    }

    // Parent - wait for child
    var status: u32 = 0;
    while (true) {
        const result = std.os.linux.waitpid(@intCast(fork_signed), &status, 0);
        const signed: isize = @bitCast(result);
        if (signed < 0) {
            const errno = std.posix.errno(@as(isize, @bitCast(result)));
            if (errno == .INTR) continue;
            return errors.Error.SystemError;
        }
        break;
    }

    if (std.os.linux.W.IFEXITED(status)) {
        const exit_code = std.os.linux.W.EXITSTATUS(status);
        if (exit_code != 0) {
            log.warn("Exec process exited with code {d}", .{exit_code});
        }
    }
}

/// Enter namespaces of a container process and execute command
fn enterNamespacesAndExec(allocator: std.mem.Allocator, container_pid: i32, cmd_args: []const []const u8) !void {
    // Namespace types to enter
    const ns_types = [_]struct { name: []const u8, flag: u32 }{
        .{ .name = "mnt", .flag = 0x00020000 }, // CLONE_NEWNS
        .{ .name = "uts", .flag = 0x04000000 }, // CLONE_NEWUTS
        .{ .name = "ipc", .flag = 0x08000000 }, // CLONE_NEWIPC
        .{ .name = "pid", .flag = 0x20000000 }, // CLONE_NEWPID
        .{ .name = "net", .flag = 0x40000000 }, // CLONE_NEWNET
    };

    var path_buf: [64:0]u8 = undefined;

    // Enter each namespace
    for (ns_types) |ns| {
        const ns_path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/ns/{s}", .{ container_pid, ns.name }) catch continue;

        const fd = std.os.linux.open(ns_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (@as(isize, @bitCast(fd)) < 0) {
            log.debug("Cannot open namespace {s}", .{ns.name});
            continue;
        }

        // setns syscall
        const result = std.os.linux.syscall2(.setns, fd, ns.flag);
        _ = std.os.linux.close(@intCast(fd));

        if (@as(isize, @bitCast(result)) < 0) {
            log.debug("Cannot enter namespace {s}", .{ns.name});
        } else {
            log.debug("Entered namespace: {s}", .{ns.name});
        }
    }

    // Change to container's root
    const root_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/root", .{container_pid}) catch {
        return errors.Error.SystemError;
    };

    std.posix.chdir(root_path) catch {
        log.warn("Cannot chdir to container root", .{});
    };

    // Execute the command
    if (cmd_args.len == 0) {
        return errors.Error.InvalidSyscallArgs;
    }

    const argv = try allocator.allocSentinel(?[*:0]const u8, cmd_args.len, null);
    defer allocator.free(argv);

    for (cmd_args, 0..) |arg, i| {
        argv[i] = try allocator.dupeZ(u8, arg);
    }

    // Default environment
    const default_env = [_][*:0]const u8{
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TERM=xterm",
    };
    const envp = try allocator.allocSentinel(?[*:0]const u8, default_env.len, null);
    defer allocator.free(envp);
    for (default_env, 0..) |env, i| {
        envp[i] = env;
    }

    log.debug("Executing: {s}", .{cmd_args[0]});
    std.posix.execvpeZ(argv[0].?, argv, envp) catch {
        std.process.exit(127);
    };
    unreachable;
}

/// Generate a default OCI spec (config.json)
pub fn spec(args: []const []const u8) !void {
    const stdout = std.fs.File.stdout();

    // Check for output flag
    var output_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") or std.mem.eql(u8, args[i], "--output")) {
            if (i + 1 < args.len) {
                output_path = args[i + 1];
                i += 1;
            }
        }
    }

    const spec_json =
        \\{
        \\  "ociVersion": "1.0.2",
        \\  "process": {
        \\    "terminal": true,
        \\    "user": { "uid": 0, "gid": 0 },
        \\    "args": ["sh"],
        \\    "env": [
        \\      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        \\      "TERM=xterm"
        \\    ],
        \\    "cwd": "/"
        \\  },
        \\  "root": {
        \\    "path": "rootfs",
        \\    "readonly": true
        \\  },
        \\  "hostname": "zigviz-container",
        \\  "mounts": [
        \\    { "destination": "/proc", "type": "proc", "source": "proc" },
        \\    { "destination": "/dev", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid", "strictatime", "mode=755", "size=65536k"] },
        \\    { "destination": "/sys", "type": "sysfs", "source": "sysfs", "options": ["nosuid", "noexec", "nodev", "ro"] }
        \\  ],
        \\  "linux": {
        \\    "namespaces": [
        \\      { "type": "pid" },
        \\      { "type": "mount" },
        \\      { "type": "ipc" },
        \\      { "type": "uts" },
        \\      { "type": "network" }
        \\    ],
        \\    "resources": {
        \\      "memory": { "limit": 536870912 },
        \\      "pids": { "limit": 100 }
        \\    }
        \\  }
        \\}
        \\
    ;

    if (output_path) |path| {
        const file = std.fs.createFileAbsolute(path, .{}) catch |err| {
            log.err("Cannot create file: {s}: {any}", .{ path, err });
            return errors.Error.SystemError;
        };
        defer file.close();
        try file.writeAll(spec_json);
        log.info("Wrote OCI spec to {s}", .{path});
    } else {
        try stdout.writeAll(spec_json);
    }
}

test "state struct" {
    const s = State{
        .id = "test-container",
        .status = .running,
        .pid = 1234,
        .bundle = "/var/run/containers/test",
    };

    try std.testing.expectEqualStrings("test-container", s.id);
    try std.testing.expectEqual(State.Status.running, s.status);
    try std.testing.expectEqual(@as(?i32, 1234), s.pid);
}

test "container init and deinit" {
    var container = try Container.init(std.testing.allocator, "test-id", "/tmp/bundle");
    defer container.deinit();

    try std.testing.expectEqualStrings("test-id", container.id);
    try std.testing.expectEqualStrings("/tmp/bundle", container.bundle);
    try std.testing.expectEqual(State.Status.creating, container.status);
    try std.testing.expect(container.pid == null);
}

test "state status string" {
    try std.testing.expectEqualStrings("creating", State.Status.creating.string());
    try std.testing.expectEqualStrings("created", State.Status.created.string());
    try std.testing.expectEqualStrings("running", State.Status.running.string());
    try std.testing.expectEqualStrings("stopped", State.Status.stopped.string());
}

test "parse signal" {
    try std.testing.expectEqual(@as(i32, 9), parseSignal("SIGKILL"));
    try std.testing.expectEqual(@as(i32, 15), parseSignal("SIGTERM"));
    try std.testing.expectEqual(@as(i32, 2), parseSignal("SIGINT"));
    try std.testing.expectEqual(@as(i32, 1), parseSignal("SIGHUP"));
    // Numeric parsing
    try std.testing.expectEqual(@as(i32, 42), parseSignal("42"));
    // Default fallback
    try std.testing.expectEqual(@as(i32, 15), parseSignal("INVALID"));
}

test "config struct" {
    const config = Config{
        .oci_version = "1.0.2",
        .root = .{ .path = "/rootfs" },
    };

    try std.testing.expectEqualStrings("1.0.2", config.oci_version);
    try std.testing.expectEqualStrings("/rootfs", config.root.path);
    try std.testing.expect(!config.root.readonly);
    try std.testing.expect(config.process == null);
    try std.testing.expect(config.hostname == null);
}

test "extractAnnotationValue" {
    const json =
        \\{
        \\  "annotations": {
        \\    "zigviz.io/profile": "ci-runner",
        \\    "zigviz.io/audit": "true",
        \\    "zigviz.io/broker-timeout": "200"
        \\  }
        \\}
    ;

    // Test profile extraction
    const profile = extractAnnotationValue(json, Annotations.PROFILE);
    try std.testing.expect(profile != null);
    try std.testing.expectEqualStrings("ci-runner", profile.?);

    // Test audit extraction
    const audit = extractAnnotationValue(json, Annotations.AUDIT);
    try std.testing.expect(audit != null);
    try std.testing.expectEqualStrings("true", audit.?);

    // Test timeout extraction
    const timeout = extractAnnotationValue(json, Annotations.BROKER_TIMEOUT);
    try std.testing.expect(timeout != null);
    try std.testing.expectEqualStrings("200", timeout.?);

    // Test non-existent key
    const missing = extractAnnotationValue(json, "zigviz.io/nonexistent");
    try std.testing.expect(missing == null);
}

test "container builtin profile loading" {
    var container = try Container.init(std.testing.allocator, "test-id", "/tmp/bundle");
    defer container.deinit();

    // Test ci-runner profile
    const ci = container.loadBuiltinProfile("ci-runner");
    try std.testing.expect(ci != null);
    try std.testing.expectEqualStrings("zigviz-ci", ci.?.name);

    // Test hostile-tenant profile
    const hostile = container.loadBuiltinProfile("hostile-tenant");
    try std.testing.expect(hostile != null);
    try std.testing.expectEqualStrings("zigviz-hostile", hostile.?.name);

    // Test minimal profile
    const minimal = container.loadBuiltinProfile("minimal");
    try std.testing.expect(minimal != null);
    try std.testing.expectEqualStrings("zigviz-minimal", minimal.?.name);

    // Test unknown profile
    const unknown = container.loadBuiltinProfile("unknown-profile");
    try std.testing.expect(unknown == null);
}
