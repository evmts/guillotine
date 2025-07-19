const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

// Import frame-related modules
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const Memory = Evm.Memory;
const Stack = Evm.Stack;
const CodeAnalysis = Evm.CodeAnalysis;
const StoragePool = Evm.StoragePool;

// =============================================================================
// Frame Lifecycle Benchmarks
// =============================================================================

/// Benchmark Frame.init with minimal configuration
pub fn bench_frame_init_minimal(allocator: Allocator) void {
    // Create a minimal contract
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var frame = Frame.init(allocator, &contract) catch unreachable;
        frame.deinit();
    }
}

/// Benchmark Frame.init with typical smart contract configuration
pub fn bench_frame_init_typical(allocator: Allocator) void {
    // Create a contract with typical bytecode size (1KB)
    var bytecode: [1024]u8 = undefined;
    @memset(&bytecode, 0x60); // PUSH1 opcodes
    
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        1000000,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &[_]u8{0x12, 0x34, 0x56, 0x78}, // Some calldata
        false,
    );
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var frame = Frame.init(allocator, &contract) catch unreachable;
        frame.deinit();
    }
}

/// Benchmark Frame.init_with_state for child frames
pub fn bench_frame_init_child(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var frame = Frame.init_with_state(
            allocator,
            &contract,
            null,
            null,
            null,
            null,
            null,
            null,
            500000, // Half gas for child
            false,
            &[_]u8{0x01, 0x02, 0x03, 0x04},
            5, // Depth 5
            null,
            null,
        ) catch unreachable;
        frame.deinit();
    }
}

/// Benchmark frame cleanup overhead
pub fn bench_frame_deinit_simple(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    // Pre-create frames
    var frames: [100]Frame = undefined;
    for (&frames) |*frame| {
        frame.* = Frame.init(allocator, &contract) catch unreachable;
    }
    
    // Benchmark deinit
    for (&frames) |*frame| {
        frame.deinit();
    }
}

/// Benchmark frame with expanded memory cleanup
pub fn bench_frame_deinit_with_memory(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    // Pre-create frames with memory expansion
    var frames: [100]Frame = undefined;
    for (&frames) |*frame| {
        frame.* = Frame.init(allocator, &contract) catch unreachable;
        _ = frame.memory.ensure_capacity(4096) catch unreachable;
    }
    
    // Benchmark deinit with memory cleanup
    for (&frames) |*frame| {
        frame.deinit();
    }
}

/// Benchmark gas consumption in hot path
pub fn bench_consume_gas_success(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    var frame = Frame.init(allocator, &contract) catch unreachable;
    defer frame.deinit();
    frame.gas_remaining = 1000000;
    
    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        frame.consume_gas(3) catch unreachable; // PUSH operation cost
    }
}

/// Benchmark gas consumption failure path
pub fn bench_consume_gas_failure(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    var frame = Frame.init(allocator, &contract) catch unreachable;
    defer frame.deinit();
    frame.gas_remaining = 100;
    
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        _ = frame.consume_gas(200) catch {}; // Will fail
        frame.gas_remaining = 100; // Reset for next iteration
    }
}

// =============================================================================
// Contract Management Benchmarks
// =============================================================================

/// Benchmark Contract.init with small bytecode
pub fn bench_contract_init_small(allocator: Allocator) void {
    const bytecode = [_]u8{0x60, 0x40, 0x60, 0x00, 0x52}; // PUSH1 64 PUSH1 0 MSTORE
    
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var contract = Contract.init(
            primitives.Address.zero(),
            primitives.Address.zero(),
            0,
            1000000,
            &bytecode,
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        contract.deinit(allocator, null);
    }
}

