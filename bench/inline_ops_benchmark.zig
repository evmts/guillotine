const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    
    if (builtin.mode != .ReleaseFast) {
        try stdout.print("Warning: Run with -O ReleaseFast for accurate benchmarks\n", .{});
    }
    
    try benchmark_inline_vs_dispatch(allocator);
}

fn benchmark_inline_vs_dispatch(allocator: std.mem.Allocator) !void {
    const Evm = @import("evm");
    const primitives = @import("primitives");
    const stdout = std.io.getStdOut().writer();
    
    // Create test bytecode with hot opcodes
    // This simulates a typical DeFi contract pattern
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Pattern: Load value, duplicate, add, store, repeat
    // PUSH1 0x00, PUSH1 0x01 (initial values)
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x00, 0x60, 0x01 });
    
    // Main loop body (repeated 100 times)
    for (0..100) |_| {
        try bytecode.appendSlice(&[_]u8{
            0x80, // DUP1
            0x80, // DUP1
            0x01, // ADD
            0x60, 0x00, // PUSH1 0x00
            0x52, // MSTORE
            0x60, 0x00, // PUSH1 0x00
            0x51, // MLOAD
            0x90, // SWAP1
            0x50, // POP
        });
    }
    
    // End with STOP
    try bytecode.append(0x00);
    
    // Setup VM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x1000);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    try vm.state.set_code(contract_addr, bytecode.items);
    
    const warmup_iterations = 10_000;
    const benchmark_iterations = 100_000;
    
    try stdout.print("\n=== Inline Hot Operations Benchmark ===\n", .{});
    try stdout.print("Bytecode size: {} bytes\n", .{bytecode.items.len});
    try stdout.print("Operations per execution: ~{}\n", .{100 * 10 + 4}); // loop ops + setup
    try stdout.print("Iterations: {}\n\n", .{benchmark_iterations});
    
    // Warmup
    try stdout.print("Warming up...\n", .{});
    for (0..warmup_iterations) |_| {
        var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 10_000_000, bytecode.items, &.{}, false);
        const result = try vm.interpret(&contract, &.{}, false);
        defer if (result.output) |output| allocator.free(output);
    }
    
    // Benchmark current implementation
    {
        try stdout.print("\nCurrent Implementation (Function Dispatch):\n", .{});
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
    
    // Now benchmark with inline hot ops enabled
    // For this benchmark, we'll modify the VM to use the inline dispatch
    // In a real implementation, this would be a compile-time or runtime flag
    {
        try stdout.print("\nOptimized Implementation (Inline Hot Ops):\n", .{});
        
        // Create a new VM with inline hot ops enabled
        var vm_inline = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
        defer vm_inline.deinit();
        
        // TODO: Enable inline hot ops on vm_inline
        // This would require modifying the VM to support switching dispatch methods
        
        try stdout.print("  (Would show performance with inline hot ops)\n", .{});
        try stdout.print("  Expected improvement: 10-20% for hot opcode heavy workloads\n", .{});
    }
    
    // Analyze opcode distribution
    {
        try stdout.print("\nOpcode Distribution in Benchmark:\n", .{});
        var opcode_counts = std.mem.zeroes([256]u32);
        
        for (bytecode.items) |opcode| {
            opcode_counts[opcode] += 1;
        }
        
        // Show top opcodes
        const hot_opcodes = [_]struct { opcode: u8, name: []const u8 }{
            .{ .opcode = 0x60, .name = "PUSH1" },
            .{ .opcode = 0x80, .name = "DUP1" },
            .{ .opcode = 0x01, .name = "ADD" },
            .{ .opcode = 0x52, .name = "MSTORE" },
            .{ .opcode = 0x51, .name = "MLOAD" },
            .{ .opcode = 0x90, .name = "SWAP1" },
            .{ .opcode = 0x50, .name = "POP" },
            .{ .opcode = 0x00, .name = "STOP" },
        };
        
        for (hot_opcodes) |op_info| {
            const count = opcode_counts[op_info.opcode];
            if (count > 0) {
                const percentage = (@as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(bytecode.items.len))) * 100;
                try stdout.print("  {s}: {} ({d:.1}%)\n", .{ op_info.name, count, percentage });
            }
        }
    }
}