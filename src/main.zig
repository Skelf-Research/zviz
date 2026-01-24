const std = @import("std");
const builtin = @import("builtin");

// Core modules
pub const log = @import("log.zig");
pub const errors = @import("errors.zig");

// Enforcement layers
pub const broker = @import("broker/broker.zig");
pub const containment = @import("containment/containment.zig");
pub const seccomp = @import("seccomp/seccomp.zig");
pub const lsm = @import("lsm/lsm.zig");
pub const cgroup = @import("cgroup/cgroup.zig");
pub const network = @import("network/network.zig");

// Policy system
pub const compiler = @import("compiler/compiler.zig");
pub const schema = @import("schema/schema.zig");

// Runtime
pub const runtime = @import("runtime.zig");

// Executor
pub const executor = @import("executor/mod.zig");

// Testing and validation
pub const testing = @import("testing/testing.zig");

// Metrics
pub const metrics = @import("metrics.zig");
pub const metrics_server = @import("metrics_server.zig");

// Configuration
pub const config = @import("config.zig");

const version = "0.1.0";

pub fn main() void {
    run() catch |err| {
        handleError(err);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (@import("builtin").mode == .Debug) {
            _ = gpa.deinit();
        }
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    // Parse global options before the command
    var arg_index: usize = 1;
    var custom_root: ?[]const u8 = null;

    while (arg_index < args.len) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--root")) {
            if (arg_index + 1 < args.len) {
                custom_root = args[arg_index + 1];
                arg_index += 2;
            } else {
                log.err("--root requires a path argument", .{});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            custom_root = arg[7..];
            arg_index += 1;
        } else {
            // First non-option is the command
            break;
        }
    }

    // Set up state directory
    if (custom_root) |root| {
        runtime.setStateDir(root);
        log.debug("Using custom state directory: {s}", .{root});
    } else {
        // Auto-detect rootless mode and set appropriate state directory
        const uid = std.os.linux.getuid();
        if (uid != 0) {
            // Running as non-root, use rootless state directory
            const rootless_dir = try runtime.getRootlessStateDir(allocator);
            runtime.setStateDir(rootless_dir);
            log.debug("Running in rootless mode, state directory: {s}", .{rootless_dir});
        }
    }

    if (arg_index >= args.len) {
        try printUsage();
        return;
    }

    const command = args[arg_index];
    const cmd_args = args[arg_index + 1 ..];

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try printVersion();
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try printUsage();
    } else if (std.mem.eql(u8, command, "create")) {
        try runtime.create(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "start")) {
        try runtime.start(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "kill")) {
        try runtime.kill(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "delete")) {
        try runtime.delete(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "state")) {
        try runtime.state(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "run")) {
        try runtime.run(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "ps")) {
        try runtime.list(allocator);
    } else if (std.mem.eql(u8, command, "exec")) {
        try runtime.exec(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "spec")) {
        try runtime.spec(cmd_args);
    } else if (std.mem.eql(u8, command, "compile")) {
        try compiler.compileProfile(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "audit")) {
        try runSecurityAudit(allocator);
    } else if (std.mem.eql(u8, command, "validate")) {
        try testing.runAll(allocator);
        log.info("All validation tests passed", .{});
    } else if (std.mem.eql(u8, command, "escape-test")) {
        const passed = try testing.runEscapeTests(allocator);
        if (!passed) {
            log.err("SECURITY FAILURE: Some escape tests succeeded!", .{});
            std.process.exit(1);
        }
    } else if (std.mem.eql(u8, command, "benchmark")) {
        try runBenchmarks(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "compare") or std.mem.eql(u8, command, "compare-gvisor")) {
        try testing.comparison.runFullComparison(allocator);
    } else if (std.mem.eql(u8, command, "metrics")) {
        try handleMetrics(allocator, cmd_args);
    } else if (std.mem.eql(u8, command, "config")) {
        try showConfig(allocator, cmd_args);
    } else {
        log.err("Unknown command: {s}", .{command});
        try printUsage();
        std.process.exit(errors.ExitCode.COMMAND_NOT_FOUND);
    }
}

fn handleError(err: anyerror) void {
    log.err("Error: {s}", .{@errorName(err)});
    std.process.exit(errors.ExitCode.GENERAL_ERROR);
}

fn showConfig(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.fs.File.stdout();

    if (args.len > 0 and std.mem.eql(u8, args[0], "--generate")) {
        // Generate default config
        try stdout.writeAll(config.generateDefault());
        return;
    }

    // Load and display current config
    const cfg = try config.load(allocator);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();

    try writer.writeAll("Current ZViz Configuration:\n\n");
    try writer.print("Runtime:\n", .{});
    try writer.print("  state_dir: {s}\n", .{cfg.runtime.state_dir});
    try writer.print("  rootless: {}\n", .{cfg.runtime.rootless});
    try writer.print("  operation_timeout_ms: {d}\n", .{cfg.runtime.operation_timeout_ms});
    try writer.print("\nLogging:\n", .{});
    try writer.print("  level: {s}\n", .{@tagName(cfg.logging.level)});
    try writer.print("  format: {s}\n", .{@tagName(cfg.logging.format)});
    try writer.print("\nBroker:\n", .{});
    try writer.print("  max_inflight: {d}\n", .{cfg.broker.max_inflight});
    try writer.print("  timeout_ms: {d}\n", .{cfg.broker.timeout_ms});
    try writer.print("\nResources:\n", .{});
    if (cfg.resources.memory_max) |mem| {
        try writer.print("  memory_max: {s}\n", .{mem});
    }
    if (cfg.resources.pids_max) |pids| {
        try writer.print("  pids_max: {d}\n", .{pids});
    }
    try writer.print("\nSecurity:\n", .{});
    try writer.print("  require_seccomp: {}\n", .{cfg.security.require_seccomp});
    try writer.print("  no_new_privs: {}\n", .{cfg.security.no_new_privs});
    try writer.print("  readonly_rootfs: {}\n", .{cfg.security.readonly_rootfs});

    try stdout.writeAll(buf[0..stream.pos]);
}

