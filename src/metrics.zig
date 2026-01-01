const std = @import("std");
const log = @import("log.zig");

/// Metrics collection for ZigViz runtime
/// Provides Prometheus-compatible metrics export

// ============================================================================
// Counter - Monotonically increasing value
// ============================================================================

pub const Counter = struct {
    value: std.atomic.Value(u64),
    name: []const u8,
    help: []const u8,

    pub fn init(name: []const u8, help: []const u8) Counter {
        return .{
            .value = std.atomic.Value(u64).init(0),
            .name = name,
            .help = help,
        };
    }

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *const Counter) u64 {
        return self.value.load(.monotonic);
    }

    pub fn reset(self: *Counter) void {
        self.value.store(0, .monotonic);
    }
};

// ============================================================================
// Gauge - Value that can go up and down
// ============================================================================

pub const Gauge = struct {
    value: std.atomic.Value(i64),
    name: []const u8,
    help: []const u8,

    pub fn init(name: []const u8, help: []const u8) Gauge {
        return .{
            .value = std.atomic.Value(i64).init(0),
            .name = name,
            .help = help,
        };
    }

    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .monotonic);
    }

    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *const Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

// ============================================================================
// Histogram - Distribution of values
// ============================================================================

pub const Histogram = struct {
    buckets: []std.atomic.Value(u64),
    bucket_bounds: []const f64,
    sum: std.atomic.Value(u64),
    count: std.atomic.Value(u64),
    name: []const u8,
    help: []const u8,
    allocator: std.mem.Allocator,

    /// Default bucket boundaries (in microseconds for latency)
    pub const DEFAULT_BUCKETS = [_]f64{ 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, bucket_bounds: []const f64) !Histogram {
        const buckets = try allocator.alloc(std.atomic.Value(u64), bucket_bounds.len + 1);
        for (buckets) |*b| {
            b.* = std.atomic.Value(u64).init(0);
        }

        return .{
            .buckets = buckets,
            .bucket_bounds = bucket_bounds,
            .sum = std.atomic.Value(u64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .name = name,
            .help = help,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.buckets);
    }

    pub fn observe(self: *Histogram, value: f64) void {
        // Find bucket and increment
        for (self.bucket_bounds, 0..) |bound, i| {
            if (value <= bound) {
                _ = self.buckets[i].fetchAdd(1, .monotonic);
                break;
            }
        } else {
            // +Inf bucket
            _ = self.buckets[self.bucket_bounds.len].fetchAdd(1, .monotonic);
        }

        // Update sum and count
        _ = self.sum.fetchAdd(@intFromFloat(value), .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub fn getCount(self: *const Histogram) u64 {
        return self.count.load(.monotonic);
    }

    pub fn getSum(self: *const Histogram) u64 {
        return self.sum.load(.monotonic);
    }
};

// ============================================================================
// Runtime Metrics Collection
// ============================================================================

/// Global metrics for ZigViz runtime
pub const RuntimeMetrics = struct {
    // Container lifecycle
    containers_created: Counter,
    containers_started: Counter,
    containers_stopped: Counter,
    containers_deleted: Counter,
    containers_running: Gauge,

    // Syscall brokering
    syscalls_brokered: Counter,
    syscalls_allowed: Counter,
    syscalls_denied: Counter,
    broker_timeouts: Counter,
    broker_latency_us: ?Histogram,

    // Resource usage
    cgroup_memory_usage_bytes: Gauge,
    cgroup_cpu_usage_us: Counter,
    cgroup_pids_current: Gauge,

    // Errors
    errors_total: Counter,
    seccomp_violations: Counter,
    network_violations: Counter,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !RuntimeMetrics {
        return .{
            .containers_created = Counter.init("zigviz_containers_created_total", "Total containers created"),
            .containers_started = Counter.init("zigviz_containers_started_total", "Total containers started"),
            .containers_stopped = Counter.init("zigviz_containers_stopped_total", "Total containers stopped"),
            .containers_deleted = Counter.init("zigviz_containers_deleted_total", "Total containers deleted"),
            .containers_running = Gauge.init("zigviz_containers_running", "Currently running containers"),

            .syscalls_brokered = Counter.init("zigviz_syscalls_brokered_total", "Total syscalls handled by broker"),
            .syscalls_allowed = Counter.init("zigviz_syscalls_allowed_total", "Total syscalls allowed"),
            .syscalls_denied = Counter.init("zigviz_syscalls_denied_total", "Total syscalls denied"),
            .broker_timeouts = Counter.init("zigviz_broker_timeouts_total", "Total broker timeouts"),
            .broker_latency_us = try Histogram.init(
                allocator,
                "zigviz_broker_latency_microseconds",
                "Broker request latency in microseconds",
                &Histogram.DEFAULT_BUCKETS,
            ),

            .cgroup_memory_usage_bytes = Gauge.init("zigviz_cgroup_memory_usage_bytes", "Current cgroup memory usage"),
            .cgroup_cpu_usage_us = Counter.init("zigviz_cgroup_cpu_usage_microseconds_total", "Total cgroup CPU usage"),
            .cgroup_pids_current = Gauge.init("zigviz_cgroup_pids_current", "Current number of PIDs in cgroup"),

            .errors_total = Counter.init("zigviz_errors_total", "Total errors"),
            .seccomp_violations = Counter.init("zigviz_seccomp_violations_total", "Total seccomp violations"),
            .network_violations = Counter.init("zigviz_network_violations_total", "Total network policy violations"),

            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RuntimeMetrics) void {
        if (self.broker_latency_us) |*h| h.deinit();
    }

    /// Export metrics in Prometheus text format
    pub fn exportPrometheus(self: *const RuntimeMetrics, allocator: std.mem.Allocator) ![]u8 {
        // Pre-allocate a reasonably sized buffer
        const buf = try allocator.alloc(u8, 16384);
        errdefer allocator.free(buf);

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        // Containers
        try self.writeCounter(writer, &self.containers_created);
        try self.writeCounter(writer, &self.containers_started);
        try self.writeCounter(writer, &self.containers_stopped);
        try self.writeCounter(writer, &self.containers_deleted);
        try self.writeGauge(writer, &self.containers_running);

        // Syscalls
        try self.writeCounter(writer, &self.syscalls_brokered);
        try self.writeCounter(writer, &self.syscalls_allowed);
        try self.writeCounter(writer, &self.syscalls_denied);
        try self.writeCounter(writer, &self.broker_timeouts);

        // Histogram
        if (self.broker_latency_us) |*h| {
            try self.writeHistogram(writer, h);
        }

        // Resources
        try self.writeGauge(writer, &self.cgroup_memory_usage_bytes);
        try self.writeCounter(writer, &self.cgroup_cpu_usage_us);
        try self.writeGauge(writer, &self.cgroup_pids_current);

        // Errors
        try self.writeCounter(writer, &self.errors_total);
        try self.writeCounter(writer, &self.seccomp_violations);
        try self.writeCounter(writer, &self.network_violations);

        // Return only the written portion
        const written = stream.pos;
        const result = try allocator.alloc(u8, written);
        @memcpy(result, buf[0..written]);
        allocator.free(buf);
        return result;
    }

    fn writeCounter(self: *const RuntimeMetrics, writer: anytype, counter: *const Counter) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ counter.name, counter.help });
        try writer.print("# TYPE {s} counter\n", .{counter.name});
        try writer.print("{s} {d}\n\n", .{ counter.name, counter.get() });
    }

    fn writeGauge(self: *const RuntimeMetrics, writer: anytype, gauge: *const Gauge) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ gauge.name, gauge.help });
        try writer.print("# TYPE {s} gauge\n", .{gauge.name});
        try writer.print("{s} {d}\n\n", .{ gauge.name, gauge.get() });
    }

    fn writeHistogram(self: *const RuntimeMetrics, writer: anytype, histogram: *const Histogram) !void {
        _ = self;
        try writer.print("# HELP {s} {s}\n", .{ histogram.name, histogram.help });
        try writer.print("# TYPE {s} histogram\n", .{histogram.name});

        var cumulative: u64 = 0;
        for (histogram.bucket_bounds, 0..) |bound, i| {
            cumulative += histogram.buckets[i].load(.monotonic);
            try writer.print("{s}_bucket{{le=\"{d:.0}\"}} {d}\n", .{ histogram.name, bound, cumulative });
        }
        cumulative += histogram.buckets[histogram.bucket_bounds.len].load(.monotonic);
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ histogram.name, cumulative });
        try writer.print("{s}_sum {d}\n", .{ histogram.name, histogram.getSum() });
        try writer.print("{s}_count {d}\n\n", .{ histogram.name, histogram.getCount() });
    }
};

