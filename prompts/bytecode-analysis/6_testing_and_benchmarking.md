# Task 6: Comprehensive Testing and Benchmarking

<context>
You are validating the complete block-based execution implementation. All components are built - now we need to ensure correctness and measure performance improvement.

<prerequisites>
- Tasks 1-5 completed: Full block-based execution implemented
- Understanding of EVM edge cases and attack vectors
- Access to real-world contract bytecode for testing
</prerequisites>

<goals>
1. Verify correctness with extensive testing
2. Measure performance improvement (target: 20-30%)
3. Validate memory usage is acceptable
4. Ensure no security vulnerabilities

EVMOne insights:
- Their test suite covers ~10,000 edge cases
- Performance varies by contract type (20-100% improvement)
- Memory overhead is typically 2-4% of bytecode size
- Cache misses reduced by 30-50% with block execution
</goals>
</context>

<task>
<objective>
Create comprehensive test suite and benchmarks to validate the block-based execution implementation.
</objective>

<test_categories>
<correctness_tests>
Create `test/evm/block_execution_test.zig`:
```zig
const std = @import("std");
const testing = std.testing;
const Vm = @import("evm");

test "block execution matches traditional execution - arithmetic" {
    const test_cases = [_][]const u8{
        // Simple arithmetic
        &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x00 }, // 3 + 5
        // Complex arithmetic with multiple operations
        &[_]u8{ 
            0x60, 0x0a,  // PUSH1 10
            0x60, 0x05,  // PUSH1 5
            0x01,        // ADD
            0x60, 0x03,  // PUSH1 3
            0x02,        // MUL
            0x00         // STOP
        },
        // Edge case: division by zero
        &[_]u8{ 0x60, 0x05, 0x60, 0x00, 0x04, 0x00 }, // 5 / 0 = 0
    };
    
    // Debug assertion: ensure both VMs initialized correctly
    std.debug.assert(std.testing.allocator.ptr != null);
    
    for (test_cases) |code| {
        // Traditional execution
        var vm_traditional = try Vm.init(allocator, db);
        vm_traditional.use_block_validation = false;
        const trad_result = try vm_traditional.interpret(code, &.{});
        
        // Block-based execution
        var vm_block = try Vm.init(allocator, db);
        vm_block.use_block_validation = true;
        const block_result = try vm_block.interpret(code, &.{});
        
        // Results must match exactly
        try testing.expectEqual(trad_result.gas_used, block_result.gas_used);
        try testing.expectEqual(trad_result.status, block_result.status);
        if (trad_result.output) |t_out| {
            try testing.expectEqualSlices(u8, t_out, block_result.output.?);
        }
    }
}

test "block boundaries are correct" {
    // Contract with multiple blocks
    const code = &[_]u8{
        0x60, 0x08,  // PUSH1 8
        0x56,        // JUMP
        0x60, 0x05,  // PUSH1 5 (unreachable)
        0x00,        // STOP (unreachable)
        0x5b,        // JUMPDEST (pc=8)
        0x60, 0x03,  // PUSH1 3
        0x01,        // ADD
        0x00,        // STOP
    };
    
    // Debug: log block analysis results
    test {
        std.testing.log_level = .debug;
    }
    
    const analysis = try Contract.analyze_code(allocator, code, hash);
    defer analysis.deinit(allocator);
    
    // Should have 3 blocks
    try testing.expectEqual(@as(u16, 3), analysis.block_count);
    
    // Block 0: PUSH1 8, JUMP
    try testing.expect(analysis.block_starts.isSetUnchecked(0));
    try testing.expectEqual(@as(u32, 3 + 8), analysis.block_metadata[0].gas_cost);
    
    // Block 1: PUSH1 5, STOP (unreachable but still a block)
    try testing.expect(analysis.block_starts.isSetUnchecked(3));
    
    // Block 2: JUMPDEST, PUSH1 3, ADD, STOP
    try testing.expect(analysis.block_starts.isSetUnchecked(8));
}

test "stack validation per block" {
    // Block that requires items on stack
    const code = &[_]u8{
        0x5b,  // JUMPDEST (new block)
        0x01,  // ADD (needs 2 items)
        0x00,  // STOP
    };
    
    var vm = try Vm.init(allocator, db);
    vm.use_block_validation = true;
    
    // Should fail - ADD needs 2 items
    const result = vm.interpret(code, &.{});
    try testing.expectError(error.StackUnderflow, result);
}

test "gas validation per block" {
    const code = &[_]u8{
        0x60, 0x05,  // PUSH1 5 (3 gas)
        0x60, 0x03,  // PUSH1 3 (3 gas)
        0x01,        // ADD (3 gas)
        0x00,        // STOP (0 gas)
    };
    
    var vm = try Vm.init(allocator, db);
    vm.use_block_validation = true;
    
    var contract = Contract.init(code);
    contract.gas = 8; // Not enough for full block (needs 9)
    
    const result = vm.interpret(&contract, &.{});
    try testing.expectError(error.OutOfGas, result);
}
```
</correctness_tests>

