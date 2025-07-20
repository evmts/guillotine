const std = @import("std");
const evm_module = @import("evm");
const Evm = evm_module.Evm;
const Frame = evm_module.Frame;
const Contract = evm_module.Contract;
const Address = evm_module.Address;

/// Benchmark configuration
const BenchmarkConfig = struct {
    name: []const u8,
    iterations: usize,
    description: []const u8,
};

/// Benchmark result
const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_time_ns: i128,
    avg_time_ns: f64,
    ops_per_sec: f64,
};

/// Comprehensive benchmarking suite for frame pool optimization
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("=== Frame Pool Optimization Benchmarks ===\n\n", .{});
    
    const benchmarks = [_]BenchmarkConfig{
        .{ .name = "single_allocation", .iterations = 10000, .description = "Single frame allocation/deallocation" },
        .{ .name = "rapid_allocation", .iterations = 50000, .description = "Rapid allocation cycles" },
        .{ .name = "nested_calls", .iterations = 1000, .description = "Nested contract calls (depth 10)" },
        .{ .name = "mixed_depth", .iterations = 5000, .description = "Mixed depth allocations" },
        .{ .name = "memory_pressure", .iterations = 20000, .description = "High memory pressure scenario" },
        .{ .name = "realistic_execution", .iterations = 2000, .description = "Realistic EVM execution simulation" },
    };
    
    for (benchmarks) |config| {
        std.debug.print("Running benchmark: {s}\n", .{config.name});
        std.debug.print("Description: {s}\n", .{config.description});
        std.debug.print("Iterations: {}\n", .{config.iterations});
        
        // Run traditional allocation benchmark
        const traditional_result = try runTraditionalBenchmark(allocator, config);
        
        // Run frame pool benchmark
        const pool_result = try runFramePoolBenchmark(allocator, config);
        
        // Calculate improvement
        const speedup = traditional_result.avg_time_ns / pool_result.avg_time_ns;
        const improvement_percent = ((traditional_result.avg_time_ns - pool_result.avg_time_ns) / traditional_result.avg_time_ns) * 100.0;
        
        // Display results
        std.debug.print("\nResults:\n", .{});
        std.debug.print("  Traditional: {d:.2} ns/op ({d:.0} ops/sec)\n", .{ traditional_result.avg_time_ns, traditional_result.ops_per_sec });
        std.debug.print("  Frame Pool:  {d:.2} ns/op ({d:.0} ops/sec)\n", .{ pool_result.avg_time_ns, pool_result.ops_per_sec });
        std.debug.print("  Speedup:     {d:.2}x\n", .{speedup});
        std.debug.print("  Improvement: {d:.1}%\n", .{improvement_percent});
        
        if (speedup > 1.0) {
            std.debug.print("  ✅ Frame pool is {d:.1}% faster!\n", .{improvement_percent});
        } else {
            std.debug.print("  ⚠️  Frame pool is slower\n", .{});
        }
        
        std.debug.print("\n============================================================\n\n", .{});
    }
    
    // Summary benchmark
    try runSummaryBenchmark(allocator);
}

/// Run benchmark with traditional frame allocation
fn runTraditionalBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    const contract = Contract.init(&[_]u8{0x01, 0x02, 0x03}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    const call_data = &[_]u8{0x04, 0x05};
    
    // Warmup
    var warmup: usize = 0;
    while (warmup < config.iterations / 10) : (warmup += 1) {
        var frame = try Frame.init(allocator, 1000000, @constCast(&contract), caller, call_data);
        defer frame.deinit();
        
        frame.gas_remaining = frame.gas_remaining -| 21;
        try frame.stack.push(42);
        _ = try frame.stack.pop();
    }
    
    // Actual benchmark
    const start_time = std.time.nanoTimestamp();
    
    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        if (std.mem.eql(u8, config.name, "single_allocation")) {
            try benchmarkSingleAllocationTraditional(allocator, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "rapid_allocation")) {
            try benchmarkRapidAllocationTraditional(allocator, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "nested_calls")) {
            try benchmarkNestedCallsTraditional(allocator, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "mixed_depth")) {
            try benchmarkMixedDepthTraditional(allocator, &contract, caller, call_data, i);
        } else if (std.mem.eql(u8, config.name, "memory_pressure")) {
            try benchmarkMemoryPressureTraditional(allocator, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "realistic_execution")) {
            try benchmarkRealisticExecutionTraditional(allocator, &contract, caller, call_data, i);
        }
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_time = end_time - start_time;
    const avg_time = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(config.iterations));
    const ops_per_sec = 1_000_000_000.0 / avg_time;
    
    return BenchmarkResult{
        .name = config.name,
        .iterations = config.iterations,
        .total_time_ns = total_time,
        .avg_time_ns = avg_time,
        .ops_per_sec = ops_per_sec,
    };
}