// ============================================================================
// Global Metrics Instance
// ============================================================================

var global_metrics: ?RuntimeMetrics = null;

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    global_metrics = try RuntimeMetrics.init(allocator);
}

pub fn deinitGlobal() void {
    if (global_metrics) |*m| m.deinit();
    global_metrics = null;
}

pub fn get() ?*RuntimeMetrics {
    return if (global_metrics) |*m| m else null;
}

// ============================================================================
// Convenience Functions
// ============================================================================

pub fn incContainersCreated() void {
    if (get()) |m| m.containers_created.inc();
}

pub fn incContainersStarted() void {
    if (get()) |m| {
        m.containers_started.inc();
        m.containers_running.inc();
    }
}

pub fn incContainersStopped() void {
    if (get()) |m| {
        m.containers_stopped.inc();
        m.containers_running.dec();
    }
}

pub fn incSyscallBrokered(latency_us: u64) void {
    if (get()) |m| {
        m.syscalls_brokered.inc();
        if (m.broker_latency_us) |*h| {
            h.observe(@floatFromInt(latency_us));
        }
    }
}

pub fn incSyscallAllowed() void {
    if (get()) |m| m.syscalls_allowed.inc();
}

pub fn incSyscallDenied() void {
    if (get()) |m| m.syscalls_denied.inc();
}

