/// Jump Table Benchmarks - AoS vs SoA Performance Comparison
///
/// Benchmarks comparing Array-of-Structs (AoS) vs Struct-of-Arrays (SoA)
/// jump table implementations for EVM opcode dispatch optimization.
const std = @import("std");
const Evm = @import("evm");
const zbench = @import("zbench");

// Real opcode distribution from Ethereum mainnet analysis
// These are weighted by actual frequency
const weighted_opcodes = [_]u8{
    // Most common (>5% each)
    0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, // PUSH1 (30%)
    0x80, 0x80, 0x80, 0x80, // DUP1 (10%)
    0x52, 0x52, 0x52, // MSTORE (8%)
    0x51, 0x51, 0x51, // MLOAD (7%)
    0x01, 0x01, 0x01, // ADD (6%)

    // Common (1-5% each)
    0x57, 0x57, // JUMPI (4%)
    0x5b, 0x5b, // JUMPDEST (4%)
    0x14, 0x14, // EQ (3%)
    0x61, 0x61, // PUSH2 (3%)
    0x50, 0x50, // POP (3%)
    0x15, // ISZERO (2%)
    0x56, // JUMP (2%)
    0x35, // CALLDATALOAD (2%)

    // Less common but still significant
    0x02, // MUL (1%)
    0x04, // DIV (1%)
    0x10, // LT (1%)
    0x11, // GT (1%)
    0x16, // AND (1%)
    0x36, // CALLDATASIZE (1%)
    0x03, // SUB (1%)
    0x81, // DUP2 (1%)
    0x82, // DUP3 (1%)
    0x90, // SWAP1 (1%)
    0x00, // STOP (1%)
    0xf3, // RETURN (1%)
};

/// Benchmark AoS jump table with full operation access
pub fn zbench_aos_full_access(allocator: std.mem.Allocator) void {
    _ = allocator;
    const aos_table = Evm.JumpTable.DEFAULT;

    var total_gas: u64 = 0;
    var total_stack: u64 = 0;

    const iterations = 10_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        for (weighted_opcodes) |opcode| {
            const op = aos_table.get_operation(opcode);
            total_gas +%= op.constant_gas;
            total_stack +%= op.min_stack;
            total_stack +%= op.max_stack;
            std.mem.doNotOptimizeAway(op.execute);
        }
    }

    std.mem.doNotOptimizeAway(total_gas);
    std.mem.doNotOptimizeAway(total_stack);
}

/// Benchmark SoA jump table with optimized hot field access
pub fn zbench_soa_hot_fields(allocator: std.mem.Allocator) void {
    _ = allocator;
    const aos_table = Evm.JumpTable.DEFAULT;
    const soa_table = Evm.SoaJumpTable.init_from_aos(&aos_table);

    var total_gas: u64 = 0;
    var total_stack: u64 = 0;

    const iterations = 10_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        for (weighted_opcodes) |opcode| {
            const hot = soa_table.get_hot_fields(opcode);
            const stack = soa_table.get_stack_requirements(opcode);
            total_gas +%= hot.gas;
            total_stack +%= stack.min_stack;
            total_stack +%= stack.max_stack;
            std.mem.doNotOptimizeAway(hot.execute);
        }
    }

    std.mem.doNotOptimizeAway(total_gas);
    std.mem.doNotOptimizeAway(total_stack);
}

/// Benchmark SoA jump table with full operation access (worst case)
pub fn zbench_soa_full_access(allocator: std.mem.Allocator) void {
    _ = allocator;
    const aos_table = Evm.JumpTable.DEFAULT;
    const soa_table = Evm.SoaJumpTable.init_from_aos(&aos_table);

    var total_gas: u64 = 0;
    var total_stack: u64 = 0;

    const iterations = 10_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        for (weighted_opcodes) |opcode| {
            const op = soa_table.get_operation_soa(opcode);
            total_gas +%= op.gas;
            total_stack +%= op.min_stack;
            total_stack +%= op.max_stack;
            std.mem.doNotOptimizeAway(op.execute);
        }
    }

    std.mem.doNotOptimizeAway(total_gas);
    std.mem.doNotOptimizeAway(total_stack);
}

/// Benchmark AoS jump table with sequential access pattern
pub fn zbench_aos_sequential(allocator: std.mem.Allocator) void {
    _ = allocator;
    const aos_table = Evm.JumpTable.DEFAULT;

    var total_gas: u64 = 0;

    const iterations = 1_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Sequential access pattern (0x00 to 0xFF)
        var opcode: u16 = 0;
        while (opcode <= 0xFF) : (opcode += 1) {
            const op = aos_table.get_operation(@intCast(opcode));
            total_gas +%= op.constant_gas;
            std.mem.doNotOptimizeAway(op.execute);
        }
    }

    std.mem.doNotOptimizeAway(total_gas);
}

/// Benchmark SoA jump table with sequential access pattern
pub fn zbench_soa_sequential(allocator: std.mem.Allocator) void {
    _ = allocator;
    const aos_table = Evm.JumpTable.DEFAULT;
    const soa_table = Evm.SoaJumpTable.init_from_aos(&aos_table);

    var total_gas: u64 = 0;

    const iterations = 1_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // Sequential access pattern (0x00 to 0xFF)
        var opcode: u16 = 0;
        while (opcode <= 0xFF) : (opcode += 1) {
            const hot = soa_table.get_hot_fields(@intCast(opcode));
            total_gas +%= hot.gas;
            std.mem.doNotOptimizeAway(hot.execute);
        }
    }

    std.mem.doNotOptimizeAway(total_gas);
}

/// Benchmark AoS jump table with random access pattern
pub fn zbench_aos_random(allocator: std.mem.Allocator) void {
    const aos_table = Evm.JumpTable.DEFAULT;

    // Create deterministic "random" sequence
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    // Pre-generate random opcodes
    var random_opcodes: [1024]u8 = undefined;
    for (&random_opcodes) |*opcode| {
        opcode.* = random.int(u8);
    }

    var total_gas: u64 = 0;

    const iterations = 10_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        for (random_opcodes) |opcode| {
            const op = aos_table.get_operation(opcode);
            total_gas +%= op.constant_gas;
            std.mem.doNotOptimizeAway(op.execute);
        }
    }

    std.mem.doNotOptimizeAway(total_gas);
    _ = allocator;
}

/// Benchmark SoA jump table with random access pattern
pub fn zbench_soa_random(allocator: std.mem.Allocator) void {
    const aos_table = Evm.JumpTable.DEFAULT;
    const soa_table = Evm.SoaJumpTable.init_from_aos(&aos_table);

    // Create deterministic "random" sequence
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    // Pre-generate random opcodes
    var random_opcodes: [1024]u8 = undefined;
    for (&random_opcodes) |*opcode| {
        opcode.* = random.int(u8);
    }

    var total_gas: u64 = 0;

    const iterations = 10_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        for (random_opcodes) |opcode| {
            const hot = soa_table.get_hot_fields(opcode);
            total_gas +%= hot.gas;
            std.mem.doNotOptimizeAway(hot.execute);
        }
    }

    std.mem.doNotOptimizeAway(total_gas);
    _ = allocator;
}