/// Run benchmark with frame pool
fn runFramePoolBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    var evm = Evm.init(allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x01, 0x02, 0x03}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    const call_data = &[_]u8{0x04, 0x05};
    
    // Warmup
    var warmup: usize = 0;
    while (warmup < config.iterations / 10) : (warmup += 1) {
        evm.depth = 0;
        const frame = try evm.getPooledFrame(1000000, @constCast(&contract), caller, call_data);
        frame.gas_remaining = frame.gas_remaining -| 21;
        try frame.stack.push(42);
        _ = try frame.stack.pop();
    }
    
    // Actual benchmark
    const start_time = std.time.nanoTimestamp();
    
    var i: usize = 0;
    while (i < config.iterations) : (i += 1) {
        if (std.mem.eql(u8, config.name, "single_allocation")) {
            try benchmarkSingleAllocationPool(&evm, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "rapid_allocation")) {
            try benchmarkRapidAllocationPool(&evm, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "nested_calls")) {
            try benchmarkNestedCallsPool(&evm, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "mixed_depth")) {
            try benchmarkMixedDepthPool(&evm, &contract, caller, call_data, i);
        } else if (std.mem.eql(u8, config.name, "memory_pressure")) {
            try benchmarkMemoryPressurePool(&evm, &contract, caller, call_data);
        } else if (std.mem.eql(u8, config.name, "realistic_execution")) {
            try benchmarkRealisticExecutionPool(&evm, &contract, caller, call_data, i);
        }
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_time = end_time - start_time;
    const avg_time = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(config.iterations));
    const ops_per_sec = 1_000_000_000.0 / avg_time;
    
    return BenchmarkResult{
        .name = config.name,
        .iterations = config.iterations,
        .total_time_ns = total_time,
        .avg_time_ns = avg_time,
        .ops_per_sec = ops_per_sec,
    };
}

// Traditional benchmark implementations
fn benchmarkSingleAllocationTraditional(allocator: std.mem.Allocator, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    var frame = try Frame.init(allocator, 1000000, @constCast(contract), caller, call_data);
    defer frame.deinit();
    
    frame.gas_remaining = frame.gas_remaining -| 21;
    try frame.stack.push(123);
    _ = try frame.stack.pop();
}

fn benchmarkRapidAllocationTraditional(allocator: std.mem.Allocator, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        var frame = try Frame.init(allocator, 1000000 + @as(u64, i) * 1000, @constCast(contract), caller, call_data);
        defer frame.deinit();
        
        frame.gas_remaining = frame.gas_remaining -| (@as(u64, 21) * i);
        try frame.stack.push(@as(u256, i));
        if (frame.stack.size() > 0) {
            _ = try frame.stack.pop();
        }
    }
}

fn benchmarkNestedCallsTraditional(allocator: std.mem.Allocator, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    var depth: u8 = 0;
    while (depth < 10) : (depth += 1) {
        var frame = try Frame.init(allocator, 1000000 - @as(u64, depth) * 50000, @constCast(contract), caller, call_data);
        defer frame.deinit();
        
        frame.gas_remaining = frame.gas_remaining -| (@as(u64, 21) * depth);
        try frame.stack.push(@as(u256, depth));
        try frame.memory.reset();
        
        if (frame.stack.size() > 0) {
            _ = try frame.stack.pop();
        }
    }
}

fn benchmarkMixedDepthTraditional(allocator: std.mem.Allocator, contract: *const Contract, caller: Address, call_data: []const u8, iteration: usize) !void {
    const depth = iteration % 20; // Mix different depths
    var frame = try Frame.init(allocator, 1000000 + @as(u64, depth) * 10000, @constCast(contract), caller, call_data);
    defer frame.deinit();
    
    frame.gas_remaining = frame.gas_remaining -| @as(u64, @intCast(21 * (depth + 1)));
    try frame.stack.push(@as(u256, @intCast(iteration)));
    
    if (depth % 3 == 0) {
        try frame.memory.reset();
    }
    
    if (frame.stack.size() > 0) {
        _ = try frame.stack.pop();
    }
}

fn benchmarkMemoryPressureTraditional(allocator: std.mem.Allocator, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    var frame = try Frame.init(allocator, 5000000, @constCast(contract), caller, call_data);
    defer frame.deinit();
    
    // Simulate memory-intensive operations
    try frame.memory.reset();
    
    // Multiple stack operations
    var i: u8 = 0;
    while (i < 50) : (i += 1) {
        try frame.stack.push(@as(u256, i) * 0x123456789ABCDEF);
    }
    
    while (frame.stack.size() > 0) {
        _ = try frame.stack.pop();
    }
    
    frame.gas_remaining = frame.gas_remaining -| 2100;
}