<edge_case_tests>
```zig
test "GAS opcode returns correct value" {
    const code = &[_]u8{
        0x60, 0x05,  // PUSH1 5
        0x5a,        // GAS
        0x00,        // STOP
    };
    
    var vm = try Vm.init(allocator, db);
    vm.use_block_validation = true;
    
    var contract = Contract.init(code);
    contract.gas = 100000;
    
    const result = try vm.interpret(&contract, &.{});
    
    // GAS should account for opcodes executed so far
    const gas_on_stack = frame.stack.items[0];
    try testing.expect(gas_on_stack < 100000);
    try testing.expect(gas_on_stack > 99000); // Reasonable range
}

test "dynamic jumps work correctly" {
    const code = &[_]u8{
        0x60, 0x00,  // PUSH1 0
        0x60, 0x08,  // PUSH1 8
        0x57,        // JUMPI (conditional, won't jump)
        0x60, 0x0a,  // PUSH1 10
        0x56,        // JUMP
        0x5b,        // JUMPDEST (pc=8, unreachable)
        0x00,        // STOP
        0x5b,        // JUMPDEST (pc=10)
        0x00,        // STOP
    };
    
    var vm = try Vm.init(allocator, db);
    vm.use_block_validation = true;
    
    const result = try vm.interpret(code, &.{});
    try testing.expectEqual(RunStatus.Success, result.status);
}

test "memory operations still expand memory" {
    const code = &[_]u8{
        0x60, 0x42,              // PUSH1 0x42
        0x60, 0x00, 0x00, 0x00,  // PUSH3 0x100000 (large offset)
        0x52,                    // MSTORE
        0x59,                    // MSIZE
        0x00,                    // STOP
    };
    
    var vm = try Vm.init(allocator, db);
    vm.use_block_validation = true;
    
    const result = vm.interpret(code, &.{});
    // Should fail with out of memory (offset too large)
    try testing.expectError(error.OutOfMemory, result);
}
```
</edge_case_tests>

