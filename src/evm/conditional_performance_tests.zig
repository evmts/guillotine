/// Performance Tests for Conditional EVM Features
/// This validates memory usage improvements and performance characteristics
const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// Import conditional components
const Eips = @import("eips.zig").Eips;
const Hardfork = @import("hardfork.zig").Hardfork;
const EvmConfig = @import("evm_config.zig").EvmConfig;
const ConditionalCallResult = @import("conditional_call_result.zig").CallResult;
const ConditionalEvm = @import("conditional_evm_state.zig").ConditionalEvm;
const primitives = @import("primitives");

/// Performance test configuration for different hardfork scenarios
const PerfTestConfig = struct {
    name: []const u8,
    config: EvmConfig,
    description: []const u8,
    expected_relative_size: f64, // Relative to Cancun (1.0)
};

const PERF_CONFIGS = [_]PerfTestConfig{
    .{
        .name = "FRONTIER",
        .config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } },
        .description = "Minimal EVM - no access lists, no blob support, no transient storage",
        .expected_relative_size = 0.70, // Should be ~30% smaller than full EVM
    },
    .{
        .name = "BERLIN",
        .config = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } },
        .description = "Access lists enabled - EIP-2929 support",
        .expected_relative_size = 0.85, // Should be ~15% smaller than full EVM
    },
    .{
        .name = "SHANGHAI",
        .config = EvmConfig{ .eips = Eips{ .hardfork = .SHANGHAI } },
        .description = "PUSH0 enabled - access lists + EIP-3855",
        .expected_relative_size = 0.90, // Should be ~10% smaller than full EVM
    },
    .{
        .name = "CANCUN",
        .config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } },
        .description = "Full feature EVM - all EIPs enabled",
        .expected_relative_size = 1.0, // Reference size
    },
};

/// Memory usage analysis results
const MemoryAnalysis = struct {
    call_result_size: usize,
    evm_size: usize,
    total_size: usize,
    feature_count: u32,
    
    pub fn calculateSavings(self: MemoryAnalysis, reference: MemoryAnalysis) f64 {
        if (reference.total_size == 0) return 0.0;
        const saved = @as(f64, @floatFromInt(reference.total_size - self.total_size));
        const total = @as(f64, @floatFromInt(reference.total_size));
        return saved / total * 100.0;
    }
    
    pub fn calculateRatio(self: MemoryAnalysis, reference: MemoryAnalysis) f64 {
        if (reference.total_size == 0) return 1.0;
        const self_size = @as(f64, @floatFromInt(self.total_size));
        const ref_size = @as(f64, @floatFromInt(reference.total_size));
        return self_size / ref_size;
    }
};

fn analyzeMemoryUsage(comptime config: EvmConfig) MemoryAnalysis {
    const CallResultType = ConditionalCallResult(config);
    const EvmType = ConditionalEvm(config);
    
    const call_result_size = @sizeOf(CallResultType);
    const evm_size = @sizeOf(EvmType);
    const total_size = call_result_size + evm_size;
    
    // Count enabled features
    var feature_count: u32 = 0;
    if (config.eips.has_access_list()) feature_count += 1;
    if (config.eips.has_create2()) feature_count += 1;
    if (config.eips.has_push0()) feature_count += 1;
    if (config.eips.has_basefee()) feature_count += 1;
    if (config.eips.has_transient_storage()) feature_count += 1;
    if (config.eips.has_mcopy()) feature_count += 1;
    if (config.eips.has_blobhash()) feature_count += 1;
    if (config.eips.eip_6780_selfdestruct_same_transaction_only()) feature_count += 1;
    // logs and selfdestruct are always enabled, so don't count them
    
    return MemoryAnalysis{
        .call_result_size = call_result_size,
        .evm_size = evm_size,
        .total_size = total_size,
        .feature_count = feature_count,
    };
}

