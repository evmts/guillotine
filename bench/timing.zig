const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const print = std.debug.print;

pub const BenchmarkResult = struct {
    name: []const u8,
    mean_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    iterations: u32,
    total_time_ns: u64,
    
    pub fn mean_time_ms(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.mean_time_ns)) / 1_000_000.0;
    }
    
    pub fn min_time_ms(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.min_time_ns)) / 1_000_000.0;
    }
    
    pub fn max_time_ms(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.max_time_ns)) / 1_000_000.0;
    }
    
    pub fn total_time_ms(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000.0;
    }
};

pub const BenchmarkConfig = struct {
    name: []const u8,
    iterations: u32 = 100,
    warmup_iterations: u32 = 10,
};

pub const BenchmarkSuite = struct {
    allocator: Allocator,
    results: ArrayList(BenchmarkResult),
    
    pub fn init(allocator: Allocator) BenchmarkSuite {
        return BenchmarkSuite{
            .allocator = allocator,
            .results = ArrayList(BenchmarkResult).init(allocator),
        };
    }
    
    pub fn deinit(self: *BenchmarkSuite) void {
        self.results.deinit();
    }
    
    pub fn benchmark(self: *BenchmarkSuite, config: BenchmarkConfig, comptime func: anytype) !void {
        std.log.info("Running benchmark: {s}", .{config.name});
        
        // Warmup
        var i: u32 = 0;
        while (i < config.warmup_iterations) : (i += 1) {
            _ = func();
        }
        
        var times = ArrayList(u64).init(self.allocator);
        defer times.deinit();
        
        var total_time: u64 = 0;
        var min_time: u64 = std.math.maxInt(u64);
        var max_time: u64 = 0;
        
        // Actual benchmark runs
        i = 0;
        while (i < config.iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            _ = func();
            const end = std.time.nanoTimestamp();
            
            const duration = @as(u64, @intCast(end - start));
            try times.append(duration);
            
            total_time += duration;
            if (duration < min_time) min_time = duration;
            if (duration > max_time) max_time = duration;
        }
        
        const mean_time = total_time / config.iterations;
        
        const result = BenchmarkResult{
            .name = config.name,
            .mean_time_ns = mean_time,
            .min_time_ns = min_time,
            .max_time_ns = max_time,
            .iterations = config.iterations,
            .total_time_ns = total_time,
        };
        
        try self.results.append(result);
        
        std.log.info("Benchmark '{s}' completed: {d:.3}ms avg ({d} iterations)", .{
            config.name,
            result.mean_time_ms(),
            config.iterations,
        });
    }
    
    pub fn print_results(self: *BenchmarkSuite) void {
        if (self.results.items.len == 0) {
            print("No benchmark results available\n", .{});
            return;
        }
        
        print("\n=== Benchmark Results ===\n", .{});
        for (self.results.items) |result| {
            print("{s}:\n", .{result.name});
            print("  Mean: {d:.3}ms\n", .{result.mean_time_ms()});
            print("  Min:  {d:.3}ms\n", .{result.min_time_ms()});
            print("  Max:  {d:.3}ms\n", .{result.max_time_ms()});
            print("  Iterations: {d}\n", .{result.iterations});
            print("  Total: {d:.3}ms\n", .{result.total_time_ms()});
            print("\n", .{});
        }
    }
    
    pub fn compare(self: *BenchmarkSuite, baseline_name: []const u8, comparison_name: []const u8) !void {
        var baseline_result: ?BenchmarkResult = null;
        var comparison_result: ?BenchmarkResult = null;
        
        for (self.results.items) |result| {
            if (std.mem.eql(u8, result.name, baseline_name)) {
                baseline_result = result;
            }
            if (std.mem.eql(u8, result.name, comparison_name)) {
                comparison_result = result;
            }
        }
        
        if (baseline_result == null or comparison_result == null) {
            std.log.err("Could not find both baseline and comparison results", .{});
            return error.ResultsNotFound;
        }
        
        const baseline = baseline_result.?;
        const comparison = comparison_result.?;
        
        const speedup = @as(f64, @floatFromInt(baseline.mean_time_ns)) / @as(f64, @floatFromInt(comparison.mean_time_ns));
        const percent_diff = ((@as(f64, @floatFromInt(comparison.mean_time_ns)) - @as(f64, @floatFromInt(baseline.mean_time_ns))) / @as(f64, @floatFromInt(baseline.mean_time_ns))) * 100;
        
        print("\n=== Benchmark Comparison ===\n", .{});
        print("Baseline: {s} - {d:.3}ms\n", .{ baseline.name, baseline.mean_time_ms() });
        print("Comparison: {s} - {d:.3}ms\n", .{ comparison.name, comparison.mean_time_ms() });
        print("Speedup: {d:.2}x\n", .{speedup});
        print("Percent difference: {d:.1}%\n", .{percent_diff});
        
        if (speedup > 1.0) {
            print("✓ {s} is {d:.2}x faster than {s}\n", .{ comparison.name, speedup, baseline.name });
        } else if (speedup < 1.0) {
            print("✗ {s} is {d:.2}x slower than {s}\n", .{ comparison.name, 1.0 / speedup, baseline.name });
        } else {
            print("≈ Both implementations have similar performance\n", .{});
        }
    }
};

// Helper function to benchmark a function with arguments
pub fn benchmark_with_args(_: Allocator, config: BenchmarkConfig, comptime func: anytype, args: anytype) !BenchmarkResult {
    std.log.info("Running benchmark: {s}", .{config.name});
    
    // Warmup
    var i: u32 = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        _ = @call(.auto, func, args);
    }
    
    var total_time: u64 = 0;
    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;
    
    // Actual benchmark runs
    i = 0;
    while (i < config.iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = @call(.auto, func, args);
        const end = std.time.nanoTimestamp();
        
        const duration = @as(u64, @intCast(end - start));
        
        total_time += duration;
        if (duration < min_time) min_time = duration;
        if (duration > max_time) max_time = duration;
    }
    
    const mean_time = total_time / config.iterations;
    
    return BenchmarkResult{
        .name = config.name,
        .mean_time_ns = mean_time,
        .min_time_ns = min_time,
        .max_time_ns = max_time,
        .iterations = config.iterations,
        .total_time_ns = total_time,
    };
}

test "benchmark timing" {
    const allocator = std.testing.allocator;
    
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    const TestFunction = struct {
        fn simple_work() void {
            var sum: u64 = 0;
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                sum += i;
            }
        }
    };
    
    try suite.benchmark(BenchmarkConfig{
        .name = "simple_work",
        .iterations = 10,
        .warmup_iterations = 2,
    }, TestFunction.simple_work);
    
    try std.testing.expectEqual(@as(usize, 1), suite.results.items.len);
    try std.testing.expect(suite.results.items[0].mean_time_ns > 0);
}