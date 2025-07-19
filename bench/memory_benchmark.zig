const std = @import("std");
const Memory = @import("evm").Memory;
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

/// Memory benchmark state to reuse allocations
const MemoryBenchState = struct {
    allocator: std.mem.Allocator,
    memory: Memory,
    test_data: []u8,
    large_data: []u8,
    u256_values: []u256,
    random: std.Random,

    pub fn init(allocator: std.mem.Allocator) !MemoryBenchState {
        var memory = try Memory.init(allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
        
        // Allocate test data
        const test_data = try allocator.alloc(u8, 32);
        const large_data = try allocator.alloc(u8, 1024 * 1024); // 1MB
        const u256_values = try allocator.alloc(u256, 1000);
        
        // Initialize test data
        var prng = std.Random.DefaultPrng.init(12345);
        const random = prng.random();
        random.bytes(test_data);
        random.bytes(large_data);
        for (u256_values) |*val| {
            val.* = random.int(u256);
        }
        
        return MemoryBenchState{
            .allocator = allocator,
            .memory = memory,
            .test_data = test_data,
            .large_data = large_data,
            .u256_values = u256_values,
            .random = random,
        };
    }

    pub fn deinit(self: *MemoryBenchState) void {
        self.memory.deinit();
        self.allocator.free(self.test_data);
        self.allocator.free(self.large_data);
        self.allocator.free(self.u256_values);
    }
};

/// Benchmark memory allocation and expansion patterns
pub fn benchmarkMemoryAllocation(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    const AllocationBench = struct {
        fn initSmall() !void {
            const alloc = std.testing.allocator;
            var memory = try Memory.init(alloc, 1024, Memory.DEFAULT_MEMORY_LIMIT);
            defer memory.deinit();
        }

        fn initLarge() !void {
            const alloc = std.testing.allocator;
            var memory = try Memory.init(alloc, 1024 * 1024, Memory.DEFAULT_MEMORY_LIMIT);
            defer memory.deinit();
        }

        fn expansionLinear() !void {
            const alloc = std.testing.allocator;
            var memory = try Memory.init(alloc, 0, Memory.DEFAULT_MEMORY_LIMIT);
            defer memory.deinit();

            var i: usize = 0;
            while (i < 10) : (i += 1) {
                _ = try memory.ensure_context_capacity(i * 1024);
            }
        }

        fn expansionExponential() !void {
            const alloc = std.testing.allocator;
            var memory = try Memory.init(alloc, 0, Memory.DEFAULT_MEMORY_LIMIT);
            defer memory.deinit();

            var size: usize = 1;
            while (size < 1024 * 1024) : (size *= 2) {
                _ = try memory.ensure_context_capacity(size);
            }
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "memory_init_small",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, AllocationBench.initSmall);

    try suite.benchmark(BenchmarkConfig{
        .name = "memory_init_large",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, AllocationBench.initLarge);

    try suite.benchmark(BenchmarkConfig{
        .name = "memory_expansion_linear",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, AllocationBench.expansionLinear);

    try suite.benchmark(BenchmarkConfig{
        .name = "memory_expansion_exponential",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, AllocationBench.expansionExponential);

    suite.print_results();
}

/// Benchmark read operations with different access patterns
pub fn benchmarkReadOperations(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    var state = try MemoryBenchState.init(allocator);
    defer state.deinit();

    // Initialize memory with test data
    _ = try state.memory.ensure_context_capacity(1024 * 1024);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try state.memory.set_u256(i * 32, state.u256_values[i]);
    }

    const ReadBench = struct {
        fn readU256Sequential(mem: *Memory) !void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                _ = try mem.get_u256(j * 32);
            }
        }

        fn readU256Random(mem: *Memory, random: std.Random) !void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                const offset = random.intRangeAtMost(usize, 0, 900) * 32;
                _ = try mem.get_u256(offset);
            }
        }

        fn readSliceSmall(mem: *Memory) !void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                _ = try mem.get_slice(j * 32, 32);
            }
        }

        fn readSliceLarge(mem: *Memory) !void {
            var j: usize = 0;
            while (j < 10) : (j += 1) {
                _ = try mem.get_slice(j * 1024, 1024);
            }
        }

        fn readByteSequential(mem: *Memory) !void {
            var j: usize = 0;
            while (j < 1000) : (j += 1) {
                _ = try mem.get_byte(j);
            }
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "read_u256_sequential",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try ReadBench.readU256Sequential(&state.memory);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "read_u256_random",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try ReadBench.readU256Random(&state.memory, state.random);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "read_slice_small",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try ReadBench.readSliceSmall(&state.memory);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "read_slice_large",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn bench() !void {
            try ReadBench.readSliceLarge(&state.memory);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "read_byte_sequential",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn bench() !void {
            try ReadBench.readByteSequential(&state.memory);
        }
    }.bench);

    suite.print_results();
}