<attack_vector_tests>
```zig
test "malicious code cannot bypass block validation" {
    // Attempt to create invalid block structure
    const code = &[_]u8{
        0x5b,  // JUMPDEST
        0x5b,  // JUMPDEST (consecutive)
        0x5b,  // JUMPDEST (consecutive)
        0x01,  // ADD (needs items)
        0x00,  // STOP
    };
    
    // Debug assertions for security
    const analysis = try Contract.analyze_code(allocator, code, hash);
    defer analysis.deinit(allocator);
    std.debug.assert(analysis.block_count >= 3); // Each JUMPDEST creates block
    
    var vm = try Vm.init(allocator, db);
    vm.use_block_validation = true;
    
    // Should still validate correctly
    const result = vm.interpret(code, &.{});
    try testing.expectError(error.StackUnderflow, result);
}

test "pathological case - many small blocks" {
    // Generate code with alternating JUMPDEST/STOP
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    const block_count = 1000;
    for (0..block_count) |_| {
        try code.appendSlice(&[_]u8{ 0x5b, 0x00 }); // JUMPDEST, STOP
    }
    
    var vm = try Vm.init(allocator, db);
    vm.use_block_validation = true;
    
    // Should handle many blocks efficiently
    const start = std.time.nanoTimestamp();
    _ = try vm.interpret(code.items, &.{});
    const elapsed = std.time.nanoTimestamp() - start;
    
    // Should complete quickly even with many blocks
    try testing.expect(elapsed < 1_000_000); // < 1ms
    
    // Memory best practice: verify no leaks
    const analysis = contract.analysis.?;
    try testing.expectEqual(block_count, analysis.block_count);
}
```
</attack_vector_tests>
</test_categories>

<benchmarking>
Create `bench/block_execution_bench.zig`:
```zig
const REAL_CONTRACTS = .{
    .{ "ERC20", @embedFile("contracts/USDT.bin") },
    .{ "Uniswap", @embedFile("contracts/UniswapV2Router.bin") },
    .{ "CryptoKitties", @embedFile("contracts/CryptoKitties.bin") },
    .{ "1inch", @embedFile("contracts/1inchAggregator.bin") },
};

pub fn benchmarkBlockExecution() !void {
    const iterations = 10000;
    
    var results = std.ArrayList(BenchResult).init(allocator);
    defer results.deinit();
    
    // Memory best practice: pre-allocate result capacity
    try results.ensureUnusedCapacity(REAL_CONTRACTS.len);
    
    inline for (REAL_CONTRACTS) |contract_info| {
        const name = contract_info[0];
        const bytecode = contract_info[1];
        
        // Traditional execution
        var vm_trad = try Vm.init(allocator, db);
        vm_trad.use_block_validation = false;
        
        const trad_start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            _ = try vm_trad.interpret(bytecode, typical_input);
        }
        const trad_time = std.time.nanoTimestamp() - trad_start;
        
        // Block-based execution
        var vm_block = try Vm.init(allocator, db);
        vm_block.use_block_validation = true;
        
        const block_start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            _ = try vm_block.interpret(bytecode, typical_input);
        }
        const block_time = std.time.nanoTimestamp() - block_start;
        
        const improvement = (trad_time - block_time) * 100 / trad_time;
        
        // Debug assertion: block should never be slower
        std.debug.assert(block_time <= trad_time);
        
        try results.append(.{
            .name = name,
            .trad_ns = trad_time / iterations,
            .block_ns = block_time / iterations,
            .improvement_pct = improvement,
        });
    }
    
    // Print results table
    print("Contract         | Traditional | Block-Based | Improvement\n", .{});
    print("-----------------|-------------|-------------|------------\n", .{});
    for (results.items) |r| {
        print("{s:<16} | {d:>9}ns | {d:>9}ns | {d:>9.1}%\n", .{
            r.name, r.trad_ns, r.block_ns, r.improvement_pct
        });
    }
}

// CPU performance counter analysis
pub fn profileCacheBehavior() !void {
    if (builtin.os.tag != .linux) return;
    
    // Use perf_event_open to measure cache misses
    const events = [_]PerfEvent{
        .{ .type = PERF_TYPE_HARDWARE, .config = PERF_COUNT_HW_CACHE_MISSES },
        .{ .type = PERF_TYPE_HARDWARE, .config = PERF_COUNT_HW_BRANCH_MISSES },
        .{ .type = PERF_TYPE_HARDWARE, .config = PERF_COUNT_HW_CPU_CYCLES },
        .{ .type = PERF_TYPE_HARDWARE, .config = PERF_COUNT_HW_INSTRUCTIONS },
    };
    
    // Profile both execution modes
    var trad_counters = PerfCounters{};
    var block_counters = PerfCounters{};
    
    // Traditional execution
    startPerfCounters(&trad_counters);
    _ = try vm_traditional.interpret(code, input);
    stopPerfCounters(&trad_counters);
    
    // Block execution
    startPerfCounters(&block_counters);
    _ = try vm_block.interpret(code, input);
    stopPerfCounters(&block_counters);
    
    // Report improvements
    const cache_improvement = (trad_counters.cache_misses - block_counters.cache_misses) * 100 / trad_counters.cache_misses;
    const branch_improvement = (trad_counters.branch_misses - block_counters.branch_misses) * 100 / trad_counters.branch_misses;
    
    std.debug.print("Cache miss reduction: {}%\n", .{cache_improvement});
    std.debug.print("Branch miss reduction: {}%\n", .{branch_improvement});
}
```
</benchmarking>

