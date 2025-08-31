const std = @import("std");
const testing = std.testing;
const evm_mod = @import("evm");
const primitives = @import("primitives");

// Benchmark to measure performance improvement from fusion patterns

const BenchmarkConfig = struct {
    iterations: usize = 10000,
    bytecode_size: usize = 1000,
};

fn createConstantFoldingBytecode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    var bytecode = try allocator.alloc(u8, size);
    var i: usize = 0;
    
    // Fill with constant folding patterns
    while (i + 5 <= size) {
        // PUSH1 random, PUSH1 random, ADD
        bytecode[i] = 0x60; // PUSH1
        bytecode[i + 1] = @intCast(i % 256);
        bytecode[i + 2] = 0x60; // PUSH1
        bytecode[i + 3] = @intCast((i + 1) % 256);
        bytecode[i + 4] = 0x01; // ADD
        i += 5;
    }
    
    // Fill remaining with STOP
    while (i < size) : (i += 1) {
        bytecode[i] = 0x00; // STOP
    }
    
    return bytecode;
}

fn createMultiPushBytecode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    var bytecode = try allocator.alloc(u8, size);
    var i: usize = 0;
    
    // Fill with multi-PUSH patterns
    while (i + 6 <= size) {
        // Three consecutive PUSH1 operations
        bytecode[i] = 0x60; // PUSH1
        bytecode[i + 1] = @intCast(i % 256);
        bytecode[i + 2] = 0x60; // PUSH1
        bytecode[i + 3] = @intCast((i + 1) % 256);
        bytecode[i + 4] = 0x60; // PUSH1
        bytecode[i + 5] = @intCast((i + 2) % 256);
        i += 6;
    }
    
    // Fill remaining with STOP
    while (i < size) : (i += 1) {
        bytecode[i] = 0x00; // STOP
    }
    
    return bytecode;
}

fn createMultiPopBytecode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    var bytecode = try allocator.alloc(u8, size);
    var i: usize = 0;
    
    // Fill with PUSH followed by multi-POP patterns
    while (i + 6 <= size) {
        // Push some values then pop them
        bytecode[i] = 0x60; // PUSH1
        bytecode[i + 1] = 0x01;
        bytecode[i + 2] = 0x60; // PUSH1
        bytecode[i + 3] = 0x02;
        bytecode[i + 4] = 0x50; // POP
        bytecode[i + 5] = 0x50; // POP
        i += 6;
    }
    
    // Fill remaining with STOP
    while (i < size) : (i += 1) {
        bytecode[i] = 0x00; // STOP
    }
    
    return bytecode;
}

test "benchmark: constant folding performance" {
    if (@import("builtin").is_test) {
        // Skip benchmarks in normal test runs
        return;
    }
    
    const allocator = testing.allocator;
    const config = BenchmarkConfig{};
    
    // Create bytecode with many constant folding opportunities
    const bytecode = try createConstantFoldingBytecode(allocator, config.bytecode_size);
    defer allocator.free(bytecode);
    
    // Create bytecode analyzer with fusion enabled
    const BytecodeWithFusion = evm_mod.Bytecode(.{
        .max_bytecode_size = 10000,
        .fusions_enabled = true,
    });
    
    const BytecodeWithoutFusion = evm_mod.Bytecode(.{
        .max_bytecode_size = 10000,
        .fusions_enabled = false,
    });
    
    // Benchmark with fusion
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        var bc = try BytecodeWithFusion.init(allocator, bytecode);
        defer bc.deinit();
        
        // Iterate through to trigger fusion detection
        var iter = bc.createIterator();
        while (iter.next()) |_| {}
    }
    const fusion_time = timer.read();
    
    // Benchmark without fusion
    timer.reset();
    i = 0;
    while (i < config.iterations) : (i += 1) {
        var bc = try BytecodeWithoutFusion.init(allocator, bytecode);
        defer bc.deinit();
        
        var iter = bc.createIterator();
        while (iter.next()) |_| {}
    }
    const no_fusion_time = timer.read();
    
    const fusion_ms = @as(f64, @floatFromInt(fusion_time)) / 1_000_000;
    const no_fusion_ms = @as(f64, @floatFromInt(no_fusion_time)) / 1_000_000;
    const improvement = ((no_fusion_ms - fusion_ms) / no_fusion_ms) * 100;
    
    std.debug.print("\n=== Constant Folding Benchmark ===\n", .{});
    std.debug.print("Iterations: {}\n", .{config.iterations});
    std.debug.print("Bytecode size: {} bytes\n", .{config.bytecode_size});
    std.debug.print("With fusion: {:.2} ms\n", .{fusion_ms});
    std.debug.print("Without fusion: {:.2} ms\n", .{no_fusion_ms});
    std.debug.print("Improvement: {:.1}%\n", .{improvement});
}