/// Benchmark Contract.init with typical contract size (5KB)
pub fn bench_contract_init_typical(allocator: Allocator) void {
    var bytecode: [5120]u8 = undefined;
    // Fill with realistic pattern - mix of opcodes
    var i: usize = 0;
    while (i < bytecode.len) : (i += 1) {
        bytecode[i] = switch (i % 10) {
            0 => 0x60, // PUSH1
            1 => @intCast(i & 0xFF),
            2 => 0x52, // MSTORE
            3 => 0x51, // MLOAD
            4 => 0x01, // ADD
            5 => 0x02, // MUL
            6 => 0x56, // JUMP
            7 => 0x5B, // JUMPDEST
            8 => 0x57, // JUMPI
            else => 0x00, // STOP
        };
    }
    
    i = 0;
    while (i < 1000) : (i += 1) {
        var contract = Contract.init(
            primitives.Address.zero(),
            primitives.Address.zero(),
            0,
            1000000,
            &bytecode,
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        contract.deinit(allocator, null);
    }
}

/// Benchmark Contract.init with large bytecode (24KB - max contract size)
pub fn bench_contract_init_large(allocator: Allocator) void {
    var bytecode: [24576]u8 = undefined;
    @memset(&bytecode, 0x5B); // Fill with JUMPDEST
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var contract = Contract.init(
            primitives.Address.zero(),
            primitives.Address.zero(),
            0,
            1000000,
            &bytecode,
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        contract.deinit(allocator, null);
    }
}

/// Benchmark Contract.init_deployment
pub fn bench_contract_init_deployment(allocator: Allocator) void {
    const init_code = [_]u8{0x60, 0x80, 0x60, 0x40, 0x52}; // Constructor bytecode
    
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var contract = Contract.init_deployment(
            primitives.Address.zero(),
            1000000, // 1 ETH initial balance
            1000000,
            &init_code,
            null, // CREATE
        );
        contract.deinit(allocator, null);
    }
}

/// Benchmark Contract.init_deployment with CREATE2
pub fn bench_contract_init_deployment_create2(allocator: Allocator) void {
    const init_code = [_]u8{0x60, 0x80, 0x60, 0x40, 0x52};
    const salt = [_]u8{0x42} ** 32;
    
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var contract = Contract.init_deployment(
            primitives.Address.zero(),
            1000000,
            1000000,
            &init_code,
            salt, // CREATE2 with salt
        );
        contract.deinit(allocator, null);
    }
}

/// Benchmark contract cleanup with storage maps
pub fn bench_contract_deinit_with_storage(allocator: Allocator) void {
    // Create contracts with storage access
    var contracts: [100]Contract = undefined;
    for (&contracts) |*contract| {
        contract.* = Contract.init(
            primitives.Address.zero(),
            primitives.Address.zero(),
            0,
            1000000,
            &[_]u8{},
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
        // Simulate storage access
        _ = contract.mark_storage_slot_warm(allocator, 0x100, null) catch unreachable;
        _ = contract.mark_storage_slot_warm(allocator, 0x200, null) catch unreachable;
        _ = contract.mark_storage_slot_warm(allocator, 0x300, null) catch unreachable;
    }
    
    // Benchmark cleanup
    for (&contracts) |*contract| {
        contract.deinit(allocator, null);
    }
}

// =============================================================================
// Code Analysis Benchmarks
// =============================================================================

/// Benchmark JUMPDEST validation for code without jumps
pub fn bench_valid_jumpdest_no_jumps(allocator: Allocator) void {
    const bytecode = [_]u8{0x60, 0x40, 0x60, 0x00, 0x52}; // No JUMPDEST
    
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        const valid = contract.valid_jumpdest(allocator, 2);
        _ = valid;
    }
}

/// Benchmark JUMPDEST validation with many jump destinations
pub fn bench_valid_jumpdest_many(allocator: Allocator) void {
    var bytecode: [1024]u8 = undefined;
    // Create pattern with many JUMPDESTs
    var i: usize = 0;
    while (i < bytecode.len) : (i += 2) {
        bytecode[i] = 0x5B; // JUMPDEST
        bytecode[i + 1] = 0x00; // STOP
    }
    
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &bytecode,
        [_]u8{1} ** 32, // Different hash to avoid cache
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Force analysis
    contract.analyze_jumpdests(allocator);
    
    // Benchmark binary search
    i = 0;
    while (i < 10000) : (i += 1) {
        const valid = contract.valid_jumpdest(allocator, 512); // Middle position
        _ = valid;
    }
}

