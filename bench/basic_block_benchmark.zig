const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    
    if (builtin.mode != .ReleaseFast) {
        try stdout.print("Warning: Run with -O ReleaseFast for accurate benchmarks\n", .{});
    }
    
    try benchmark_basic_block_validation(allocator);
}

fn benchmark_basic_block_validation(allocator: std.mem.Allocator) !void {
    const Evm = @import("evm");
    const primitives = @import("primitives");
    const BasicBlockAnalysis = @import("evm").BasicBlockAnalysis;
    const stdout = std.io.getStdOut().writer();
    
    // Create test bytecode with long sequences of arithmetic operations
    // This simulates contracts with heavy computation and minimal branching
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Start with some initial values
    try bytecode.appendSlice(&[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
    });
    
    // Long sequence of arithmetic operations (basic block)
    for (0..200) |i| {
        // Pattern: DUP4, DUP4, ADD, DUP3, MUL, DUP2, SUB, SWAP1
        try bytecode.appendSlice(&[_]u8{
            0x83, // DUP4
            0x83, // DUP4
            0x01, // ADD
            0x82, // DUP3
            0x02, // MUL
            0x81, // DUP2
            0x03, // SUB
            0x90, // SWAP1
        });
        
        // Every 10 iterations, add a conditional jump (creates new basic block)
        if (i % 10 == 9) {
            try bytecode.appendSlice(&[_]u8{
                0x60, 0x00, // PUSH1 0
                0x14,       // EQ
                0x61, 0x00, 0x00, // PUSH2 (placeholder target)
                0x57,       // JUMPI
            });
        }
    }
    
    // End with STOP
    try bytecode.append(0x00);
    
    try stdout.print("\n=== Basic Block Stack Validation Benchmark ===\n", .{});
    try stdout.print("Bytecode size: {} bytes\n", .{bytecode.items.len});
    try stdout.print("Estimated basic blocks: ~20\n", .{});
    
    // Analyze bytecode to create basic block information
    var basic_block_analysis = try BasicBlockAnalysis.analyze(allocator, bytecode.items);
    defer basic_block_analysis.deinit();
    
    try stdout.print("Actual basic blocks: {}\n", .{basic_block_analysis.blocks.len});
    try stdout.print("\nBlock details:\n", .{});
    for (basic_block_analysis.blocks, 0..) |block, i| {
        try stdout.print("  Block {}: PC {}-{}, min_stack={}, max_stack={}, net_change={}\n", .{
            i,
            block.start_pc,
            block.end_pc,
            block.min_stack_entry,
            block.max_stack_entry,
            block.net_stack_change,
        });
    }
    
    // Setup VM for execution benchmark
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x1000);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    try vm.state.set_code(contract_addr, bytecode.items);
    
    const warmup_iterations = 1_000;
    const benchmark_iterations = 10_000;
    
    // Warmup
    try stdout.print("\nWarming up...\n", .{});
    for (0..warmup_iterations) |_| {
        var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 10_000_000, bytecode.items, &.{}, false);
        const result = try vm.interpret(&contract, &.{}, false);
        defer if (result.output) |output| allocator.free(output);
    }
    
    // Benchmark current per-opcode validation
    {
        try stdout.print("\nCurrent Implementation (Per-Opcode Validation):\n", .{});
        var total_gas_used: u64 = 0;
        
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |_| {
            var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 10_000_000, bytecode.items, &.{}, false);
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
            
            total_gas_used += result.gas_used;
        }
        
        const elapsed_ns = timer.read();
        const executions_per_sec = (benchmark_iterations * 1_000_000_000) / elapsed_ns;
        const ns_per_execution = elapsed_ns / benchmark_iterations;
        
        try stdout.print("  Total time: {d:.3}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
        try stdout.print("  Executions/second: {}\n", .{executions_per_sec});
        try stdout.print("  Nanoseconds/execution: {}\n", .{ns_per_execution});
        try stdout.print("  Total gas used: {}\n", .{total_gas_used});
        try stdout.print("  Average gas/execution: {}\n", .{total_gas_used / benchmark_iterations});
    }
    
    // Benchmark basic block validation (simulated)
    {
        try stdout.print("\nOptimized Implementation (Basic Block Validation):\n", .{});
        try stdout.print("  (Would show performance with basic block optimization)\n", .{});
        try stdout.print("  Expected improvement: 20-40% for computation-heavy contracts\n", .{});
        try stdout.print("  Benefits:\n", .{});
        try stdout.print("    - Single validation per basic block instead of per opcode\n", .{});
        try stdout.print("    - Better CPU branch prediction\n", .{});
        try stdout.print("    - Reduced validation overhead in tight loops\n", .{});
    }
    
    // Analyze validation overhead
    {
        try stdout.print("\nValidation Overhead Analysis:\n", .{});
        const total_opcodes = bytecode.items.len;
        const validation_calls_current = total_opcodes;
        const validation_calls_optimized = basic_block_analysis.blocks.len;
        const reduction_percent = (@as(f64, @floatFromInt(validation_calls_current - validation_calls_optimized)) / 
                                  @as(f64, @floatFromInt(validation_calls_current))) * 100;
        
        try stdout.print("  Total opcodes: {}\n", .{total_opcodes});
        try stdout.print("  Validation calls (current): {}\n", .{validation_calls_current});
        try stdout.print("  Validation calls (optimized): {}\n", .{validation_calls_optimized});
        try stdout.print("  Reduction: {d:.1}%\n", .{reduction_percent});
    }
}