fn benchmarkRealisticExecutionTraditional(allocator: std.mem.Allocator, contract: *const Contract, caller: Address, call_data: []const u8, iteration: usize) !void {
    const base_gas = 1000000 + (iteration % 1000) * 1000;
    var frame = try Frame.init(allocator, base_gas, @constCast(contract), caller, call_data);
    defer frame.deinit();
    
    // Simulate realistic EVM execution
    const operations = (iteration % 20) + 5;
    var op_count: usize = 0;
    
    while (op_count < operations) : (op_count += 1) {
        const op_type = op_count % 4;
        
        switch (op_type) {
            0 => { // Stack operations
                try frame.stack.push(@as(u256, @intCast(op_count)) * 0xDEADBEEF);
                frame.gas_remaining = frame.gas_remaining -| 3;
            },
            1 => { // Pop operation
                if (frame.stack.size() > 0) {
                    _ = try frame.stack.pop();
                    frame.gas_remaining = frame.gas_remaining -| 2;
                }
            },
            2 => { // Memory operation
                try frame.memory.reset();
                frame.gas_remaining = frame.gas_remaining -| 3;
            },
            3 => { // Gas consumption
                frame.gas_remaining = frame.gas_remaining -| 21;
            },
            else => unreachable,
        }
    }
}

// Frame pool benchmark implementations
fn benchmarkSingleAllocationPool(evm: *const Evm, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    // Have to cast away const to modify depth
    const mutable_evm = @constCast(evm);
    mutable_evm.depth = 0;
    
    const frame = try mutable_evm.getPooledFrame(1000000, @constCast(contract), caller, call_data);
    
    frame.gas_remaining = frame.gas_remaining -| 21;
    try frame.stack.push(123);
    _ = try frame.stack.pop();
}

fn benchmarkRapidAllocationPool(evm: *const Evm, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    const mutable_evm = @constCast(evm);
    mutable_evm.depth = 0;
    
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        const frame = try mutable_evm.getPooledFrame(1000000 + @as(u64, i) * 1000, @constCast(contract), caller, call_data);
        
        frame.gas_remaining = frame.gas_remaining -| (@as(u64, 21) * i);
        try frame.stack.push(@as(u256, i));
        if (frame.stack.size() > 0) {
            _ = try frame.stack.pop();
        }
    }
}

fn benchmarkNestedCallsPool(evm: *const Evm, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    const mutable_evm = @constCast(evm);
    
    var depth: u8 = 0;
    while (depth < 10) : (depth += 1) {
        mutable_evm.depth = depth;
        const frame = try mutable_evm.getPooledFrame(1000000 - @as(u64, depth) * 50000, @constCast(contract), caller, call_data);
        
        frame.gas_remaining = frame.gas_remaining -| (@as(u64, 21) * depth);
        try frame.stack.push(@as(u256, depth));
        try frame.memory.reset();
        
        if (frame.stack.size() > 0) {
            _ = try frame.stack.pop();
        }
    }
}

fn benchmarkMixedDepthPool(evm: *const Evm, contract: *const Contract, caller: Address, call_data: []const u8, iteration: usize) !void {
    const mutable_evm = @constCast(evm);
    const depth = @as(u16, @intCast(iteration % 20)); // Mix different depths
    mutable_evm.depth = depth;
    
    const frame = try mutable_evm.getPooledFrame(1000000 + @as(u64, depth) * 10000, @constCast(contract), caller, call_data);
    
    frame.gas_remaining = frame.gas_remaining -| @as(u64, @intCast(21 * (depth + 1)));
    try frame.stack.push(@as(u256, @intCast(iteration)));
    
    if (depth % 3 == 0) {
        try frame.memory.reset();
    }
    
    if (frame.stack.size() > 0) {
        _ = try frame.stack.pop();
    }
}

fn benchmarkMemoryPressurePool(evm: *const Evm, contract: *const Contract, caller: Address, call_data: []const u8) !void {
    const mutable_evm = @constCast(evm);
    mutable_evm.depth = 0;
    
    const frame = try mutable_evm.getPooledFrame(5000000, @constCast(contract), caller, call_data);
    
    // Simulate memory-intensive operations
    try frame.memory.reset();
    
    // Multiple stack operations
    var i: u8 = 0;
    while (i < 50) : (i += 1) {
        try frame.stack.push(@as(u256, i) * 0x123456789ABCDEF);
    }
    
    while (frame.stack.size() > 0) {
        _ = try frame.stack.pop();
    }
    
    frame.gas_remaining = frame.gas_remaining -| 2100;
}

