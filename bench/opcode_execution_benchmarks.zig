const std = @import("std");

// Import the execution modules with benchmarks
const arithmetic = @import("../src/evm/execution/arithmetic.zig");
const stack = @import("../src/evm/execution/stack.zig");
const memory = @import("../src/evm/execution/memory.zig");
const control = @import("../src/evm/execution/control.zig");

/// Comprehensive benchmark runner for all opcode execution implementations
pub fn run_all_opcode_benchmarks(allocator: std.mem.Allocator) !void {
    std.log.info("Starting comprehensive opcode execution benchmarks for Issue #62", .{});
    std.log.info("===========================================================", .{});
    
    // Run arithmetic benchmarks
    std.log.info("", .{});
    try arithmetic.run_all_arithmetic_benchmarks(allocator);
    
    // Run stack benchmarks  
    std.log.info("", .{});
    try stack.run_all_stack_benchmarks(allocator);
    
    // Run memory benchmarks
    std.log.info("", .{});
    try memory.run_all_memory_benchmarks(allocator);
    
    // Run control flow benchmarks
    std.log.info("", .{});
    try control.run_all_control_benchmarks(allocator);
    
    std.log.info("", .{});
    std.log.info("Opcode execution benchmarks completed successfully!", .{});
    std.log.info("===========================================================", .{});
}

/// Individual benchmark functions for specific opcode categories
pub const BenchmarkCategory = enum {
    arithmetic,
    stack,
    memory,
    control,
    all,
};

pub fn run_benchmark_category(allocator: std.mem.Allocator, category: BenchmarkCategory) !void {
    switch (category) {
        .arithmetic => try arithmetic.run_all_arithmetic_benchmarks(allocator),
        .stack => try stack.run_all_stack_benchmarks(allocator),
        .memory => try memory.run_all_memory_benchmarks(allocator),
        .control => try control.run_all_control_benchmarks(allocator),
        .all => try run_all_opcode_benchmarks(allocator),
    }
}

/// Benchmark configuration that can be used across all opcode benchmarks
pub const OpcodeBenchmarkConfig = struct {
    iterations: usize = 10000,
    warmup_iterations: usize = 1000,
    
    /// Create a fast configuration for quick tests
    pub fn fast() OpcodeBenchmarkConfig {
        return OpcodeBenchmarkConfig{
            .iterations = 1000,
            .warmup_iterations = 100,
        };
    }
    
    /// Create a thorough configuration for production benchmarks
    pub fn thorough() OpcodeBenchmarkConfig {
        return OpcodeBenchmarkConfig{
            .iterations = 100000,
            .warmup_iterations = 10000,
        };
    }
};

/// Performance summary for an individual opcode
pub const OpcodePerformance = struct {
    opcode_name: []const u8,
    ns_per_operation: u64,
    total_time_ns: u64,
    iterations: usize,
};

/// Comprehensive benchmark results aggregator
pub const BenchmarkResults = struct {
    arithmetic_results: std.ArrayList(OpcodePerformance),
    stack_results: std.ArrayList(OpcodePerformance),
    memory_results: std.ArrayList(OpcodePerformance),
    control_results: std.ArrayList(OpcodePerformance),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .arithmetic_results = std.ArrayList(OpcodePerformance).init(allocator),
            .stack_results = std.ArrayList(OpcodePerformance).init(allocator),
            .memory_results = std.ArrayList(OpcodePerformance).init(allocator),
            .control_results = std.ArrayList(OpcodePerformance).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.arithmetic_results.deinit();
        self.stack_results.deinit();
        self.memory_results.deinit();
        self.control_results.deinit();
    }
    
    pub fn print_summary(self: *const Self) void {
        std.log.info("", .{});
        std.log.info("BENCHMARK RESULTS SUMMARY", .{});
        std.log.info("=========================", .{});
        
        self.print_category_summary("ARITHMETIC OPERATIONS", self.arithmetic_results.items);
        self.print_category_summary("STACK OPERATIONS", self.stack_results.items);
        self.print_category_summary("MEMORY OPERATIONS", self.memory_results.items);
        self.print_category_summary("CONTROL FLOW OPERATIONS", self.control_results.items);
    }
    
    fn print_category_summary(self: *const Self, category_name: []const u8, results: []const OpcodePerformance) void {
        _ = self;
        if (results.len == 0) return;
        
        std.log.info("", .{});
        std.log.info("{s}:", .{category_name});
        std.log.info("{s}", .{"-" ** category_name.len});
        
        var fastest: ?OpcodePerformance = null;
        var slowest: ?OpcodePerformance = null;
        var total_time: u64 = 0;
        
        for (results) |result| {
            total_time += result.total_time_ns;
            
            if (fastest == null or result.ns_per_operation < fastest.?.ns_per_operation) {
                fastest = result;
            }
            if (slowest == null or result.ns_per_operation > slowest.?.ns_per_operation) {
                slowest = result;
            }
            
            std.log.info("  {s}: {} ns/op", .{ result.opcode_name, result.ns_per_operation });
        }
        
        if (fastest != null and slowest != null) {
            std.log.info("  Fastest: {s} ({} ns/op)", .{ fastest.?.opcode_name, fastest.?.ns_per_operation });
            std.log.info("  Slowest: {s} ({} ns/op)", .{ slowest.?.opcode_name, slowest.?.ns_per_operation });
            const speedup = @as(f64, @floatFromInt(slowest.?.ns_per_operation)) / @as(f64, @floatFromInt(fastest.?.ns_per_operation));
            std.log.info("  Speed difference: {d:.2}x", .{speedup});
        }
    }
};

test "opcode_execution_benchmarks_basic" {
    const allocator = std.testing.allocator;
    
    // Test that all benchmark categories can be run without errors
    try run_benchmark_category(allocator, .arithmetic);
    try run_benchmark_category(allocator, .stack);
    try run_benchmark_category(allocator, .memory);
    try run_benchmark_category(allocator, .control);
}

test "benchmark_config_variants" {
    const fast_config = OpcodeBenchmarkConfig.fast();
    const thorough_config = OpcodeBenchmarkConfig.thorough();
    
    try std.testing.expect(fast_config.iterations < thorough_config.iterations);
    try std.testing.expect(fast_config.warmup_iterations < thorough_config.warmup_iterations);
}

test "benchmark_results_aggregator" {
    const allocator = std.testing.allocator;
    
    var results = BenchmarkResults.init(allocator);
    defer results.deinit();
    
    try results.arithmetic_results.append(OpcodePerformance{
        .opcode_name = "ADD",
        .ns_per_operation = 50,
        .total_time_ns = 500000,
        .iterations = 10000,
    });
    
    try std.testing.expectEqual(@as(usize, 1), results.arithmetic_results.items.len);
    try std.testing.expectEqualStrings("ADD", results.arithmetic_results.items[0].opcode_name);
}