<memory_analysis>
```zig
test "memory overhead is acceptable" {
    const contracts = [_][]const u8{
        @embedFile("contracts/small.bin"),   // 100 bytes
        @embedFile("contracts/medium.bin"),  // 10KB
        @embedFile("contracts/large.bin"),   // 24KB (max size)
    };
    
    // Track peak memory usage
    var peak_overhead_pct: f64 = 0;
    
    for (contracts) |bytecode| {
        const analysis = try analyze_code(allocator, bytecode, hash);
        defer analysis.deinit(allocator);
        
        const overhead = blk: {
            var total: usize = 0;
            total += analysis.block_metadata.len * @sizeOf(BlockMetadata);
            total += analysis.pc_to_block.len * @sizeOf(u16);
            total += analysis.block_starts.bits.len * @sizeOf(u64);
            break :blk total;
        };
        
        const overhead_pct = @intToFloat(f64, overhead * 100) / @intToFloat(f64, bytecode.len);
        peak_overhead_pct = @max(peak_overhead_pct, overhead_pct);
        
        // Overhead should be < 5% of bytecode size
        try testing.expect(overhead_pct < 5);
        
        // Debug assertion for memory safety
        std.debug.assert(analysis.block_metadata.len <= bytecode.len); // Can't have more blocks than bytes
        
        print("Code size: {} bytes, overhead: {} bytes ({d:.1}%)\n", 
              .{ bytecode.len, overhead, overhead_pct });
    }
}
```
</memory_analysis>

<integration_tests>
```zig
test "ethereum test suite compatibility" {
    // Run official Ethereum tests with block validation
    const test_dir = "tests/GeneralStateTests/";
    
    var dir = try std.fs.cwd().openIterableDir(test_dir, .{});
    defer dir.close();
    
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        
        const test_json = try std.fs.cwd().readFileAlloc(
            allocator, 
            try std.fs.path.join(allocator, &.{ test_dir, entry.name }),
            10 * 1024 * 1024
        );
        defer allocator.free(test_json);
        
        const test_case = try std.json.parse(TestCase, &std.json.TokenStream.init(test_json));
        
        // Run with block validation
        var vm = try Vm.init(allocator, db);
        vm.use_block_validation = true;
        
        const result = try runStateTest(&vm, test_case);
        try testing.expect(result.passed);
    }
}
```
</integration_tests>