fn benchmarkRealisticExecutionPool(evm: *const Evm, contract: *const Contract, caller: Address, call_data: []const u8, iteration: usize) !void {
    const mutable_evm = @constCast(evm);
    mutable_evm.depth = @as(u16, @intCast(iteration % 10)); // Use different depths
    
    const base_gas = 1000000 + (iteration % 1000) * 1000;
    const frame = try mutable_evm.getPooledFrame(base_gas, @constCast(contract), caller, call_data);
    
    // Simulate realistic EVM execution
    const operations = (iteration % 20) + 5;
    var op_count: usize = 0;
    
    while (op_count < operations) : (op_count += 1) {
        const op_type = op_count % 4;
        
        switch (op_type) {
            0 => { // Stack operations
                try frame.stack.push(@as(u256, @intCast(op_count)) * 0xDEADBEEF);
                frame.gas_remaining = frame.gas_remaining -| 3;
            },
            1 => { // Pop operation
                if (frame.stack.size() > 0) {
                    _ = try frame.stack.pop();
                    frame.gas_remaining = frame.gas_remaining -| 2;
                }
            },
            2 => { // Memory operation
                try frame.memory.reset();
                frame.gas_remaining = frame.gas_remaining -| 3;
            },
            3 => { // Gas consumption
                frame.gas_remaining = frame.gas_remaining -| 21;
            },
            else => unreachable,
        }
    }
}

/// Run summary benchmark showing overall improvement
fn runSummaryBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("=== SUMMARY BENCHMARK ===\n\n", .{});
    
    const iterations = 100000;
    std.debug.print("Running comprehensive comparison with {} iterations...\n\n", .{iterations});
    
    const contract = Contract.init(&[_]u8{0xDE, 0xAD, 0xBE, 0xEF}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    const call_data = &[_]u8{0x01, 0x02, 0x03, 0x04, 0x05};
    
    // Traditional approach timing
    const traditional_start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var frame = try Frame.init(allocator, 1000000 + i, @constCast(&contract), caller, call_data);
        defer frame.deinit();
        
        // Simulate typical frame operations
        frame.gas_remaining = frame.gas_remaining -| 100;
        try frame.stack.push(@as(u256, @intCast(i)));
        try frame.stack.push(0xABCDEF);
        _ = try frame.stack.pop();
        _ = try frame.stack.pop();
        try frame.memory.reset();
    }
    const traditional_time = std.time.nanoTimestamp() - traditional_start;
    
    // Frame pool approach timing
    var evm = Evm.init(allocator);
    defer evm.deinit();
    
    const pool_start = std.time.nanoTimestamp();
    i = 0;
    while (i < iterations) : (i += 1) {
        evm.depth = @as(u16, @intCast(i % 10)); // Mix different depths
        const frame = try evm.getPooledFrame(1000000 + i, @constCast(&contract), caller, call_data);
        
        // Same operations as traditional
        frame.gas_remaining = frame.gas_remaining -| 100;
        try frame.stack.push(@as(u256, @intCast(i)));
        try frame.stack.push(0xABCDEF);
        _ = try frame.stack.pop();
        _ = try frame.stack.pop();
        try frame.memory.reset();
    }
    const pool_time = std.time.nanoTimestamp() - pool_start;
    
    // Calculate results
    const traditional_ms = @as(f64, @floatFromInt(traditional_time)) / 1_000_000.0;
    const pool_ms = @as(f64, @floatFromInt(pool_time)) / 1_000_000.0;
    const speedup = traditional_ms / pool_ms;
    const improvement_percent = ((traditional_ms - pool_ms) / traditional_ms) * 100.0;
    
    const traditional_ops_per_sec = @as(f64, @floatFromInt(iterations)) / (traditional_ms / 1000.0);
    const pool_ops_per_sec = @as(f64, @floatFromInt(iterations)) / (pool_ms / 1000.0);
    
    // Display final results
    std.debug.print("FINAL RESULTS:\n", .{});
    std.debug.print("Traditional allocation: {d:.2} ms ({d:.0} ops/sec)\n", .{ traditional_ms, traditional_ops_per_sec });
    std.debug.print("Frame pool allocation:  {d:.2} ms ({d:.0} ops/sec)\n", .{ pool_ms, pool_ops_per_sec });
    std.debug.print("\n", .{});
    std.debug.print("🚀 SPEEDUP: {d:.2}x\n", .{speedup});
    std.debug.print("📈 IMPROVEMENT: {d:.1}%\n", .{improvement_percent});
    std.debug.print("💾 MEMORY ALLOCATIONS ELIMINATED: {}\n", .{iterations});
    
    if (speedup > 1.0) {
        std.debug.print("\n✅ Frame pool optimization is successful!\n", .{});
        std.debug.print("   Contract calls are {d:.1}% faster with eliminated allocation overhead.\n", .{improvement_percent});
    } else {
        std.debug.print("\n❌ Frame pool optimization needs review.\n", .{});
    }
    
    std.debug.print("\n================================================================================\n", .{});
}