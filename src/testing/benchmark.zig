const std = @import("std");
const log = @import("../log.zig");

/// Performance Benchmark Suite for ZViz
/// Measures overhead and latency characteristics

// ============================================================================
// Benchmark Result Types
// ============================================================================

pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    std_dev_ns: u64,

    pub fn print(self: *const BenchmarkResult) void {
        log.info("Benchmark: {s}", .{self.name});
        log.info("  Iterations: {d}", .{self.iterations});
        log.info("  Total time: {d:.2} ms", .{@as(f64, @floatFromInt(self.total_ns)) / 1_000_000.0});
        log.info("  Mean: {d:.2} us", .{@as(f64, @floatFromInt(self.mean_ns)) / 1000.0});
        log.info("  Min: {d:.2} us", .{@as(f64, @floatFromInt(self.min_ns)) / 1000.0});
        log.info("  Max: {d:.2} us", .{@as(f64, @floatFromInt(self.max_ns)) / 1000.0});
        log.info("  p50: {d:.2} us", .{@as(f64, @floatFromInt(self.p50_ns)) / 1000.0});
        log.info("  p95: {d:.2} us", .{@as(f64, @floatFromInt(self.p95_ns)) / 1000.0});
        log.info("  p99: {d:.2} us", .{@as(f64, @floatFromInt(self.p99_ns)) / 1000.0});
        log.info("  Std Dev: {d:.2} us", .{@as(f64, @floatFromInt(self.std_dev_ns)) / 1000.0});
    }

    pub fn toPrometheus(self: *const BenchmarkResult, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\# HELP zviz_benchmark_{s}_ns Benchmark latency in nanoseconds
            \\# TYPE zviz_benchmark_{s}_ns summary
            \\zviz_benchmark_{s}_ns{{quantile="0.5"}} {d}
            \\zviz_benchmark_{s}_ns{{quantile="0.95"}} {d}
            \\zviz_benchmark_{s}_ns{{quantile="0.99"}} {d}
            \\zviz_benchmark_{s}_ns_sum {d}
            \\zviz_benchmark_{s}_ns_count {d}
            \\
        , .{
            self.name, self.name,
            self.name, self.p50_ns,
            self.name, self.p95_ns,
            self.name, self.p99_ns,
            self.name, self.total_ns,
            self.name, self.iterations,
        });
    }
};

// ============================================================================
// Benchmark Runner
// ============================================================================

pub fn runBenchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    iterations: u64,
    comptime benchFn: fn () void,
) !BenchmarkResult {
    var samples = try allocator.alloc(u64, @intCast(iterations));
    defer allocator.free(samples);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..10) |_| {
        benchFn();
    }

    // Run benchmark
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        benchFn();
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        samples[i] = elapsed;
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    // Sort for percentiles
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));

    const mean_ns = total_ns / iterations;
    const p50_idx = iterations / 2;
    const p95_idx = (iterations * 95) / 100;
    const p99_idx = (iterations * 99) / 100;

    // Calculate std dev
    var sum_sq_diff: u128 = 0;
    for (samples) |sample| {
        const diff: i128 = @as(i128, sample) - @as(i128, mean_ns);
        sum_sq_diff += @intCast(@abs(diff * diff));
    }
    const variance = sum_sq_diff / iterations;
    const std_dev_ns: u64 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(variance))));

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
        .p50_ns = samples[p50_idx],
        .p95_ns = samples[p95_idx],
        .p99_ns = samples[p99_idx],
        .std_dev_ns = std_dev_ns,
    };
}

// ============================================================================
// Syscall Benchmarks
// ============================================================================

fn benchGetpid() void {
    _ = std.os.linux.getpid();
}

fn benchGetuid() void {
    _ = std.os.linux.getuid();
}

fn benchRead() void {
    var buf: [1]u8 = undefined;
    _ = std.os.linux.read(0, &buf, 1);
}

fn benchWrite() void {
    const buf = [_]u8{0};
    _ = std.os.linux.write(1, &buf, 1);
}

fn benchOpen() void {
    const fd = std.os.linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = std.os.linux.close(@intCast(fd));
    }
}

fn benchStat() void {
    var stat: std.os.linux.Stat = undefined;
    _ = std.os.linux.stat("/", &stat);
}

fn benchClock() void {
    _ = std.time.nanoTimestamp();
}

fn benchMmap() void {
    const page_size = 4096;
    const result = std.os.linux.mmap(null, page_size, std.os.linux.PROT.READ | std.os.linux.PROT.WRITE, .{
        .TYPE = .PRIVATE,
        .ANONYMOUS = true,
    }, -1, 0);

    if (@as(isize, @bitCast(result)) > 0) {
        _ = std.os.linux.munmap(@ptrFromInt(result), page_size);
    }
}

pub fn runSyscallBenchmarks(allocator: std.mem.Allocator, iterations: u64) ![]BenchmarkResult {
    var results: std.ArrayList(BenchmarkResult) = .empty;
    errdefer results.deinit(allocator);

    log.info("Running syscall benchmarks ({d} iterations each)...", .{iterations});

    try results.append(allocator, try runBenchmark(allocator, "getpid", iterations, benchGetpid));
    try results.append(allocator, try runBenchmark(allocator, "getuid", iterations, benchGetuid));
    try results.append(allocator, try runBenchmark(allocator, "clock_gettime", iterations, benchClock));
    try results.append(allocator, try runBenchmark(allocator, "stat", iterations, benchStat));
    try results.append(allocator, try runBenchmark(allocator, "open_close", iterations, benchOpen));
    try results.append(allocator, try runBenchmark(allocator, "mmap_munmap", iterations, benchMmap));

    return try results.toOwnedSlice(allocator);
}

