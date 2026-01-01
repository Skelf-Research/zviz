const std = @import("std");
const log = @import("log.zig");
const metrics = @import("metrics.zig");

/// Simple HTTP server for Prometheus metrics endpoint
/// Exposes metrics at /metrics in Prometheus text format

pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    server: ?std.net.Server = null,
    running: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !MetricsServer {
        const address = try std.net.Address.parseIp4(host, port);
        return .{
            .allocator = allocator,
            .address = address,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *MetricsServer) !void {
        if (self.running.load(.acquire)) {
            return;
        }

        self.server = try self.address.listen(.{
            .reuse_address = true,
        });

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});

        log.info("Metrics server started on {any}", .{self.address});
    }

    pub fn stop(self: *MetricsServer) void {
        self.running.store(false, .release);

        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        log.info("Metrics server stopped", .{});
    }

    fn serverLoop(self: *MetricsServer) void {
        while (self.running.load(.acquire)) {
            if (self.server) |*server| {
                const conn = server.accept() catch |err| {
                    if (err == error.ConnectionAborted) continue;
                    if (!self.running.load(.acquire)) break;
                    log.warn("Accept error: {s}", .{@errorName(err)});
                    continue;
                };

                self.handleConnection(conn) catch |err| {
                    log.debug("Connection error: {s}", .{@errorName(err)});
                };
            }
        }
    }

    fn handleConnection(self: *MetricsServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        // Read request (simple HTTP parsing)
        var buf: [4096]u8 = undefined;
        const n = conn.stream.read(&buf) catch return;
        if (n == 0) return;

        const request = buf[0..n];

        // Check if it's a GET /metrics request
        if (std.mem.startsWith(u8, request, "GET /metrics")) {
            try self.sendMetrics(conn.stream);
        } else if (std.mem.startsWith(u8, request, "GET /health")) {
            try self.sendHealth(conn.stream);
        } else if (std.mem.startsWith(u8, request, "GET /")) {
            try self.sendIndex(conn.stream);
        } else {
            try self.send404(conn.stream);
        }
    }

    fn sendMetrics(self: *MetricsServer, stream: std.net.Stream) !void {
        const runtime_metrics = metrics.get() orelse {
            try self.send500(stream);
            return;
        };

        const body = runtime_metrics.exportPrometheus(self.allocator) catch {
            try self.send500(stream);
            return;
        };
        defer self.allocator.free(body);

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n", .{body.len}) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(body) catch return;
    }

    fn sendHealth(_: *MetricsServer, stream: std.net.Stream) !void {
        const response =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 15\r\n" ++
            "\r\n" ++
            "{\"status\":\"ok\"}";
        _ = stream.write(response) catch return;
    }

    fn sendIndex(_: *MetricsServer, stream: std.net.Stream) !void {
        const body =
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>ZigViz Metrics</title></head>
            \\<body>
            \\<h1>ZigViz Metrics Server</h1>
            \\<ul>
            \\<li><a href="/metrics">/metrics</a> - Prometheus metrics</li>
            \\<li><a href="/health">/health</a> - Health check</li>
            \\</ul>
            \\</body>
            \\</html>
        ;

        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/html\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n", .{body.len}) catch return;

        _ = stream.write(header) catch return;
        _ = stream.write(body) catch return;
    }

    fn send404(_: *MetricsServer, stream: std.net.Stream) !void {
        const response =
            "HTTP/1.1 404 Not Found\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 9\r\n" ++
            "\r\n" ++
            "Not Found";
        _ = stream.write(response) catch return;
    }

    fn send500(_: *MetricsServer, stream: std.net.Stream) !void {
        const response =
            "HTTP/1.1 500 Internal Server Error\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 21\r\n" ++
            "\r\n" ++
            "Internal Server Error";
        _ = stream.write(response) catch return;
    }
};

/// Start metrics server in background
pub fn startMetricsServer(allocator: std.mem.Allocator, host: []const u8, port: u16) !*MetricsServer {
    // Initialize global metrics if not already done
    if (metrics.get() == null) {
        try metrics.initGlobal(allocator);
    }

    const server = try allocator.create(MetricsServer);
    server.* = try MetricsServer.init(allocator, host, port);
    try server.start();
    return server;
}

/// Stop and cleanup metrics server
pub fn stopMetricsServer(allocator: std.mem.Allocator, server: *MetricsServer) void {
    server.stop();
    allocator.destroy(server);
}

// ============================================================================
// Tests
// ============================================================================

test "metrics server init" {
    const server = try MetricsServer.init(std.testing.allocator, "127.0.0.1", 9999);
    _ = server;
}