fn handleMetrics(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse arguments
    var serve_mode = false;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 9090;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "serve")) {
            serve_mode = true;
        } else if (std.mem.eql(u8, args[i], "--addr") or std.mem.eql(u8, args[i], "-a")) {
            if (i + 1 < args.len) {
                // Parse host:port
                const addr_str = args[i + 1];
                if (std.mem.indexOf(u8, addr_str, ":")) |colon_pos| {
                    host = addr_str[0..colon_pos];
                    port = std.fmt.parseInt(u16, addr_str[colon_pos + 1 ..], 10) catch 9090;
                } else {
                    host = addr_str;
                }
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], "--port") or std.mem.eql(u8, args[i], "-p")) {
            if (i + 1 < args.len) {
                port = std.fmt.parseInt(u16, args[i + 1], 10) catch 9090;
                i += 1;
            }
        }
    }

    if (serve_mode) {
        // Start metrics server
        log.info("Starting metrics server on {s}:{d}", .{ host, port });

        const server = try metrics_server.startMetricsServer(allocator, host, port);
        defer metrics_server.stopMetricsServer(allocator, server);

        // Wait for signal (simplified - just sleep indefinitely)
        log.info("Metrics available at http://{s}:{d}/metrics", .{ host, port });
        log.info("Health check at http://{s}:{d}/health", .{ host, port });
        log.info("Press Ctrl+C to stop", .{});

        // Block forever (until signal)
        while (true) {
            std.Thread.sleep(std.time.ns_per_s);
        }
    } else {
        // Export mode - print to stdout
        var m = try metrics.RuntimeMetrics.init(allocator);
        defer m.deinit();

        const output = try m.exportPrometheus(allocator);
        defer allocator.free(output);

        const stdout = std.fs.File.stdout();
        try stdout.writeAll(output);
    }
}

fn runBenchmarks(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var iterations: u64 = 10000;

    // Parse arguments
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--iterations=")) {
            const val = arg[13..];
            iterations = std.fmt.parseInt(u64, val, 10) catch 10000;
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            // Short form: -n1000
            if (arg.len > 2) {
                iterations = std.fmt.parseInt(u64, arg[2..], 10) catch 10000;
            }
        }
    }

    var suite = try testing.benchmark.runFullBenchmarkSuite(allocator, iterations);
    defer suite.deinit();

    suite.printAll();
}

fn runSecurityAudit(allocator: std.mem.Allocator) !void {
    log.info("Running security audit with default profile...", .{});

    // Get default profile
    const profile = schema.defaultCiRunner();

    // Build seccomp policy
    const seccomp_policy = seccomp.SyscallPolicy{
        .allow = profile.syscalls.allow,
        .deny = profile.syscalls.deny,
        .broker = profile.syscalls.broker,
    };

    // Build namespace config
    const ns_config = containment.Config{
        .namespaces = &.{ .user, .pid, .mount, .network, .ipc },
        .capabilities_keep = &.{},
        .rootfs_readonly = true,
        .no_new_privileges = true,
    };

    // Build resource limits
    var limits = cgroup.Limits{};
    if (profile.resources.memory_max) |mem_str| {
        limits.memory_max = cgroup.parseMemoryLimit(mem_str) catch null;
    }
    limits.pids_max = profile.resources.pids_max;

    // Run full audit
    try testing.security.runFullAudit(allocator, seccomp_policy, ns_config, limits);
}

fn printVersion() !void {
    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg1 = std.fmt.bufPrint(&buf, "zviz version {s}\n", .{version}) catch "zviz\n";
    try stdout.writeAll(msg1);
    const msg2 = std.fmt.bufPrint(&buf, "zig version {s}\n", .{builtin.zig_version_string}) catch "zig\n";
    try stdout.writeAll(msg2);
}

fn printUsage() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(
        \\ZViz - Zig-based container isolation runtime
        \\
        \\Usage: zviz <command> [options]
        \\
        \\OCI Runtime Commands:
        \\  create <container-id> <bundle>   Create a container
        \\  start <container-id>             Start a container
        \\  run <container-id> <bundle>      Create and start a container
        \\  exec <container-id> <cmd...>     Execute command in container
        \\  kill <container-id> [signal]     Send signal to container
        \\  delete <container-id>            Delete a container
        \\  state <container-id>             Query container state
        \\  list (ps)                        List containers
        \\  spec [-o config.json]            Generate OCI spec
        \\
        \\Policy Commands:
        \\  compile <profile.yaml>           Compile a policy profile
        \\
        \\Validation Commands:
        \\  audit                            Run security audit
        \\  validate                         Run all validation tests
        \\  escape-test                      Run escape-class security tests
        \\  benchmark [-n<N>]                Run performance benchmarks
        \\  compare                          Compare policies with gVisor
        \\
        \\Monitoring:
        \\  metrics                          Export Prometheus metrics to stdout
        \\  metrics serve [-a host:port]     Start metrics HTTP server (default: 127.0.0.1:9090)
        \\  config [--generate]              Show/generate configuration
        \\
        \\Other:
        \\  version                          Print version info
        \\  help                             Show this help
        \\
        \\See docs/roadmap.md for implementation status.
        \\
    );
}

test {
    // Import all modules for testing
    std.testing.refAllDecls(@This());
}