/// Benchmark code analysis for typical contract
pub fn bench_analyze_code_typical(allocator: Allocator) void {
    var bytecode: [2048]u8 = undefined;
    // Create realistic bytecode pattern
    var i: usize = 0;
    while (i < bytecode.len) {
        switch (i % 20) {
            0 => {
                bytecode[i] = 0x60; // PUSH1
                if (i + 1 < bytecode.len) {
                    bytecode[i + 1] = @intCast((i + 1) & 0xFF);
                    i += 2;
                } else {
                    i += 1;
                }
            },
            5 => {
                bytecode[i] = 0x5B; // JUMPDEST
                i += 1;
            },
            10 => {
                bytecode[i] = 0x56; // JUMP
                i += 1;
            },
            15 => {
                bytecode[i] = 0x57; // JUMPI
                i += 1;
            },
            else => {
                bytecode[i] = 0x01; // ADD
                i += 1;
            },
        }
    }
    
    // Clear cache to force re-analysis
    Contract.clear_analysis_cache(allocator);
    
    i = 0;
    while (i < 10) : (i += 1) {
        // Use different hash each time to avoid cache
        const hash = [_]u8{@intCast(i)} ** 32;
        _ = Contract.analyze_code(allocator, &bytecode, hash) catch unreachable;
    }
    
    Contract.clear_analysis_cache(allocator);
}

/// Benchmark analysis cache hit performance
pub fn bench_analyze_code_cached(allocator: Allocator) void {
    const bytecode = [_]u8{0x60, 0x40, 0x5B, 0x60, 0x00, 0x52};
    const hash = [_]u8{0x42} ** 32;
    
    // First call populates cache
    _ = Contract.analyze_code(allocator, &bytecode, hash) catch unreachable;
    
    // Benchmark cache hits
    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        _ = Contract.analyze_code(allocator, &bytecode, hash) catch unreachable;
    }
    
    Contract.clear_analysis_cache(allocator);
}

// =============================================================================
// Storage Operations Benchmarks
// =============================================================================

/// Benchmark cold storage slot access
pub fn bench_storage_cold_access(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const slot = @as(u256, i) << 128; // Spread out slots
        const was_cold = contract.mark_storage_slot_warm(allocator, slot, null) catch unreachable;
        _ = was_cold;
    }
}

/// Benchmark warm storage slot access
pub fn bench_storage_warm_access(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Warm up some slots
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = contract.mark_storage_slot_warm(allocator, i, null) catch unreachable;
    }
    
    // Benchmark warm access
    i = 0;
    while (i < 10000) : (i += 1) {
        const was_cold = contract.mark_storage_slot_warm(allocator, i % 100, null) catch unreachable;
        _ = was_cold;
    }
}

/// Benchmark storage with pool
pub fn bench_storage_with_pool(allocator: Allocator) void {
    var pool = StoragePool.init(allocator);
    defer pool.deinit();
    
    var contracts: [10]Contract = undefined;
    
    // Create and destroy contracts using pool
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Create contracts
        for (&contracts) |*contract| {
            contract.* = Contract.init(
                primitives.Address.zero(),
                primitives.Address.zero(),
                0,
                1000000,
                &[_]u8{},
                [_]u8{0} ** 32,
                &[_]u8{},
                false,
            );
            // Use storage
            _ = contract.mark_storage_slot_warm(allocator, 0x100, &pool) catch unreachable;
            _ = contract.mark_storage_slot_warm(allocator, 0x200, &pool) catch unreachable;
        }
        
        // Clean up with pool
        for (&contracts) |*contract| {
            contract.deinit(allocator, &pool);
        }
    }
}

/// Benchmark batch storage operations
pub fn bench_storage_batch_warm(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Prepare slots to warm
    var slots: [100]u256 = undefined;
    for (&slots, 0..) |*slot, idx| {
        slot.* = @as(u256, idx) << 64;
    }
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        contract.mark_storage_slots_warm(allocator, &slots, null) catch unreachable;
        // Reset for next iteration
        contract.storage_access.?.clearRetainingCapacity();
    }
}

// =============================================================================
// Call Stack Management Benchmarks
// =============================================================================

