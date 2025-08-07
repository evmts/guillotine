const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;
const benchmark_with_args = timing.benchmark_with_args;

// Import EVM components
const primitives = @import("primitives");
const Address = primitives.Address;
const U256 = u256;
const Memory = @import("evm").Memory;
const Stack = @import("evm").Stack;
const Frame = @import("evm").Frame;
const Contract = @import("evm").Contract;
const CodeAnalysis = @import("evm").CodeAnalysis;
const StoragePool = @import("evm").StoragePool;
const MemoryDatabase = @import("evm").MemoryDatabase;
const Vm = @import("evm").Vm;

/// Comprehensive frame management benchmarks
pub const FrameBenchmarks = struct {
    allocator: Allocator,
    storage_pool: StoragePool,
    sample_bytecode: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        const storage_pool = StoragePool.init(allocator);
        
        // Sample ERC-20 transfer bytecode (simplified)
        const bytecode = [_]u8{
            0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15,
            0x61, 0x00, 0x10, 0x57, 0x60, 0x00, 0x80, 0xfd,
            0x5b, 0x50, 0x60, 0x04, 0x36, 0x10, 0x61, 0x00,
            0x49, 0x57, 0x60, 0x00, 0x35, 0x60, 0xe0, 0x1c,
            0x80, 0x63, 0xa9, 0x05, 0x9c, 0xbb, 0x14, 0x61,
            0x00, 0x4e, 0x57, 0x80, 0x63, 0xdd, 0x62, 0xed,
            0x3e, 0x14, 0x61, 0x00, 0x86, 0x57, 0x5b, 0x60,
            0x00, 0x80, 0xfd, 0x5b, 0x34, 0x80, 0x15, 0x61,
        };
        
        return Self{
            .allocator = allocator,
            .storage_pool = storage_pool,
            .sample_bytecode = try allocator.dupe(u8, &bytecode),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sample_bytecode);
        self.storage_pool.deinit();
    }
    
    /// Benchmark frame creation and destruction
    pub fn frameLifecycle(self: *Self) !void {
        var memory_db = MemoryDatabase.init(self.allocator);
        defer memory_db.deinit();
        
        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(self.allocator, db_interface, null, null, null, 0, false, null);
        defer vm.deinit();
        
        var contract = Contract.init(
            Address.ZERO, // caller
            Address.ZERO, // address
            0,            // value
            1000000,      // gas
            self.sample_bytecode, // code
            [_]u8{0} ** 32,       // code_hash
            &.{},         // input
            false,        // is_static
        );
        
        // Create and destroy frame
        var frame = try Frame.init(
            self.allocator,
            &vm,
            &contract,
        );
        defer frame.deinit();
    }
    
    /// Benchmark frame with memory operations
    pub fn frameWithMemoryOps(self: *Self) !void {
        var memory_db = MemoryDatabase.init(self.allocator);
        defer memory_db.deinit();
        
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            self.sample_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
        
        var frame = try Frame.init(
            self.allocator,
            &contract,
        );
        defer frame.deinit();
        
        // Perform memory operations
        try frame.memory.set_u256(0, 42);
        try frame.memory.set_u256(32, 0x123456789ABCDEF);
        try frame.memory.set_data(64, "Hello, EVM!");
        
        _ = try frame.memory.get_u256(0);
        _ = try frame.memory.get_slice(64, 11);
    }
    
    /// Benchmark frame with stack operations
    pub fn frameWithStackOps(self: *Self) !void {
        var memory_db = MemoryDatabase.init(self.allocator);
        defer memory_db.deinit();
        
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            self.sample_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
        
        var frame = try Frame.init(
            self.allocator,
            &contract,
        );
        defer frame.deinit();
        
        // Perform stack operations
        try frame.stack.append(42);
        try frame.stack.append(0x123456789ABCDEF);
        try frame.stack.append(0xDEADBEEF);
        
        _ = try frame.stack.pop();
        _ = try frame.stack.peek();
        
        frame.stack.dup_unsafe(1);
        frame.stack.swap_unsafe(1);
    }
    
    /// Benchmark contract creation
    pub fn contractCreation(self: *Self) !void {
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            self.sample_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
    }
    
    /// Benchmark contract with storage operations
    pub fn contractWithStorage(self: *Self) !void {
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            self.sample_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
        
        // Simulate storage access patterns
        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            const key = @as(u256, @intCast(i));
            _ = try contract.mark_storage_slot_warm(self.allocator, key, null);
        }
    }
    
    /// Benchmark multiple frame creation (call stack simulation)
    pub fn multipleFrames(self: *Self) !void {
        var memory_db = MemoryDatabase.init(self.allocator);
        defer memory_db.deinit();
        
        var frames: [10]Frame = undefined;
        
        var i: usize = 0;
        while (i < frames.len) : (i += 1) {
            var contract = Contract.init(
                Address.ZERO,  // caller
                Address.ZERO,  // addr
                0,  // value
                1000000,  // gas
                self.sample_bytecode,  // code
                [_]u8{0} ** 32,  // code_hash
                &[_]u8{},  // input
                false,  // is_static
            );
            defer contract.deinit(self.allocator, &self.storage_pool);
            
            frames[i] = try Frame.init(
                self.allocator,
                &contract,
            );
        }
        
        // Cleanup
        for (&frames) |*frame| {
            frame.deinit();
        }
    }
    
    /// Benchmark large bytecode contract
    pub fn largeBytecodeContract(self: *Self) !void {
        // Create large bytecode (simulating complex contract)
        const large_bytecode = try self.allocator.alloc(u8, 10000);
        defer self.allocator.free(large_bytecode);
        
        // Fill with valid EVM opcodes
        for (large_bytecode, 0..) |*byte, idx| {
            byte.* = @as(u8, @intCast((idx % 256)));
        }
        
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            large_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
    }
    
    /// Benchmark storage pool efficiency
    pub fn storagePoolEfficiency(self: *Self) !void {
        var contracts: [5]Contract = undefined;
        
        var i: usize = 0;
        while (i < contracts.len) : (i += 1) {
            contracts[i] = Contract.init(
                Address.ZERO,  // caller
                Address.ZERO,  // addr
                0,  // value
                1000000,  // gas
                self.sample_bytecode,  // code
                [_]u8{0} ** 32,  // code_hash
                &[_]u8{},  // input
                false,  // is_static
            );
        }
        
        // Simulate storage operations
        for (&contracts) |*contract| {
            var j: u32 = 0;
            while (j < 5) : (j += 1) {
                const key = @as(u256, @intCast(j));
                _ = try contract.mark_storage_slot_warm(self.allocator, key, null);
            }
        }
        
        // Cleanup
        for (&contracts) |*contract| {
            contract.deinit(self.allocator, &self.storage_pool);
        }
    }
    
    /// Benchmark gas accounting overhead
    pub fn gasAccountingOverhead(self: *Self) !void {
        var memory_db = MemoryDatabase.init(self.allocator);
        defer memory_db.deinit();
        
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            self.sample_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
        
        var frame = try Frame.init(
            self.allocator,
            &contract,
        );
        defer frame.deinit();
        
        // Simulate gas accounting operations
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            frame.gas_remaining = frame.gas_remaining -| 21; // Base transaction cost
            if (frame.gas_remaining == 0) break;
        }
    }
    
    /// Baseline benchmark for frame allocation overhead (pre-optimization)
    /// This measures the current allocation/deallocation cost pattern
    /// that will be optimized with the frame pool implementation.
    pub fn frameAllocationBaseline(self: *Self) !void {
        var memory_db = MemoryDatabase.init(self.allocator);
        defer memory_db.deinit();
        
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            self.sample_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
        
        // Simulate nested calls with multiple frame allocations
        // This is the hot path that will be optimized
        var depth: usize = 0;
        while (depth < 10) : (depth += 1) {
            var frame = try Frame.init(
                self.allocator,
                &contract,
            );
            defer frame.deinit();
            
            // Simulate some frame operations
            try frame.stack.append(42 + depth);
            try frame.stack.append(depth * 2);
            _ = try frame.stack.pop();
            
            // Simulate memory allocation within frame
            _ = try frame.memory.ensure_context_capacity(32 * (depth + 1));
        }
    }
    
    /// Benchmark rapid frame allocation/deallocation cycles
    /// Simulates the allocation pressure during contract execution
    pub fn frameAllocationPressure(self: *Self) !void {
        var memory_db = MemoryDatabase.init(self.allocator);
        defer memory_db.deinit();
        
        var contract = Contract.init(
            Address.ZERO,  // caller
            Address.ZERO,  // addr
            0,  // value
            1000000,  // gas
            self.sample_bytecode,  // code
            [_]u8{0} ** 32,  // code_hash
            &[_]u8{},  // input
            false,  // is_static
        );
        defer contract.deinit(self.allocator, &self.storage_pool);
        
        // Rapid allocation/deallocation cycles
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var frame = try Frame.init(
                self.allocator,
                &contract,
            );
            defer frame.deinit();
            
            // Minimal operations to measure pure allocation overhead
            try frame.stack.append(@as(u256, @intCast(i)));
            _ = try frame.stack.pop();
        }
    }
};