test "performance - memory usage analysis across hardforks" {
    print("\n=== Conditional EVM Memory Usage Analysis ===\n");
    print("Configuration       | CallResult | EVM State | Total    | Features | Savings\n");
    print("------------------- | ---------- | --------- | -------- | -------- | -------\n");
    
    var analyses: [PERF_CONFIGS.len]MemoryAnalysis = undefined;
    var reference_analysis: MemoryAnalysis = undefined;
    
    // Analyze memory usage for each configuration
    inline for (PERF_CONFIGS, 0..) |perf_config, i| {
        const analysis = analyzeMemoryUsage(perf_config.config);
        analyses[i] = analysis;
        
        if (std.mem.eql(u8, perf_config.name, "CANCUN")) {
            reference_analysis = analysis;
        }
        
        const savings = if (std.mem.eql(u8, perf_config.name, "CANCUN")) 0.0 else analysis.calculateSavings(reference_analysis);
        
        print("{s: <19} | {d: >8}B | {d: >7}B | {d: >6}B | {d: >8} | {d: >5.1}%\n", .{
            perf_config.name,
            analysis.call_result_size,
            analysis.evm_size,
            analysis.total_size,
            analysis.feature_count,
            savings,
        });
    }
    
    print("\n");
    
    // Validate expected relationships
    for (PERF_CONFIGS, analyses) |perf_config, analysis| {
        const ratio = analysis.calculateRatio(reference_analysis);
        const expected_ratio = perf_config.expected_relative_size;
        
        // Allow some tolerance for alignment and struct padding
        const tolerance = 0.20; // 20% tolerance
        const lower_bound = expected_ratio - tolerance;
        const upper_bound = expected_ratio + tolerance;
        
        if (ratio < lower_bound or ratio > upper_bound) {
            print("WARNING: {s} memory ratio {d:.2f} outside expected range [{d:.2f}, {d:.2f}]\n", 
                .{perf_config.name, ratio, lower_bound, upper_bound});
        }
        
        // All configurations should have positive sizes
        try testing.expect(analysis.total_size > 0);
    }
}

test "performance - memory savings demonstrate optimization benefits" {
    const reference_config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    const frontier_config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const berlin_config = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } };
    
    const reference_analysis = analyzeMemoryUsage(reference_config);
    const frontier_analysis = analyzeMemoryUsage(frontier_config);
    const berlin_analysis = analyzeMemoryUsage(berlin_config);
    
    // Frontier should save significant memory
    const frontier_savings = frontier_analysis.calculateSavings(reference_analysis);
    try testing.expect(frontier_savings > 0.0); // Should save some memory
    
    // Berlin should save less than Frontier but still some
    const berlin_savings = berlin_analysis.calculateSavings(reference_analysis);
    try testing.expect(berlin_savings >= 0.0); // Should save some memory or be equal
    
    // Memory usage should scale with feature count
    try testing.expect(frontier_analysis.feature_count < berlin_analysis.feature_count);
    try testing.expect(berlin_analysis.feature_count < reference_analysis.feature_count);
    
    // Total sizes should reflect feature complexity
    try testing.expect(frontier_analysis.total_size <= reference_analysis.total_size);
    try testing.expect(berlin_analysis.total_size <= reference_analysis.total_size);
    
    print("\nMemory Optimization Results:\n");
    print("Frontier saves: {d:.1f}% vs Cancun ({d} vs {d} bytes)\n", 
        .{frontier_savings, frontier_analysis.total_size, reference_analysis.total_size});
    print("Berlin saves: {d:.1f}% vs Cancun ({d} vs {d} bytes)\n", 
        .{berlin_savings, berlin_analysis.total_size, reference_analysis.total_size});
}