pub fn incError() void {
    if (get()) |m| m.errors_total.inc();
}

// ============================================================================
// Tests
// ============================================================================

test "counter operations" {
    var counter = Counter.init("test_counter", "Test counter");
    try std.testing.expectEqual(@as(u64, 0), counter.get());

    counter.inc();
    try std.testing.expectEqual(@as(u64, 1), counter.get());

    counter.add(5);
    try std.testing.expectEqual(@as(u64, 6), counter.get());

    counter.reset();
    try std.testing.expectEqual(@as(u64, 0), counter.get());
}

test "gauge operations" {
    var gauge = Gauge.init("test_gauge", "Test gauge");
    try std.testing.expectEqual(@as(i64, 0), gauge.get());

    gauge.set(42);
    try std.testing.expectEqual(@as(i64, 42), gauge.get());

    gauge.inc();
    try std.testing.expectEqual(@as(i64, 43), gauge.get());

    gauge.dec();
    try std.testing.expectEqual(@as(i64, 42), gauge.get());
}

test "histogram operations" {
    var histogram = try Histogram.init(
        std.testing.allocator,
        "test_histogram",
        "Test histogram",
        &[_]f64{ 10, 50, 100 },
    );
    defer histogram.deinit();

    histogram.observe(5);
    histogram.observe(25);
    histogram.observe(75);
    histogram.observe(150);

    try std.testing.expectEqual(@as(u64, 4), histogram.getCount());
}

test "runtime metrics export" {
    var metrics = try RuntimeMetrics.init(std.testing.allocator);
    defer metrics.deinit();

    metrics.containers_created.inc();
    metrics.syscalls_allowed.add(100);

    const output = try metrics.exportPrometheus(std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "zigviz_containers_created_total 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zigviz_syscalls_allowed_total 100") != null);
}