test "benchmark: multi-PUSH performance" {
    if (@import("builtin").is_test) {
        // Skip benchmarks in normal test runs
        return;
    }
    
    const allocator = testing.allocator;
    const config = BenchmarkConfig{};
    
    // Create bytecode with many multi-PUSH patterns
    const bytecode = try createMultiPushBytecode(allocator, config.bytecode_size);
    defer allocator.free(bytecode);
    
    const BytecodeWithFusion = evm_mod.Bytecode(.{
        .max_bytecode_size = 10000,
        .fusions_enabled = true,
    });
    
    const BytecodeWithoutFusion = evm_mod.Bytecode(.{
        .max_bytecode_size = 10000,
        .fusions_enabled = false,
    });
    
    // Benchmark with fusion
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        var bc = try BytecodeWithFusion.init(allocator, bytecode);
        defer bc.deinit();
        
        var iter = bc.createIterator();
        while (iter.next()) |_| {}
    }
    const fusion_time = timer.read();
    
    // Benchmark without fusion
    timer.reset();
    i = 0;
    while (i < config.iterations) : (i += 1) {
        var bc = try BytecodeWithoutFusion.init(allocator, bytecode);
        defer bc.deinit();
        
        var iter = bc.createIterator();
        while (iter.next()) |_| {}
    }
    const no_fusion_time = timer.read();
    
    const fusion_ms = @as(f64, @floatFromInt(fusion_time)) / 1_000_000;
    const no_fusion_ms = @as(f64, @floatFromInt(no_fusion_time)) / 1_000_000;
    const improvement = ((no_fusion_ms - fusion_ms) / no_fusion_ms) * 100;
    
    std.debug.print("\n=== Multi-PUSH Benchmark ===\n", .{});
    std.debug.print("Iterations: {}\n", .{config.iterations});
    std.debug.print("Bytecode size: {} bytes\n", .{config.bytecode_size});
    std.debug.print("With fusion: {:.2} ms\n", .{fusion_ms});
    std.debug.print("Without fusion: {:.2} ms\n", .{no_fusion_ms});
    std.debug.print("Improvement: {:.1}%\n", .{improvement});
}

test "benchmark: multi-POP performance" {
    if (@import("builtin").is_test) {
        // Skip benchmarks in normal test runs
        return;
    }
    
    const allocator = testing.allocator;
    const config = BenchmarkConfig{};
    
    // Create bytecode with many multi-POP patterns
    const bytecode = try createMultiPopBytecode(allocator, config.bytecode_size);
    defer allocator.free(bytecode);
    
    const BytecodeWithFusion = evm_mod.Bytecode(.{
        .max_bytecode_size = 10000,
        .fusions_enabled = true,
    });
    
    const BytecodeWithoutFusion = evm_mod.Bytecode(.{
        .max_bytecode_size = 10000,
        .fusions_enabled = false,
    });
    
    // Benchmark with fusion
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        var bc = try BytecodeWithFusion.init(allocator, bytecode);
        defer bc.deinit();
        
        var iter = bc.createIterator();
        while (iter.next()) |_| {}
    }
    const fusion_time = timer.read();
    
    // Benchmark without fusion
    timer.reset();
    i = 0;
    while (i < config.iterations) : (i += 1) {
        var bc = try BytecodeWithoutFusion.init(allocator, bytecode);
        defer bc.deinit();
        
        var iter = bc.createIterator();
        while (iter.next()) |_| {}
    }
    const no_fusion_time = timer.read();
    
    const fusion_ms = @as(f64, @floatFromInt(fusion_time)) / 1_000_000;
    const no_fusion_ms = @as(f64, @floatFromInt(no_fusion_time)) / 1_000_000;
    const improvement = ((no_fusion_ms - fusion_ms) / no_fusion_ms) * 100;
    
    std.debug.print("\n=== Multi-POP Benchmark ===\n", .{});
    std.debug.print("Iterations: {}\n", .{config.iterations});
    std.debug.print("Bytecode size: {} bytes\n", .{config.bytecode_size});
    std.debug.print("With fusion: {:.2} ms\n", .{fusion_ms});
    std.debug.print("Without fusion: {:.2} ms\n", .{no_fusion_ms});
    std.debug.print("Improvement: {:.1}%\n", .{improvement});
}

// To run benchmarks: zig test test/fusion/fusion_benchmark.zig --test-filter "benchmark"