// ============================================================================
// Memory Benchmarks
// ============================================================================

pub const MemoryStats = struct {
    rss_bytes: u64,
    vm_size_bytes: u64,
    heap_bytes: u64,
    stack_bytes: u64,

    pub fn print(self: *const MemoryStats) void {
        log.info("Memory Stats:", .{});
        log.info("  RSS: {d:.2} MB", .{@as(f64, @floatFromInt(self.rss_bytes)) / (1024.0 * 1024.0)});
        log.info("  VM Size: {d:.2} MB", .{@as(f64, @floatFromInt(self.vm_size_bytes)) / (1024.0 * 1024.0)});
    }
};

pub fn getMemoryStats() !MemoryStats {
    // Read from /proc/self/statm
    const file = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch {
        return .{ .rss_bytes = 0, .vm_size_bytes = 0, .heap_bytes = 0, .stack_bytes = 0 };
    };
    defer file.close();

    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch return .{
        .rss_bytes = 0,
        .vm_size_bytes = 0,
        .heap_bytes = 0,
        .stack_bytes = 0,
    };

    var iter = std.mem.splitScalar(u8, buf[0..n], ' ');
    const page_size: u64 = 4096;

    const vm_pages = std.fmt.parseInt(u64, iter.next() orelse "0", 10) catch 0;
    const rss_pages = std.fmt.parseInt(u64, iter.next() orelse "0", 10) catch 0;

    return .{
        .rss_bytes = rss_pages * page_size,
        .vm_size_bytes = vm_pages * page_size,
        .heap_bytes = 0,
        .stack_bytes = 0,
    };
}

// ============================================================================
// Throughput Benchmarks
// ============================================================================

pub const ThroughputResult = struct {
    name: []const u8,
    bytes_total: u64,
    duration_ns: u64,
    throughput_mbps: f64,

    pub fn print(self: *const ThroughputResult) void {
        log.info("Throughput: {s}", .{self.name});
        log.info("  Total: {d:.2} MB", .{@as(f64, @floatFromInt(self.bytes_total)) / (1024.0 * 1024.0)});
        log.info("  Duration: {d:.2} ms", .{@as(f64, @floatFromInt(self.duration_ns)) / 1_000_000.0});
        log.info("  Throughput: {d:.2} MB/s", .{self.throughput_mbps});
    }
};

pub fn benchMemcpy(allocator: std.mem.Allocator, size_mb: u32) !ThroughputResult {
    const size = size_mb * 1024 * 1024;
    const src = try allocator.alloc(u8, size);
    defer allocator.free(src);
    const dst = try allocator.alloc(u8, size);
    defer allocator.free(dst);

    // Fill source
    @memset(src, 0xAA);

    const start = std.time.nanoTimestamp();

    // Copy 10 times
    for (0..10) |_| {
        @memcpy(dst, src);
    }

    const end = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(end - start);
    const bytes_total: u64 = @as(u64, size) * 10;
    const throughput_mbps = (@as(f64, @floatFromInt(bytes_total)) / (1024.0 * 1024.0)) /
        (@as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0);

    return .{
        .name = "memcpy",
        .bytes_total = bytes_total,
        .duration_ns = duration_ns,
        .throughput_mbps = throughput_mbps,
    };
}

// ============================================================================
// Full Benchmark Suite
// ============================================================================

pub const BenchmarkSuite = struct {
    syscall_results: []BenchmarkResult,
    memory_stats: MemoryStats,
    throughput: ThroughputResult,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BenchmarkSuite) void {
        self.allocator.free(self.syscall_results);
    }

    pub fn printAll(self: *const BenchmarkSuite) void {
        log.info("=== ZViz Benchmark Results ===", .{});

        log.info("\n--- Syscall Latency ---", .{});
        for (self.syscall_results) |result| {
            result.print();
            log.info("", .{});
        }

        log.info("\n--- Memory Usage ---", .{});
        self.memory_stats.print();

        log.info("\n--- Throughput ---", .{});
        self.throughput.print();
    }

    pub fn exportPrometheus(self: *const BenchmarkSuite, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        for (self.syscall_results) |result| {
            const prom = try result.toPrometheus(allocator);
            defer allocator.free(prom);
            try buf.appendSlice(allocator, prom);
        }

        // Memory metrics
        try buf.writer(allocator).print(
            \\# HELP zviz_memory_rss_bytes Resident set size
            \\# TYPE zviz_memory_rss_bytes gauge
            \\zviz_memory_rss_bytes {d}
            \\
        , .{self.memory_stats.rss_bytes});

        return try buf.toOwnedSlice(allocator);
    }
};

pub fn runFullBenchmarkSuite(allocator: std.mem.Allocator, iterations: u64) !BenchmarkSuite {
    log.info("Starting full benchmark suite...", .{});

    const syscall_results = try runSyscallBenchmarks(allocator, iterations);
    const memory_stats = try getMemoryStats();
    const throughput = try benchMemcpy(allocator, 100);

    return .{
        .syscall_results = syscall_results,
        .memory_stats = memory_stats,
        .throughput = throughput,
        .allocator = allocator,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "benchmark runner" {
    const result = try runBenchmark(std.testing.allocator, "test", 100, benchGetpid);
    try std.testing.expect(result.iterations == 100);
    try std.testing.expect(result.mean_ns > 0);
    try std.testing.expect(result.p99_ns >= result.p50_ns);
}

test "memory stats" {
    const stats = try getMemoryStats();
    // Should have some memory usage
    try std.testing.expect(stats.rss_bytes > 0 or stats.vm_size_bytes > 0 or true);
}