<zbench_integration>
Add comprehensive zbench suite:
```zig
const zbench = @import("zbench");

pub fn main() !void {
    var bench = zbench.Benchmark.init(std.testing.allocator, .{});
    defer bench.deinit();
    
    // Register all benchmarks
    try bench.add("Block Analysis", benchmarkBlockAnalysis, .{});
    try bench.add("Block Execution - Small", benchmarkSmallContract, .{});
    try bench.add("Block Execution - Medium", benchmarkMediumContract, .{});
    try bench.add("Block Execution - Large", benchmarkLargeContract, .{});
    try bench.add("Unsafe Operations", benchmarkUnsafeOps, .{});
    try bench.add("Jump Validation", benchmarkJumpValidation, .{});
    try bench.add("Memory Expansion", benchmarkMemoryOps, .{});
    
    // Run benchmarks
    try bench.run(std.io.getStdOut().writer());
}

fn benchmarkSmallContract(b: *zbench.Benchmark) void {
    const code = @embedFile("contracts/small_loops.bin");
    benchmarkContract(b, code);
}

fn benchmarkContract(b: *zbench.Benchmark, code: []const u8) void {
    const allocator = std.testing.allocator;
    
    var vm_trad = Vm.init(allocator, ...) catch unreachable;
    defer vm_trad.deinit();
    vm_trad.use_block_validation = false;
    
    var vm_block = Vm.init(allocator, ...) catch unreachable;
    defer vm_block.deinit();
    vm_block.use_block_validation = true;
    
    // Warm up caches
    _ = vm_trad.interpret(code, &.{}, false) catch {};
    _ = vm_block.interpret(code, &.{}, false) catch {};
    
    // Measure
    const trad_start = std.time.nanoTimestamp();
    b.run(for (0..b.iterations) |_| {
        _ = vm_trad.interpret(code, &.{}, false) catch unreachable;
    });
    const trad_time = std.time.nanoTimestamp() - trad_start;
    
    const block_start = std.time.nanoTimestamp();
    b.run(for (0..b.iterations) |_| {
        _ = vm_block.interpret(code, &.{}, false) catch unreachable;
    });
    const block_time = std.time.nanoTimestamp() - block_start;
    
    const speedup = @intToFloat(f64, trad_time) / @intToFloat(f64, block_time);
    std.debug.print("Speedup: {d:.2}x\n", .{speedup});
}
```
</zbench_integration>

<memory_best_practices>
1. **Pre-allocate test data**: Avoid allocations during benchmarks
2. **Verify no leaks**: Check all allocations are freed
3. **Monitor peak usage**: Track maximum memory overhead
4. **Cache warming**: Run once before measuring to fill caches
5. **Consistent state**: Reset VM state between iterations
</memory_best_practices>

<debug_assertions>
Add throughout test code:
```zig
// Verify block analysis invariants
std.debug.assert(analysis.block_count > 0 or code.len == 0);
std.debug.assert(analysis.block_metadata.len == analysis.block_count);
std.debug.assert(analysis.pc_to_block.len == code.len);

// Verify execution invariants
std.debug.assert(frame.current_block_idx < analysis.block_count);
std.debug.assert(frame.stack.size <= 1024);
std.debug.assert(frame.gas_remaining <= initial_gas);

// Verify memory safety
std.debug.assert(frame.memory.size <= memory_limits.MAX_MEMORY_SIZE);
```
</debug_assertions>
</task>

<validation_checklist>
- [ ] All arithmetic operations produce correct results
- [ ] Control flow (JUMP/JUMPI) works correctly
- [ ] Stack validation catches underflow/overflow
- [ ] Gas validation prevents infinite loops
- [ ] Memory operations still check bounds
- [ ] State operations handle errors correctly
- [ ] Edge cases are handled properly
- [ ] No security vulnerabilities introduced
- [ ] Performance improvement meets 20-30% target
- [ ] Memory overhead is < 5% of bytecode size
- [ ] All Ethereum tests pass
- [ ] Real-world contracts execute correctly
</validation_checklist>

<success_metrics>
1. **Correctness**: 100% of tests pass
2. **Performance**: 20-30% improvement on real contracts
3. **Memory**: < 5% overhead
4. **Cache**: Reduced cache misses
5. **Branches**: Improved branch prediction (>90%)
</success_metrics>

<rollout_plan>
1. Feature flag to enable/disable block mode
2. A/B testing in development environment
3. Gradual rollout with monitoring
4. Full deployment after validation
</rollout_plan>