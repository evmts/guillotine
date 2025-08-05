const std = @import("std");
const builtin = @import("builtin");
const evm = @import("evm");
const primitives = @import("primitives");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    
    if (builtin.mode != .ReleaseFast) {
        try stdout.print("Warning: Run with -O ReleaseFast for accurate benchmarks\n", .{});
    }
    
    try stdout.print("\n=== Block-Based Execution Performance Benchmark ===\n\n", .{});
    
    // Benchmark simple arithmetic loop
    try benchmarkArithmeticLoop(allocator);
    
    // Benchmark memory-intensive operations
    try benchmarkMemoryOperations(allocator);
    
    // Benchmark control flow heavy code
    try benchmarkControlFlow(allocator);
}

// Benchmark a simple arithmetic loop
fn benchmarkArithmeticLoop(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("Arithmetic Loop Benchmark (1000 iterations of ADD/MUL/SUB):\n", .{});
    
    // Bytecode for a loop that does arithmetic operations
    // This creates blocks of straight-line arithmetic
    const bytecode = try generateArithmeticLoopBytecode(allocator);
    defer allocator.free(bytecode);
    
    const iterations = 1000;
    const warmup = 100;
    
    // Create VM and contract
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Test with block execution disabled
    {
        var total_time: u64 = 0;
        for (0..warmup) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            // Force disable block execution
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            contract.analysis = null; // Disable block execution
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            contract.analysis = null; // Disable block execution
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        total_time = timer.read();
        
        try stdout.print("  Without block execution: {d:.2} ms\n", .{@as(f64, @floatFromInt(total_time)) / 1_000_000});
    }
    
    // Test with block execution enabled
    {
        var total_time: u64 = 0;
        for (0..warmup) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        total_time = timer.read();
        
        try stdout.print("  With block execution: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(total_time)) / 1_000_000});
    }
}

// Generate bytecode for arithmetic loop
fn generateArithmeticLoopBytecode(allocator: std.mem.Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Initialize counter
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x00 }); // PUSH1 0
    
    // Main loop (100 iterations)
    const loop_start = 2;
    
    // Loop body - arithmetic operations
    try bytecode.append(0x80); // DUP1
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x05 }); // PUSH1 5
    try bytecode.append(0x01); // ADD
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x03 }); // PUSH1 3
    try bytecode.append(0x02); // MUL
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x02 }); // PUSH1 2
    try bytecode.append(0x03); // SUB
    try bytecode.append(0x50); // POP (result)
    
    // Increment counter
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    try bytecode.append(0x01); // ADD
    
    // Check if done
    try bytecode.append(0x80); // DUP1
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x64 }); // PUSH1 100
    try bytecode.append(0x10); // LT
    
    // Jump back if not done
    try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
    try bytecode.append(@intCast(loop_start >> 8));
    try bytecode.append(@intCast(loop_start & 0xFF));
    try bytecode.append(0x57); // JUMPI
    
    // Cleanup and stop
    try bytecode.append(0x50); // POP
    try bytecode.append(0x00); // STOP
    
    // Add JUMPDEST at loop start
    var result = try allocator.alloc(u8, bytecode.items.len + 1);
    @memcpy(result[0..2], bytecode.items[0..2]);
    result[2] = 0x5b; // JUMPDEST
    @memcpy(result[3..], bytecode.items[2..]);
    
    return result;
}

// Benchmark memory-intensive operations
fn benchmarkMemoryOperations(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("Memory Operations Benchmark (MSTORE/MLOAD patterns):\n", .{});
    
    // Bytecode that does repeated memory operations
    const bytecode = try generateMemoryBytecode(allocator);
    defer allocator.free(bytecode);
    
    const iterations = 1000;
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Without block execution
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            contract.analysis = null;
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        const time = timer.read();
        
        try stdout.print("  Without block execution: {d:.2} ms\n", .{@as(f64, @floatFromInt(time)) / 1_000_000});
    }
    
    // With block execution
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        const time = timer.read();
        
        try stdout.print("  With block execution: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(time)) / 1_000_000});
    }
}

// Generate bytecode for memory operations
fn generateMemoryBytecode(allocator: std.mem.Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Store values at different memory locations
    for (0..10) |i| {
        // PUSH value
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 0x11) });
        // PUSH offset
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 0x20) });
        // MSTORE
        try bytecode.append(0x52);
    }
    
    // Load values back
    for (0..10) |i| {
        // PUSH offset
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 0x20) });
        // MLOAD
        try bytecode.append(0x51);
        // POP
        try bytecode.append(0x50);
    }
    
    // STOP
    try bytecode.append(0x00);
    
    return try allocator.dupe(u8, bytecode.items);
}

// Benchmark control flow heavy code
fn benchmarkControlFlow(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("Control Flow Benchmark (many small blocks with jumps):\n", .{});
    
    // Bytecode with many conditional jumps
    const bytecode = try generateControlFlowBytecode(allocator);
    defer allocator.free(bytecode);
    
    const iterations = 1000;
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Without block execution
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            contract.analysis = null;
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        const time = timer.read();
        
        try stdout.print("  Without block execution: {d:.2} ms\n", .{@as(f64, @floatFromInt(time)) / 1_000_000});
    }
    
    // With block execution
    {
        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
            defer vm.deinit();
            
            var contract = evm.Contract.init(
                primitives.Address.ZERO,
                primitives.Address.ZERO,
                0,
                1000000,
                bytecode,
                [_]u8{0} ** 32,
                &.{},
                false
            );
            defer contract.deinit(allocator, null);
            
            const result = try vm.interpret(&contract, &.{}, false);
            defer if (result.output) |output| allocator.free(output);
        }
        const time = timer.read();
        
        try stdout.print("  With block execution: {d:.2} ms\n\n", .{@as(f64, @floatFromInt(time)) / 1_000_000});
    }
}

// Generate bytecode with control flow
fn generateControlFlowBytecode(allocator: std.mem.Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Series of conditional jumps creating many small blocks
    for (0..20) |i| {
        // PUSH condition
        try bytecode.appendSlice(&[_]u8{ 0x60, if (i % 2 == 0) 0x01 else 0x00 });
        
        // PUSH jump destination (skip next few instructions)
        const dest = bytecode.items.len + 6;
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(dest) });
        
        // JUMPI
        try bytecode.append(0x57);
        
        // Some operations in between
        try bytecode.appendSlice(&[_]u8{ 0x60, 0xFF }); // PUSH1 FF
        try bytecode.append(0x50); // POP
        
        // JUMPDEST
        try bytecode.append(0x5b);
    }
    
    // STOP
    try bytecode.append(0x00);
    
    return try allocator.dupe(u8, bytecode.items);
}

test "block execution benchmark" {
    try main();
}