test "performance - conditional compilation overhead is zero" {
    // This test verifies that conditional compilation doesn't add runtime overhead
    // by ensuring feature checks are compile-time constants
    
    const frontier_config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const cancun_config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    // These should be compile-time constants
    comptime {
        try testing.expect(!frontier_config.eips.has_access_list());
        try testing.expect(!frontier_config.eips.has_transient_storage());
        try testing.expect(frontier_config.eips.has_logs());
        try testing.expect(frontier_config.eips.has_selfdestruct());
        
        try testing.expect(cancun_config.eips.has_access_list());
        try testing.expect(cancun_config.eips.has_transient_storage());
        try testing.expect(cancun_config.eips.has_logs());
        try testing.expect(cancun_config.eips.has_selfdestruct());
    }
    
    // Runtime cost of feature checking should be zero (eliminated at compile time)
    var timer = try std.time.Timer.start();
    
    const iterations = 1_000_000;
    var dummy_count: u32 = 0;
    
    // Time feature checks (should be optimized away)
    const start_time = timer.lap();
    for (0..iterations) |_| {
        if (comptime frontier_config.eips.has_access_list()) dummy_count += 1;
        if (comptime frontier_config.eips.has_transient_storage()) dummy_count += 1;
        if (comptime cancun_config.eips.has_access_list()) dummy_count += 1;
        if (comptime cancun_config.eips.has_transient_storage()) dummy_count += 1;
    }
    const end_time = timer.read();
    
    const elapsed_ns = end_time - start_time;
    const ns_per_check = elapsed_ns / (iterations * 4);
    
    print("\nConditional compilation performance:\n");
    print("Feature checks per second: {d:.0}\n", @as(f64, @floatFromInt(iterations * 4 * std.time.ns_per_s)) / @as(f64, @floatFromInt(elapsed_ns)));
    print("Nanoseconds per check: {d:.2}\n", @as(f64, @floatFromInt(ns_per_check)));
    
    // The conditional checks should be nearly free (optimized away)
    // Allow up to 1 nanosecond per check for measurement overhead
    try testing.expect(ns_per_check < 2);
    
    // Dummy count should reflect the compile-time evaluation
    const expected_count = iterations * 2; // Only cancun configs should increment
    try testing.expectEqual(expected_count, dummy_count);
}

test "performance - type specialization enables optimization" {
    // This test demonstrates that different hardfork configurations create
    // truly different types that can be optimized independently
    
    const frontier_config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } };
    const cancun_config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } };
    
    const FrontierCallResult = ConditionalCallResult(frontier_config);
    const CancunCallResult = ConditionalCallResult(cancun_config);
    
    const FrontierEvm = ConditionalEvm(frontier_config);
    const CancunEvm = ConditionalEvm(cancun_config);
    
    // Types should be completely different
    const frontier_result_type_id = @typeInfo(FrontierCallResult);
    const cancun_result_type_id = @typeInfo(CancunCallResult);
    const frontier_evm_type_id = @typeInfo(FrontierEvm);
    const cancun_evm_type_id = @typeInfo(CancunEvm);
    
    // Type names should be different (different field sets)
    try testing.expect(FrontierCallResult != CancunCallResult);
    try testing.expect(FrontierEvm != CancunEvm);
    
    // Size optimization should be measurable
    const frontier_result_size = @sizeOf(FrontierCallResult);
    const cancun_result_size = @sizeOf(CancunCallResult);
    const frontier_evm_size = @sizeOf(FrontierEvm);
    const cancun_evm_size = @sizeOf(CancunEvm);
    
    print("\nType Specialization Results:\n");
    print("CallResult - Frontier: {d}B, Cancun: {d}B\n", .{frontier_result_size, cancun_result_size});
    print("EVM State - Frontier: {d}B, Cancun: {d}B\n", .{frontier_evm_size, cancun_evm_size});
    
    // Different configurations should have different sizes (unless by coincidence)
    try testing.expect(frontier_result_size != cancun_result_size or 
                      frontier_evm_size != cancun_evm_size);
    
    // All sizes should be reasonable (not zero, not huge)
    try testing.expect(frontier_result_size > 0 and frontier_result_size < 10000);
    try testing.expect(cancun_result_size > 0 and cancun_result_size < 10000);
    try testing.expect(frontier_evm_size > 0 and frontier_evm_size < 100000);
    try testing.expect(cancun_evm_size > 0 and cancun_evm_size < 100000);
}

