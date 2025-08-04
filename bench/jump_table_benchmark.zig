const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    
    // Only run in ReleaseFast mode for accurate benchmarks
    if (builtin.mode != .ReleaseFast) {
        try stdout.print("Warning: Run with -O ReleaseFast for accurate benchmarks\n", .{});
    }
    
    try benchmark_aos_vs_soa(allocator);
}

fn benchmark_aos_vs_soa(allocator: std.mem.Allocator) !void {
    _ = allocator;
    const Evm = @import("evm");
    const JumpTable = Evm.JumpTable;
    const SoaJumpTable = Evm.SoaJumpTable;
    
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
    
    // Initialize tables
    const aos_table = JumpTable.DEFAULT;
    const soa_table = SoaJumpTable.init_from_aos(&aos_table);
    
    const warmup_iterations = 100_000;
    const benchmark_iterations = 10_000_000;
    
    const stdout = std.io.getStdOut().writer();
    
    // Warmup
    try stdout.print("Warming up caches...\n", .{});
    for (0..warmup_iterations) |_| {
        for (weighted_opcodes) |opcode| {
            const op = aos_table.get_operation(opcode);
            std.mem.doNotOptimizeAway(op);
        }
    }
    
    try stdout.print("\n=== Jump Table Benchmark ===\n", .{});
    try stdout.print("Iterations: {}\n", .{benchmark_iterations});
    try stdout.print("Opcodes per iteration: {}\n", .{weighted_opcodes.len});
    try stdout.print("Total operations: {}\n\n", .{benchmark_iterations * weighted_opcodes.len});
    
    // Benchmark AoS
    {
        var total_gas: u64 = 0;
        var total_stack: u64 = 0;
        
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |_| {
            for (weighted_opcodes) |opcode| {
                const op = aos_table.get_operation(opcode);
                total_gas +%= op.constant_gas;
                total_stack +%= op.min_stack;
                total_stack +%= op.max_stack;
                // Force compiler to not optimize away the function pointer
                std.mem.doNotOptimizeAway(op.execute);
            }
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = (@as(u64, benchmark_iterations) * weighted_opcodes.len * 1_000_000_000) / elapsed_ns;
        const ns_per_op = elapsed_ns / (@as(u64, benchmark_iterations) * weighted_opcodes.len);
        
        try stdout.print("Array-of-Structs (Current):\n", .{});
        try stdout.print("  Total time: {d:.3}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
        try stdout.print("  Ops/second: {d:.2}M\n", .{@as(f64, @floatFromInt(ops_per_sec)) / 1_000_000});
        try stdout.print("  Nanoseconds/op: {}\n", .{ns_per_op});
        try stdout.print("  Checksum: gas={}, stack={}\n", .{ total_gas, total_stack });
    }
    
    // Benchmark SoA
    {
        var total_gas: u64 = 0;
        var total_stack: u64 = 0;
        
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |_| {
            for (weighted_opcodes) |opcode| {
                const hot = soa_table.get_hot_fields(opcode);
                const stack = soa_table.get_stack_requirements(opcode);
                total_gas +%= hot.gas;
                total_stack +%= stack.min_stack;
                total_stack +%= stack.max_stack;
                std.mem.doNotOptimizeAway(hot.execute);
            }
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = (@as(u64, benchmark_iterations) * weighted_opcodes.len * 1_000_000_000) / elapsed_ns;
        const ns_per_op = elapsed_ns / (@as(u64, benchmark_iterations) * weighted_opcodes.len);
        
        try stdout.print("\nStruct-of-Arrays (Optimized):\n", .{});
        try stdout.print("  Total time: {d:.3}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
        try stdout.print("  Ops/second: {d:.2}M\n", .{@as(f64, @floatFromInt(ops_per_sec)) / 1_000_000});
        try stdout.print("  Nanoseconds/op: {}\n", .{ns_per_op});
        try stdout.print("  Checksum: gas={}, stack={}\n", .{ total_gas, total_stack });
    }
    
    // Benchmark SoA with full struct access (worst case)
    {
        var total_gas: u64 = 0;
        var total_stack: u64 = 0;
        
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |_| {
            for (weighted_opcodes) |opcode| {
                const op = soa_table.get_operation_soa(opcode);
                total_gas +%= op.gas;
                total_stack +%= op.min_stack;
                total_stack +%= op.max_stack;
                std.mem.doNotOptimizeAway(op.execute);
            }
        }
        
        const elapsed_ns = timer.read();
        const ops_per_sec = (@as(u64, benchmark_iterations) * weighted_opcodes.len * 1_000_000_000) / elapsed_ns;
        const ns_per_op = elapsed_ns / (@as(u64, benchmark_iterations) * weighted_opcodes.len);
        
        try stdout.print("\nStruct-of-Arrays (Full Access):\n", .{});
        try stdout.print("  Total time: {d:.3}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
        try stdout.print("  Ops/second: {d:.2}M\n", .{@as(f64, @floatFromInt(ops_per_sec)) / 1_000_000});
        try stdout.print("  Nanoseconds/op: {}\n", .{ns_per_op});
        try stdout.print("  Checksum: gas={}, stack={}\n", .{ total_gas, total_stack });
    }
}