/// Benchmark shallow call stack (depth 1-10)
pub fn bench_call_stack_shallow(allocator: Allocator) void {
    var contracts: [10]Contract = undefined;
    var frames: [10]Frame = undefined;
    
    // Initialize contracts
    for (&contracts) |*contract| {
        contract.* = Contract.init(
            primitives.Address.zero(),
            primitives.Address.zero(),
            0,
            1000000,
            &[_]u8{},
            [_]u8{0} ** 32,
            &[_]u8{},
            false,
        );
    }
    defer for (&contracts) |*contract| {
        contract.deinit(allocator, null);
    };
    
    // Create frame stack
    for (&frames, 0..) |*frame, idx| {
        frame.* = Frame.init_with_state(
            allocator,
            &contracts[idx],
            null,
            null,
            null,
            null,
            null,
            null,
            1000000 - (idx * 1000),
            false,
            null,
            @intCast(idx),
            null,
            null,
        ) catch unreachable;
    }
    
    // Clean up
    for (&frames) |*frame| {
        frame.deinit();
    }
}

/// Benchmark deep call stack (approaching 1024 limit)
pub fn bench_call_stack_deep(allocator: Allocator) void {
    // For benchmark, we'll simulate operations at various depths
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    const depths = [_]u32{100, 500, 900, 1020, 1024};
    
    for (depths) |depth| {
        var frame = Frame.init_with_state(
            allocator,
            &contract,
            null,
            null,
            null,
            null,
            null,
            null,
            1000000,
            false,
            null,
            depth,
            null,
            null,
        ) catch unreachable;
        
        // Simulate some operations at this depth
        frame.consume_gas(21000) catch unreachable;
        frame.stack.push(42) catch unreachable;
        _ = frame.stack.pop() catch unreachable;
        
        frame.deinit();
    }
}

/// Benchmark frame creation/destruction for recursive calls
pub fn bench_recursive_frame_pattern(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        10000000, // 10M gas
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    // Simulate recursive call pattern
    var depth: u32 = 0;
    while (depth < 100) : (depth += 1) {
        var frame = Frame.init_with_state(
            allocator,
            &contract,
            null,
            null,
            null,
            null,
            null,
            null,
            10000000 - (depth * 1000),
            false,
            null,
            depth,
            null,
            null,
        ) catch unreachable;
        
        // Simulate work
        frame.consume_gas(100) catch unreachable;
        
        frame.deinit();
    }
}

// =============================================================================
// Gas Accounting Benchmarks
// =============================================================================

/// Benchmark gas consumption tracking
pub fn bench_gas_tracking_simple(_: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        30000000, // 30M gas
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    // Track gas consumption
    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        const used = contract.use_gas(21000); // Base transaction cost
        _ = used;
        contract.refund_gas(21000); // Restore for next iteration
    }
}

/// Benchmark gas refund calculations
pub fn bench_gas_refund_tracking(_: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    
    // Simulate SSTORE refunds
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        contract.add_gas_refund(15000); // SSTORE refund
        contract.sub_gas_refund(5000); // Partial use
    }
}

/// Benchmark dynamic gas calculation patterns
pub fn bench_dynamic_gas_patterns(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        1000000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    var frame = Frame.init(allocator, &contract) catch unreachable;
    defer frame.deinit();
    frame.gas_remaining = 1000000;
    
    // Simulate memory expansion gas costs
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const memory_size = (i + 1) * 32;
        const word_count = (memory_size + 31) / 32;
        const memory_cost = (word_count * 3) + ((word_count * word_count) / 512);
        
        frame.consume_gas(memory_cost) catch break;
    }
}

// =============================================================================
// Real-world Scenario Benchmarks
// =============================================================================

/// Benchmark simple ETH transfer
pub fn bench_scenario_simple_transfer(allocator: Allocator) void {
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        1000000000000000000, // 1 ETH
        21000, // Base gas
        &[_]u8{}, // No code
        [_]u8{0} ** 32,
        &[_]u8{}, // No calldata
        false,
    );
    defer contract.deinit(allocator, null);
    
    var frame = Frame.init(allocator, &contract) catch unreachable;
    defer frame.deinit();
    frame.gas_remaining = 21000;
    
    // Simulate transfer execution
    frame.consume_gas(21000) catch unreachable;
    frame.stop = true;
}

