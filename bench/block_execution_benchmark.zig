const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Benchmark arithmetic loop with block execution disabled
// WARNING: This function is NEVER called! zbench_runner.zig expects different function names
// TODO: Either rename to match zbench_block_arithmetic OR update zbench_runner.zig
pub fn zbench_arithmetic_no_blocks(allocator: Allocator) void {
    // Use GPA for the benchmark
    // FIXME: We're ignoring the provided allocator parameter and creating our own GPA
    // This is inefficient and not how zbench is meant to be used
    // Should use: const gpa_allocator = allocator; instead
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Generate bytecode
    const bytecode = generateArithmeticLoopBytecode(gpa_allocator) catch return;
    defer gpa_allocator.free(bytecode);
    
    // Create VM and contract
    var memory_db = Evm.MemoryDatabase.init(gpa_allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(gpa_allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(gpa_allocator, null);
    contract.analysis = null; // Disable block execution
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| gpa_allocator.free(output);
}

/// Benchmark arithmetic loop with block execution enabled
pub fn zbench_arithmetic_with_blocks(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Generate bytecode
    const bytecode = generateArithmeticLoopBytecode(gpa_allocator) catch return;
    defer gpa_allocator.free(bytecode);
    
    // Create VM and contract
    var memory_db = Evm.MemoryDatabase.init(gpa_allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(gpa_allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(gpa_allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| gpa_allocator.free(output);
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

/// Benchmark memory operations with block execution disabled
pub fn zbench_memory_no_blocks(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Generate bytecode
    const bytecode = generateMemoryBytecode(gpa_allocator) catch return;
    defer gpa_allocator.free(bytecode);
    
    // Create VM and contract
    var memory_db = Evm.MemoryDatabase.init(gpa_allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(gpa_allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(gpa_allocator, null);
    contract.analysis = null; // Disable block execution
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| gpa_allocator.free(output);
}

/// Benchmark memory operations with block execution enabled
pub fn zbench_memory_with_blocks(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Generate bytecode
    const bytecode = generateMemoryBytecode(gpa_allocator) catch return;
    defer gpa_allocator.free(bytecode);
    
    // Create VM and contract
    var memory_db = Evm.MemoryDatabase.init(gpa_allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(gpa_allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(gpa_allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| gpa_allocator.free(output);
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

/// Benchmark control flow with block execution disabled
pub fn zbench_control_flow_no_blocks(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Generate bytecode
    const bytecode = generateControlFlowBytecode(gpa_allocator) catch return;
    defer gpa_allocator.free(bytecode);
    
    // Create VM and contract
    var memory_db = Evm.MemoryDatabase.init(gpa_allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(gpa_allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(gpa_allocator, null);
    contract.analysis = null; // Disable block execution
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| gpa_allocator.free(output);
}

/// Benchmark control flow with block execution enabled
pub fn zbench_control_flow_with_blocks(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Generate bytecode
    const bytecode = generateControlFlowBytecode(gpa_allocator) catch return;
    defer gpa_allocator.free(bytecode);
    
    // Create VM and contract
    var memory_db = Evm.MemoryDatabase.init(gpa_allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(gpa_allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(gpa_allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| gpa_allocator.free(output);
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

