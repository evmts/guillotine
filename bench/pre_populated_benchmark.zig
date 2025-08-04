const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    
    if (builtin.mode != .ReleaseFast) {
        try stdout.print("Warning: Run with -O ReleaseFast for accurate benchmarks\n", .{});
    }
    
    try benchmark_pre_populated_vs_dynamic(allocator);
}

fn benchmark_pre_populated_vs_dynamic(_: std.mem.Allocator) !void {
    const Evm = @import("evm");
    const JumpTable = Evm.JumpTable;
    const Hardfork = Evm.Hardfork.Hardfork;
    const stdout = std.io.getStdOut().writer();
    
    const warmup_iterations = 1_000;
    const benchmark_iterations = 100_000;
    
    try stdout.print("\n=== Pre-Populated Operation Lookup Benchmark ===\n", .{});
    try stdout.print("Comparing jump table initialization methods\n", .{});
    try stdout.print("Iterations: {}\n\n", .{benchmark_iterations});
    
    // Test hardforks
    const hardforks = [_]Hardfork{
        .FRONTIER,
        .BYZANTIUM,
        .ISTANBUL,
        .BERLIN,
        .LONDON,
        .SHANGHAI,
        .CANCUN,
    };
    
    // Warmup
    try stdout.print("Warming up...\n", .{});
    for (0..warmup_iterations) |_| {
        for (hardforks) |hardfork| {
            _ = JumpTable.init_from_hardfork(hardfork);
            _ = JumpTable.init_from_pre_populated(hardfork);
        }
    }
    
    // Benchmark dynamic generation
    try stdout.print("\nDynamic Generation (init_from_hardfork):\n", .{});
    for (hardforks) |hardfork| {
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |_| {
            const table = JumpTable.init_from_hardfork(hardfork);
            // Use the table to prevent optimization
            std.mem.doNotOptimizeAway(&table);
        }
        
        const elapsed_ns = timer.read();
        const ns_per_init = elapsed_ns / benchmark_iterations;
        const inits_per_sec = (benchmark_iterations * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  {s}: {} ns/init, {} inits/sec\n", .{
            @tagName(hardfork),
            ns_per_init,
            inits_per_sec,
        });
    }
    
    // Benchmark pre-populated
    try stdout.print("\nPre-Populated (init_from_pre_populated):\n", .{});
    for (hardforks) |hardfork| {
        var timer = try std.time.Timer.start();
        
        for (0..benchmark_iterations) |_| {
            const table = JumpTable.init_from_pre_populated(hardfork);
            // Use the table to prevent optimization
            std.mem.doNotOptimizeAway(&table);
        }
        
        const elapsed_ns = timer.read();
        const ns_per_init = elapsed_ns / benchmark_iterations;
        const inits_per_sec = (benchmark_iterations * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  {s}: {} ns/init, {} inits/sec\n", .{
            @tagName(hardfork),
            ns_per_init,
            inits_per_sec,
        });
    }
    
    // Benchmark operation lookup performance
    try stdout.print("\nOperation Lookup Performance:\n", .{});
    
    const dynamic_table = JumpTable.init_from_hardfork(.CANCUN);
    const pre_populated_table = JumpTable.init_from_pre_populated(.CANCUN);
    
    // Common opcodes to test
    const test_opcodes = [_]u8{
        0x01, // ADD
        0x60, // PUSH1
        0x80, // DUP1
        0x52, // MSTORE
        0x51, // MLOAD
        0x56, // JUMP
        0xf1, // CALL
        0x00, // STOP
    };
    
    const lookup_iterations = 10_000_000;
    
    // Benchmark dynamic table lookup
    {
        var total_ops: usize = 0;
        var timer = try std.time.Timer.start();
        
        for (0..lookup_iterations) |i| {
            const opcode = test_opcodes[i % test_opcodes.len];
            const op = dynamic_table.get_operation(opcode);
            total_ops += @intFromPtr(op);
        }
        
        const elapsed_ns = timer.read();
        const lookups_per_sec = (lookup_iterations * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Dynamic table: {} lookups/sec\n", .{lookups_per_sec});
        std.mem.doNotOptimizeAway(total_ops);
    }
    
    // Benchmark pre-populated table lookup
    {
        var total_ops: usize = 0;
        var timer = try std.time.Timer.start();
        
        for (0..lookup_iterations) |i| {
            const opcode = test_opcodes[i % test_opcodes.len];
            const op = pre_populated_table.get_operation(opcode);
            total_ops += @intFromPtr(op);
        }
        
        const elapsed_ns = timer.read();
        const lookups_per_sec = (lookup_iterations * 1_000_000_000) / elapsed_ns;
        
        try stdout.print("  Pre-populated table: {} lookups/sec\n", .{lookups_per_sec});
        std.mem.doNotOptimizeAway(total_ops);
    }
    
    // Memory usage comparison
    try stdout.print("\nMemory Usage Analysis:\n", .{});
    try stdout.print("  Dynamic: Allocates operations at runtime\n", .{});
    try stdout.print("  Pre-populated: Uses compile-time const data\n", .{});
    try stdout.print("  Expected improvement: Better cache locality with const data\n", .{});
    
    // Binary size impact
    try stdout.print("\nBinary Size Impact:\n", .{});
    try stdout.print("  Pre-populated tables add ~{}KB to binary\n", .{
        (@sizeOf(@TypeOf(Evm.pre_populated_tables.TABLES)) / 1024),
    });
    try stdout.print("  Trade-off: Larger binary for faster initialization\n", .{});
}