/// Benchmark DeFi swap transaction
pub fn bench_scenario_defi_swap(allocator: Allocator) void {
    // Typical Uniswap V2 swap bytecode pattern
    var bytecode: [4096]u8 = undefined;
    std.mem.set(u8, &bytecode, 0x60); // Simplified
    
    var contract = Contract.init(
        primitives.Address.zero(),
        primitives.Address.zero(),
        0,
        300000, // Typical swap gas
        &bytecode,
        [_]u8{0x11} ** 32,
        &[_]u8{0x02, 0x75, 0x12}, // Function selector + args
        false,
    );
    defer contract.deinit(allocator, null);
    
    var frame = Frame.init(allocator, &contract) catch unreachable;
    defer frame.deinit();
    frame.gas_remaining = 300000;
    
    // Simulate swap operations
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // Storage reads (reserves)
        _ = contract.mark_storage_slot_warm(allocator, 0x0, null) catch unreachable;
        _ = contract.mark_storage_slot_warm(allocator, 0x1, null) catch unreachable;
        frame.consume_gas(2100 * 2) catch unreachable; // Cold slots
        
        // Calculations on stack
        frame.stack.push(1000000) catch unreachable;
        frame.stack.push(50000000) catch unreachable;
        _ = frame.stack.pop() catch unreachable;
        _ = frame.stack.pop() catch unreachable;
        
        // Storage writes (update reserves)
        frame.consume_gas(20000) catch unreachable; // SSTORE
    }
}

/// Benchmark contract deployment
pub fn bench_scenario_contract_deployment(allocator: Allocator) void {
    // ERC20 constructor pattern
    var init_code: [8192]u8 = undefined;
    std.mem.set(u8, &init_code, 0x60);
    
    var contract = Contract.init_deployment(
        primitives.Address.zero(),
        0,
        3000000, // Deployment gas
        &init_code,
        null,
    );
    defer contract.deinit(allocator, null);
    
    var frame = Frame.init(allocator, &contract) catch unreachable;
    defer frame.deinit();
    frame.gas_remaining = 3000000;
    
    // Simulate deployment execution
    frame.consume_gas(32000) catch unreachable; // CREATE base cost
    
    // Memory operations for code copy
    _ = frame.memory.ensure_capacity(init_code.len) catch unreachable;
    frame.consume_gas(init_code.len * 3) catch unreachable; // Memory expansion
    
    // Return runtime code
    frame.output = init_code[0..4096]; // Runtime code
    frame.stop = true;
}

/// Benchmark deep call stack (DeFi composability)
pub fn bench_scenario_deep_defi_calls(allocator: Allocator) void {
    // Simulate flash loan -> swap -> lending protocol pattern
    const depths = [_]struct { name: []const u8, gas: u64 }{
        .{ .name = "flashloan", .gas = 500000 },
        .{ .name = "swap", .gas = 300000 },
        .{ .name = "deposit", .gas = 200000 },
        .{ .name = "mint", .gas = 100000 },
    };
    
    var contracts: [4]Contract = undefined;
    for (&contracts, 0..) |*contract, idx| {
        contract.* = Contract.init(
            primitives.Address.zero(),
            primitives.Address.zero(),
            0,
            depths[idx].gas,
            &[_]u8{0x60, 0x40},
            [_]u8{@intCast(idx)} ** 32,
            &[_]u8{},
            false,
        );
    }
    defer for (&contracts) |*contract| {
        contract.deinit(allocator, null);
    };
    
    // Create nested frames
    var frames: [4]Frame = undefined;
    for (&frames, 0..) |*frame, idx| {
        frame.* = Frame.init_with_state(
            allocator,
            &contracts[idx],
            null,
            null,
            null,
            null,
            null,
            null,
            depths[idx].gas,
            false,
            null,
            @intCast(idx),
            null,
            null,
        ) catch unreachable;
    }
    
    // Simulate execution at each level
    for (&frames) |*frame| {
        frame.consume_gas(21000) catch unreachable;
        frame.stack.push(42) catch unreachable;
    }
    
    // Clean up in reverse order
    var i: usize = frames.len;
    while (i > 0) {
        i -= 1;
        frames[i].deinit();
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}