/// Run all frame management benchmarks
pub fn runFrameBenchmarks(allocator: Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    var benchmarks = try FrameBenchmarks.init(allocator);
    defer benchmarks.deinit();
    
    std.debug.print("\n=== Frame Management Benchmarks ===\n", .{});
    
    // Frame lifecycle benchmarks
    const lifecycle_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "frame_lifecycle",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, FrameBenchmarks.frameLifecycle, .{&benchmarks});
    try suite.results.append(lifecycle_result);
    
    const memory_ops_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "frame_with_memory_ops",
        .iterations = 500,
        .warmup_iterations = 50,
    }, FrameBenchmarks.frameWithMemoryOps, .{&benchmarks});
    try suite.results.append(memory_ops_result);
    
    const stack_ops_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "frame_with_stack_ops",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, FrameBenchmarks.frameWithStackOps, .{&benchmarks});
    try suite.results.append(stack_ops_result);
    
    // Contract management benchmarks
    const contract_creation_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "contract_creation",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, FrameBenchmarks.contractCreation, .{&benchmarks});
    try suite.results.append(contract_creation_result);
    
    const contract_storage_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "contract_with_storage",
        .iterations = 500,
        .warmup_iterations = 50,
    }, FrameBenchmarks.contractWithStorage, .{&benchmarks});
    try suite.results.append(contract_storage_result);
    
    // Call stack benchmarks
    const multiple_frames_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "multiple_frames",
        .iterations = 100,
        .warmup_iterations = 10,
    }, FrameBenchmarks.multipleFrames, .{&benchmarks});
    try suite.results.append(multiple_frames_result);
    
    // Large contract benchmarks
    const large_bytecode_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "large_bytecode_contract",
        .iterations = 100,
        .warmup_iterations = 10,
    }, FrameBenchmarks.largeBytecodeContract, .{&benchmarks});
    try suite.results.append(large_bytecode_result);
    
    // Storage pool benchmarks
    const storage_pool_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "storage_pool_efficiency",
        .iterations = 200,
        .warmup_iterations = 20,
    }, FrameBenchmarks.storagePoolEfficiency, .{&benchmarks});
    try suite.results.append(storage_pool_result);
    
    // Gas accounting benchmarks
    const gas_accounting_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "gas_accounting_overhead",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, FrameBenchmarks.gasAccountingOverhead, .{&benchmarks});
    try suite.results.append(gas_accounting_result);
    
    // Frame allocation baseline benchmarks (pre-optimization)
    const frame_baseline_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "frame_allocation_baseline",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, FrameBenchmarks.frameAllocationBaseline, .{&benchmarks});
    try suite.results.append(frame_baseline_result);
    
    const frame_pressure_result = try benchmark_with_args(allocator, BenchmarkConfig{
        .name = "frame_allocation_pressure",
        .iterations = 1000, 
        .warmup_iterations = 100,
    }, FrameBenchmarks.frameAllocationPressure, .{&benchmarks});
    try suite.results.append(frame_pressure_result);
    
    std.debug.print("=== Frame Management Benchmarks Complete ===\n\n", .{});
}