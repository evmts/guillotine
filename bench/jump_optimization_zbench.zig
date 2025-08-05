const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Benchmark pre-validated static jump performance
pub fn zbench_prevalidated_static_jumps(allocator: Allocator) void {
    // Generate bytecode with many pre-validatable static jumps
    const bytecode = generateStaticJumpPattern(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

/// Benchmark dynamic jump validation overhead
pub fn zbench_dynamic_jump_validation(allocator: Allocator) void {
    // Generate bytecode with computed jump destinations
    const bytecode = generateDynamicJumpPattern(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

/// Benchmark mixed static/dynamic jump patterns
pub fn zbench_mixed_jump_patterns(allocator: Allocator) void {
    const bytecode = generateMixedJumpPattern(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

/// Benchmark jump validation with deep call stack
pub fn zbench_deep_call_stack_jumps(allocator: Allocator) void {
    const bytecode = generateDeepCallStackPattern(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

/// Benchmark conditional jumps with static destinations
pub fn zbench_static_conditional_jumps(allocator: Allocator) void {
    const bytecode = generateStaticConditionalJumps(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

/// Benchmark jump table pattern (common in switch statements)
pub fn zbench_jump_table_pattern(allocator: Allocator) void {
    const bytecode = generateJumpTablePattern(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

/// Benchmark loop with static jumps (common pattern)
pub fn zbench_loop_static_jumps(allocator: Allocator) void {
    const bytecode = generateLoopPattern(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

/// Benchmark function call pattern with returns
pub fn zbench_function_call_pattern(allocator: Allocator) void {
    const bytecode = generateFunctionCallPattern(allocator) catch return;
    defer allocator.free(bytecode);
    
    executeContract(allocator, bytecode);
}

// Helper function to execute a contract
fn executeContract(allocator: Allocator, bytecode: []const u8) void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
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
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

// Bytecode generation functions

fn generateStaticJumpPattern(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Create 100 static jumps to different locations
    var destinations = std.ArrayList(usize).init(allocator);
    defer destinations.deinit();
    
    // Reserve space for jumps
    const jump_section_start = 0;
    const jump_section_size = 100 * 5; // Each jump is ~5 bytes
    try bytecode.appendNTimes(0x00, jump_section_size);
    
    // Add jump destinations
    for (0..100) |i| {
        try destinations.append(bytecode.items.len);
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
        try bytecode.append(0x50); // POP
    }
    
    // Fill in the jumps
    var pos: usize = jump_section_start;
    for (destinations.items) |dest| {
        bytecode.items[pos] = 0x61; // PUSH2
        bytecode.items[pos + 1] = @intCast(dest >> 8);
        bytecode.items[pos + 2] = @intCast(dest & 0xFF);
        bytecode.items[pos + 3] = 0x56; // JUMP
        bytecode.items[pos + 4] = 0x5b; // JUMPDEST (return point)
        pos += 5;
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateDynamicJumpPattern(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Add multiple jump destinations
    const dest_count = 50;
    var dest_positions = std.ArrayList(usize).init(allocator);
    defer dest_positions.deinit();
    
    for (0..dest_count) |i| {
        try dest_positions.append(bytecode.items.len);
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
        try bytecode.append(0x50); // POP
    }
    
    // Dynamic jump pattern: compute destination
    for (0..20) |i| {
        // Calculate destination based on input
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i % dest_count) }); // PUSH1 index
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x03 }); // PUSH1 3 (size of each dest block)
        try bytecode.append(0x02); // MUL
        try bytecode.append(0x56); // JUMP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateMixedJumpPattern(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Mix of static and dynamic jumps
    var static_dests = std.ArrayList(usize).init(allocator);
    defer static_dests.deinit();
    
    // Add destinations
    for (0..20) |i| {
        try static_dests.append(bytecode.items.len);
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
        try bytecode.append(0x50); // POP
    }
    
    // Interleave static and dynamic jumps
    for (0..10) |i| {
        // Static jump
        const static_dest = static_dests.items[i * 2];
        try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
        try bytecode.append(@intCast(static_dest >> 8));
        try bytecode.append(@intCast(static_dest & 0xFF));
        try bytecode.append(0x56); // JUMP
        
        // Dynamic jump (load from memory)
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 32) }); // PUSH1 offset
        try bytecode.append(0x51); // MLOAD
        try bytecode.append(0x56); // JUMP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateDeepCallStackPattern(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Simulate deep call stack with nested jumps
    var return_points = std.ArrayList(usize).init(allocator);
    defer return_points.deinit();
    
    // Create nested jump pattern
    for (0..10) |depth| {
        // Save return point
        try return_points.append(bytecode.items.len + 8);
        
        // Jump to next level
        const next_level = bytecode.items.len + 10;
        try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
        try bytecode.append(@intCast(next_level >> 8));
        try bytecode.append(@intCast(next_level & 0xFF));
        try bytecode.append(0x56); // JUMP
        
        // Return point
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(depth) }); // PUSH1 depth
        try bytecode.append(0x50); // POP
        
        // Jump destination for next level
        try bytecode.append(0x5b); // JUMPDEST
    }
    
    // Return through all levels
    for (return_points.items) |ret| {
        try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
        try bytecode.append(@intCast(ret >> 8));
        try bytecode.append(@intCast(ret & 0xFF));
        try bytecode.append(0x56); // JUMP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateStaticConditionalJumps(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Conditional jumps with static destinations
    var if_dests = std.ArrayList(usize).init(allocator);
    var else_dests = std.ArrayList(usize).init(allocator);
    defer if_dests.deinit();
    defer else_dests.deinit();
    
    // Reserve space for conditional logic
    const condition_section_size = 50 * 10; // 50 conditions, ~10 bytes each
    const start_pos = bytecode.items.len;
    try bytecode.appendNTimes(0x00, condition_section_size);
    
    // Add if/else destinations
    for (0..50) |i| {
        // If branch
        try if_dests.append(bytecode.items.len);
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 2) }); // PUSH1 (i*2)
        try bytecode.append(0x50); // POP
        
        // Else branch
        try else_dests.append(bytecode.items.len);
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 2 + 1) }); // PUSH1 (i*2+1)
        try bytecode.append(0x50); // POP
    }
    
    // Fill in conditional jumps
    var pos = start_pos;
    for (0..50) |i| {
        // Condition
        bytecode.items[pos] = 0x60; // PUSH1
        bytecode.items[pos + 1] = @intCast(i % 2); // Alternate 0/1
        pos += 2;
        
        // Destination
        const dest = if (i % 2 == 0) else_dests.items[i] else if_dests.items[i];
        bytecode.items[pos] = 0x61; // PUSH2
        bytecode.items[pos + 1] = @intCast(dest >> 8);
        bytecode.items[pos + 2] = @intCast(dest & 0xFF);
        pos += 3;
        
        // JUMPI
        bytecode.items[pos] = 0x57;
        pos += 1;
        
        // Continue to next
        bytecode.items[pos] = 0x5b; // JUMPDEST
        pos += 1;
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateJumpTablePattern(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Simulate switch statement with jump table
    const case_count = 20;
    var case_dests = std.ArrayList(usize).init(allocator);
    defer case_dests.deinit();
    
    // Input value (simulate switch variable)
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x00 }); // PUSH1 0
    try bytecode.append(0x35); // CALLDATALOAD
    
    // Jump table implementation
    for (0..case_count) |i| {
        // Check if equal to case value
        try bytecode.append(0x80); // DUP1
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
        try bytecode.append(0x14); // EQ
        
        // Jump to case if equal
        const case_dest = bytecode.items.len + 200 + (i * 5); // Pre-calculate destinations
        try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
        try bytecode.append(@intCast(case_dest >> 8));
        try bytecode.append(@intCast(case_dest & 0xFF));
        try bytecode.append(0x57); // JUMPI
    }
    
    // Default case
    try bytecode.append(0x50); // POP
    try bytecode.append(0x00); // STOP
    
    // Case implementations
    for (0..case_count) |i| {
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 10) }); // PUSH1 (i*10)
        try bytecode.append(0x50); // POP
        try bytecode.append(0x00); // STOP
    }
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateLoopPattern(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Classic for loop with static jumps
    
    // Initialize counter
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x00 }); // PUSH1 0
    
    // Loop start
    const loop_start = bytecode.items.len;
    try bytecode.append(0x5b); // JUMPDEST
    
    // Loop body
    try bytecode.append(0x80); // DUP1
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x0A }); // PUSH1 10
    try bytecode.append(0x02); // MUL
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x05 }); // PUSH1 5
    try bytecode.append(0x01); // ADD
    try bytecode.append(0x50); // POP
    
    // Increment counter
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    try bytecode.append(0x01); // ADD
    
    // Check condition
    try bytecode.append(0x80); // DUP1
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x64 }); // PUSH1 100
    try bytecode.append(0x10); // LT
    
    // Jump back if condition true
    try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
    try bytecode.append(@intCast(loop_start >> 8));
    try bytecode.append(@intCast(loop_start & 0xFF));
    try bytecode.append(0x57); // JUMPI
    
    // Cleanup and exit
    try bytecode.append(0x50); // POP
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateFunctionCallPattern(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Simulate function calls with return addresses
    
    // Main function
    const main_start = bytecode.items.len;
    
    // Call function 1
    const return1 = main_start + 10;
    try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2 (return address)
    try bytecode.append(@intCast(return1 >> 8));
    try bytecode.append(@intCast(return1 & 0xFF));
    const func1 = main_start + 50;
    try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2 (function address)
    try bytecode.append(@intCast(func1 >> 8));
    try bytecode.append(@intCast(func1 & 0xFF));
    try bytecode.append(0x56); // JUMP
    
    // Return point 1
    try bytecode.append(0x5b); // JUMPDEST
    
    // Call function 2
    const return2 = bytecode.items.len + 10;
    try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2 (return address)
    try bytecode.append(@intCast(return2 >> 8));
    try bytecode.append(@intCast(return2 & 0xFF));
    const func2 = main_start + 80;
    try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2 (function address)
    try bytecode.append(@intCast(func2 >> 8));
    try bytecode.append(@intCast(func2 & 0xFF));
    try bytecode.append(0x56); // JUMP
    
    // Return point 2
    try bytecode.append(0x5b); // JUMPDEST
    try bytecode.append(0x00); // STOP
    
    // Pad to function 1
    while (bytecode.items.len < func1) {
        try bytecode.append(0x00);
    }
    
    // Function 1
    try bytecode.append(0x5b); // JUMPDEST
    try bytecode.appendSlice(&[_]u8{ 0x60, 0xAA }); // PUSH1 170
    try bytecode.append(0x50); // POP
    try bytecode.append(0x56); // JUMP (return)
    
    // Pad to function 2
    while (bytecode.items.len < func2) {
        try bytecode.append(0x00);
    }
    
    // Function 2
    try bytecode.append(0x5b); // JUMPDEST
    try bytecode.appendSlice(&[_]u8{ 0x60, 0xBB }); // PUSH1 187
    try bytecode.append(0x50); // POP
    try bytecode.append(0x56); // JUMP (return)
    
    return allocator.dupe(u8, bytecode.items);
}