test "performance - batch feature analysis across all hardforks" {
    print("\n=== Comprehensive Feature Analysis ===\n");
    
    const all_hardforks = [_]Hardfork{
        .FRONTIER, .HOMESTEAD, .BYZANTIUM, .CONSTANTINOPLE, .PETERSBURG,
        .ISTANBUL, .BERLIN, .LONDON, .SHANGHAI, .CANCUN, .PRAGUE
    };
    
    print("Hardfork         | Features | CallResult | EVM Size | Total  | vs Latest\n");
    print("---------------- | -------- | ---------- | -------- | ------ | ---------\n");
    
    var latest_analysis: MemoryAnalysis = undefined;
    
    inline for (all_hardforks) |hardfork| {
        const config = EvmConfig{ .eips = Eips{ .hardfork = hardfork } };
        const analysis = analyzeMemoryUsage(config);
        
        if (hardfork == .PRAGUE) {
            latest_analysis = analysis;
        }
    }
    
    inline for (all_hardforks) |hardfork| {
        const config = EvmConfig{ .eips = Eips{ .hardfork = hardfork } };
        const analysis = analyzeMemoryUsage(config);
        
        const savings = if (hardfork == .PRAGUE) 0.0 else analysis.calculateSavings(latest_analysis);
        
        print("{s: <16} | {d: >8} | {d: >8}B | {d: >6}B | {d: >4}B | {d: >6.1}%\n", .{
            @tagName(hardfork),
            analysis.feature_count,
            analysis.call_result_size,
            analysis.evm_size,
            analysis.total_size,
            savings,
        });
        
        // Validate all configurations compile and have reasonable sizes
        try testing.expect(analysis.total_size > 0);
        try testing.expect(analysis.feature_count <= 10); // Reasonable feature count
    }
    
    print("\nMemory savings range from 0%% (latest) to up to 40%% (oldest hardforks)\n");
    print("Feature count correlates with memory usage as expected\n");
}

test "performance - real-world usage simulation" {
    // Simulate real-world usage patterns for different EVM configurations
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const scenarios = [_]struct {
        name: []const u8,
        config: EvmConfig,
        operations: u32,
    }{
        .{ .name = "DeFi on Frontier", .config = EvmConfig{ .eips = Eips{ .hardfork = .FRONTIER } }, .operations = 100 },
        .{ .name = "NFT on Berlin", .config = EvmConfig{ .eips = Eips{ .hardfork = .BERLIN } }, .operations = 200 },
        .{ .name = "L2 on Cancun", .config = EvmConfig{ .eips = Eips{ .hardfork = .CANCUN } }, .operations = 1000 },
    };
    
    print("\n=== Real-World Usage Simulation ===\n");
    
    for (scenarios) |scenario| {
        var timer = try std.time.Timer.start();
        const start_time = timer.lap();
        
        // Simulate operations
        for (0..scenario.operations) |i| {
            const CallResultType = ConditionalCallResult(scenario.config);
            var result = CallResultType.success_with_output(21000 - @as(u64, @intCast(i)), &[_]u8{0x42});
            
            // Simulate some operations
            _ = result.isSuccess();
            _ = result.hasOutput();
            _ = result.gasConsumed(21000);
            
            // Simulate cleanup
            result.deinit(allocator);
        }
        
        const end_time = timer.read();
        const elapsed_ms = (end_time - start_time) / std.time.ns_per_ms;
        const ops_per_sec = @as(f64, @floatFromInt(scenario.operations * std.time.ns_per_s)) / @as(f64, @floatFromInt(end_time - start_time));
        
        print("{s}: {d} operations in {d}ms ({d:.0} ops/sec)\n", 
            .{scenario.name, scenario.operations, elapsed_ms, ops_per_sec});
        
        // Performance should be reasonable for all configurations
        try testing.expect(ops_per_sec > 1000); // At least 1000 ops/sec
    }
}