/// Benchmark write operations with different patterns
pub fn benchmarkWriteOperations(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    var state = try MemoryBenchState.init(allocator);
    defer state.deinit();

    const WriteBench = struct {
        fn writeU256Sequential(mem: *Memory, values: []u256) !void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                try mem.set_u256(j * 32, values[j % values.len]);
            }
        }

        fn writeU256Random(mem: *Memory, values: []u256, random: std.Random) !void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                const offset = random.intRangeAtMost(usize, 0, 900) * 32;
                try mem.set_u256(offset, values[j % values.len]);
            }
        }

        fn writeDataSmall(mem: *Memory, data: []const u8) !void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                try mem.set_data(j * 32, data);
            }
        }

        fn writeDataLarge(mem: *Memory, data: []const u8) !void {
            var j: usize = 0;
            while (j < 10) : (j += 1) {
                try mem.set_data(j * 65536, data[0..65536]);
            }
        }

        fn writeDataBounded(mem: *Memory, data: []const u8) !void {
            var j: usize = 0;
            while (j < 100) : (j += 1) {
                try mem.set_data_bounded(j * 32, data, j % 16, 32);
            }
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "write_u256_sequential",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn bench() !void {
            try WriteBench.writeU256Sequential(&state.memory, state.u256_values);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "write_u256_random",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn bench() !void {
            try WriteBench.writeU256Random(&state.memory, state.u256_values, state.random);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "write_data_small",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn bench() !void {
            try WriteBench.writeDataSmall(&state.memory, state.test_data);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "write_data_large",
        .iterations = 100,
        .warmup_iterations = 10,
    }, struct {
        fn bench() !void {
            try WriteBench.writeDataLarge(&state.memory, state.large_data);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "write_data_bounded",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn bench() !void {
            try WriteBench.writeDataBounded(&state.memory, state.test_data);
        }
    }.bench);

    suite.print_results();
}

/// Benchmark shared buffer architecture with child contexts
pub fn benchmarkSharedBuffer(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    const SharedBench = struct {
        fn childCreation(alloc: std.mem.Allocator) !void {
            var root = try Memory.init(alloc, 1024, Memory.DEFAULT_MEMORY_LIMIT);
            defer root.deinit();

            var children: [10]Memory = undefined;
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                children[i] = try root.init_child_memory(i * 100);
            }
        }

        fn childAccess(alloc: std.mem.Allocator) !void {
            var root = try Memory.init(alloc, 10240, Memory.DEFAULT_MEMORY_LIMIT);
            defer root.deinit();

            // Write data to root
            try root.set_u256(0, 0xDEADBEEF);
            try root.set_u256(1024, 0xCAFEBABE);

            var child1 = try root.init_child_memory(512);
            var child2 = try root.init_child_memory(1024);

            // Child contexts reading from shared buffer
            _ = try child1.get_u256(0);
            _ = try child2.get_u256(0);
            
            // Writing through child contexts
            try child1.set_u256(100, 0x12345678);
            try child2.set_u256(200, 0x87654321);
        }

        fn nestedContexts(alloc: std.mem.Allocator) !void {
            var root = try Memory.init(alloc, 1024, Memory.DEFAULT_MEMORY_LIMIT);
            defer root.deinit();

            var i: usize = 0;
            while (i < 5) : (i += 1) {
                var child = try root.init_child_memory(i * 200);
                try child.set_data(0, "nested context data");
                _ = try child.get_slice(0, 19);
            }
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "shared_buffer_child_creation",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try SharedBench.childCreation(allocator);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "shared_buffer_child_access",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try SharedBench.childAccess(allocator);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "shared_buffer_nested_contexts",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, struct {
        fn bench() !void {
            try SharedBench.nestedContexts(allocator);
        }
    }.bench);

    suite.print_results();
}

/// Benchmark memory patterns common in EVM execution
pub fn benchmarkEvmPatterns(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    var state = try MemoryBenchState.init(allocator);
    defer state.deinit();

    const EvmPatternBench = struct {
        fn codecopy(mem: *Memory, data: []const u8) !void {
            // Simulate CODECOPY operation
            try mem.set_data(0, data[0..@min(512, data.len)]);
        }

        fn calldatacopy(mem: *Memory, data: []const u8) !void {
            // Simulate CALLDATACOPY with offset
            try mem.set_data_bounded(64, data, 32, 256);
        }

        fn returndatacopy(mem: *Memory, data: []const u8) !void {
            // Simulate RETURNDATACOPY
            try mem.set_data(128, data[0..@min(128, data.len)]);
        }

        fn mloadMstore(mem: *Memory) !void {
            // Simulate common MLOAD/MSTORE pattern
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                const value = try mem.get_u256(i * 32);
                try mem.set_u256((i + 10) * 32, value);
            }
        }

        fn keccak256Pattern(mem: *Memory, data: []const u8) !void {
            // Simulate memory access for Keccak256
            try mem.set_data(0, data);
            _ = try mem.get_slice(0, data.len);
        }

        fn memoryExpansion(mem: *Memory) !void {
            // Simulate gradual memory expansion
            var offset: usize = 0;
            while (offset < 10000) : (offset += 1000) {
                try mem.set_u256(offset, 0xABCDEF);
            }
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "evm_pattern_codecopy",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try EvmPatternBench.codecopy(&state.memory, state.large_data);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "evm_pattern_calldatacopy",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try EvmPatternBench.calldatacopy(&state.memory, state.large_data);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "evm_pattern_returndatacopy",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try EvmPatternBench.returndatacopy(&state.memory, state.large_data);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "evm_pattern_mload_mstore",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, struct {
        fn bench() !void {
            try EvmPatternBench.mloadMstore(&state.memory);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "evm_pattern_keccak256",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, struct {
        fn bench() !void {
            try EvmPatternBench.keccak256Pattern(&state.memory, state.test_data);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "evm_pattern_memory_expansion",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn bench() !void {
            try EvmPatternBench.memoryExpansion(&state.memory);
        }
    }.bench);

    suite.print_results();
}

/// Benchmark edge cases and boundary conditions
pub fn benchmarkEdgeCases(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    const EdgeCaseBench = struct {
        fn zeroLengthOps(alloc: std.mem.Allocator) !void {
            var memory = try Memory.init(alloc, 1024, Memory.DEFAULT_MEMORY_LIMIT);
            defer memory.deinit();

            try memory.set_data(0, &[_]u8{});
            _ = try memory.get_slice(0, 0);
        }

        fn nearMemoryLimit(alloc: std.mem.Allocator) !void {
            const limit = 1024 * 1024; // 1MB limit for testing
            var memory = try Memory.init(alloc, 0, limit);
            defer memory.deinit();

            // Expand to near limit
            _ = try memory.ensure_context_capacity(limit - 100);
            try memory.set_data(limit - 100, "test");
        }

        fn alignmentPatterns(alloc: std.mem.Allocator) !void {
            var memory = try Memory.init(alloc, 1024, Memory.DEFAULT_MEMORY_LIMIT);
            defer memory.deinit();

            // Test various alignments
            const alignments = [_]usize{ 1, 7, 15, 31, 63, 127 };
            for (alignments) |align| {
                try memory.set_u256(align, 0x12345678);
                _ = try memory.get_u256(align);
            }
        }
    };

    try suite.benchmark(BenchmarkConfig{
        .name = "edge_case_zero_length",
        .iterations = 100000,
        .warmup_iterations = 10000,
    }, struct {
        fn bench() !void {
            try EdgeCaseBench.zeroLengthOps(allocator);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "edge_case_near_limit",
        .iterations = 100,
        .warmup_iterations = 10,
    }, struct {
        fn bench() !void {
            try EdgeCaseBench.nearMemoryLimit(allocator);
        }
    }.bench);

    try suite.benchmark(BenchmarkConfig{
        .name = "edge_case_alignment",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn bench() !void {
            try EdgeCaseBench.alignmentPatterns(allocator);
        }
    }.bench);

    suite.print_results();
}

/// Run all memory benchmarks
pub fn runAllMemoryBenchmarks(allocator: std.mem.Allocator) !void {
    std.log.info("=== Memory Subsystem Benchmarks ===", .{});
    
    std.log.info("\n--- Memory Allocation and Expansion ---", .{});
    try benchmarkMemoryAllocation(allocator);
    
    std.log.info("\n--- Read Operations ---", .{});
    try benchmarkReadOperations(allocator);
    
    std.log.info("\n--- Write Operations ---", .{});
    try benchmarkWriteOperations(allocator);
    
    std.log.info("\n--- Shared Buffer Architecture ---", .{});
    try benchmarkSharedBuffer(allocator);
    
    std.log.info("\n--- EVM Patterns ---", .{});
    try benchmarkEvmPatterns(allocator);
    
    std.log.info("\n--- Edge Cases ---", .{});
    try benchmarkEdgeCases(allocator);
}

test "memory benchmark smoke test" {
    const allocator = std.testing.allocator;
    
    // Just test that benchmarks compile and can run
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    try suite.benchmark(BenchmarkConfig{
        .name = "test_memory_init",
        .iterations = 1,
        .warmup_iterations = 0,
    }, struct {
        fn bench() !void {
            const alloc = std.testing.allocator;
            var memory = try Memory.init(alloc, 1024, Memory.DEFAULT_MEMORY_LIMIT);
            defer memory.deinit();
        }
    }.bench);
}