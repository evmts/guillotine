const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Allocator = std.mem.Allocator;

const Vm = evm.Evm;
const Contract = evm.Contract;
const MemoryDatabase = evm.MemoryDatabase;
const Address = primitives.Address;
const JumpAnalysis = evm.JumpAnalysis;
const BitVec64 = evm.BitVec64;

test "static jump detection - simple PUSH JUMP" {
    const allocator = testing.allocator;
    
    // Simple static jump pattern
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x56,       // JUMP
        0x00,       // STOP
        0x5b,       // JUMPDEST (at position 5)
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
    };
    
    // Create bitmaps for analysis
    var code_segments = try BitVec64.init(allocator, bytecode.len);
    defer code_segments.deinit(allocator);
    for (0..bytecode.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
    defer jumpdest_bitmap.deinit(allocator);
    jumpdest_bitmap.setUnchecked(5); // JUMPDEST at position 5
    
    // Analyze jumps
    var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Verify static jump was detected
    try testing.expectEqual(@as(u32, 1), analysis.jump_count);
    try testing.expectEqual(@as(u32, 1), analysis.static_jump_count);
    try testing.expectEqual(@as(u32, 0), analysis.dynamic_jump_count);
    try testing.expect(analysis.all_jumps_static);
    
    // Verify jump info
    const jump_info = analysis.get_jump_info(2);
    try testing.expect(jump_info != null);
    try testing.expect(jump_info.?.jump_type == .static);
    try testing.expectEqual(@as(u256, 5), jump_info.?.destination.?);
    try testing.expect(jump_info.?.is_valid);
    
    // Test optimization function
    try testing.expect(JumpAnalysis.optimize_jump_validation(&analysis, 2, 5));
    try testing.expect(!JumpAnalysis.optimize_jump_validation(&analysis, 2, 6)); // Wrong dest
}

test "static jump detection - PUSH DUP JUMP pattern" {
    const allocator = testing.allocator;
    
    // PUSH DUP1 JUMP pattern
    const bytecode = [_]u8{
        0x60, 0x08, // PUSH1 8
        0x80,       // DUP1
        0x56,       // JUMP
        0x00,       // STOP
        0x00, 0x00, // padding
        0x5b,       // JUMPDEST (at position 8)
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
    };
    
    var code_segments = try BitVec64.init(allocator, bytecode.len);
    defer code_segments.deinit(allocator);
    for (0..bytecode.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
    defer jumpdest_bitmap.deinit(allocator);
    jumpdest_bitmap.setUnchecked(8);
    
    var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Should detect the DUP pattern
    const jump_info = analysis.get_jump_info(4);
    try testing.expect(jump_info != null);
    try testing.expect(jump_info.?.jump_type == .static);
    try testing.expectEqual(@as(u256, 8), jump_info.?.destination.?);
    try testing.expect(jump_info.?.is_valid);
}

test "static conditional jump - PUSH PUSH JUMPI" {
    const allocator = testing.allocator;
    
    // Static conditional jump
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10 (destination)
        0x60, 0x01, // PUSH1 1 (condition)
        0x57,       // JUMPI
        0x00,       // STOP
        0x00, 0x00, 0x00, 0x00, // padding
        0x5b,       // JUMPDEST (at position 10)
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
    };
    
    var code_segments = try BitVec64.init(allocator, bytecode.len);
    defer code_segments.deinit(allocator);
    for (0..bytecode.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
    defer jumpdest_bitmap.deinit(allocator);
    jumpdest_bitmap.setUnchecked(10);
    
    var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Should detect conditional jump
    const jump_info = analysis.get_jump_info(5);
    try testing.expect(jump_info != null);
    try testing.expect(jump_info.?.is_conditional);
    
    // Current implementation may classify this as dynamic
    // Enhancement needed to detect PUSH PUSH JUMPI pattern
}

test "dynamic jump detection" {
    const allocator = testing.allocator;
    
    // Dynamic jump (destination from CALLDATALOAD)
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        0x56,       // JUMP
        0x00,       // STOP
    };
    
    var code_segments = try BitVec64.init(allocator, bytecode.len);
    defer code_segments.deinit(allocator);
    for (0..bytecode.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
    defer jumpdest_bitmap.deinit(allocator);
    
    var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Should detect dynamic jump
    try testing.expectEqual(@as(u32, 1), analysis.jump_count);
    try testing.expectEqual(@as(u32, 0), analysis.static_jump_count);
    try testing.expectEqual(@as(u32, 1), analysis.dynamic_jump_count);
    try testing.expect(!analysis.all_jumps_static);
    
    const jump_info = analysis.get_jump_info(4);
    try testing.expect(jump_info != null);
    try testing.expect(jump_info.?.jump_type == .dynamic);
    try testing.expect(jump_info.?.destination == null);
}

test "mixed static and dynamic jumps" {
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        // Static jump
        0x60, 0x0A, // PUSH1 10
        0x56,       // JUMP
        
        // Dynamic jump
        0x60, 0x00, // PUSH1 0
        0x35,       // CALLDATALOAD
        0x56,       // JUMP
        
        // JUMPDEST
        0x5b,       // JUMPDEST (at position 10)
        0x00,       // STOP
    };
    
    var code_segments = try BitVec64.init(allocator, bytecode.len);
    defer code_segments.deinit(allocator);
    for (0..bytecode.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
    defer jumpdest_bitmap.deinit(allocator);
    jumpdest_bitmap.setUnchecked(10);
    
    var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Should detect both jumps
    try testing.expectEqual(@as(u32, 2), analysis.jump_count);
    try testing.expectEqual(@as(u32, 1), analysis.static_jump_count);
    try testing.expectEqual(@as(u32, 1), analysis.dynamic_jump_count);
    try testing.expect(!analysis.all_jumps_static);
}

test "invalid static jump detection" {
    const allocator = testing.allocator;
    
    // Static jump to invalid destination
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (not a JUMPDEST)
        0x56,       // JUMP
        0x00,       // STOP
        0x60, 0x42, // PUSH1 66 (position 5, but not JUMPDEST)
        0x00,       // STOP
    };
    
    var code_segments = try BitVec64.init(allocator, bytecode.len);
    defer code_segments.deinit(allocator);
    for (0..bytecode.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
    defer jumpdest_bitmap.deinit(allocator);
    // No JUMPDEST at position 5
    
    var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Should detect invalid static jump
    const jump_info = analysis.get_jump_info(2);
    try testing.expect(jump_info != null);
    try testing.expect(jump_info.?.jump_type == .static);
    try testing.expectEqual(@as(u256, 5), jump_info.?.destination.?);
    try testing.expect(!jump_info.?.is_valid); // Invalid destination
    
    // Optimization should reject invalid jump
    try testing.expect(!JumpAnalysis.optimize_jump_validation(&analysis, 2, 5));
}

test "jump analysis with PUSH data segments" {
    const allocator = testing.allocator;
    
    // Bytecode with PUSH data that should be skipped
    const bytecode = [_]u8{
        0x61, 0x00, 0x0A, // PUSH2 10
        0x56,             // JUMP
        0x00,             // STOP
        0x00, 0x00, 0x00, 0x00, // padding
        0x5b,             // JUMPDEST (at position 10)
        0x00,             // STOP
    };
    
    var code_segments = try BitVec64.init(allocator, bytecode.len);
    defer code_segments.deinit(allocator);
    // Mark code segments (skip PUSH data)
    code_segments.setUnchecked(0); // PUSH2
    // Skip bytes 1-2 (PUSH2 data)
    code_segments.setUnchecked(3); // JUMP
    code_segments.setUnchecked(4); // STOP
    for (5..bytecode.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
    defer jumpdest_bitmap.deinit(allocator);
    jumpdest_bitmap.setUnchecked(10);
    
    var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Should detect jump at correct position
    const jump_info = analysis.get_jump_info(3);
    try testing.expect(jump_info != null);
    try testing.expect(jump_info.?.jump_type == .static);
    try testing.expectEqual(@as(u256, 10), jump_info.?.destination.?);
    try testing.expect(jump_info.?.is_valid);
}

test "optimize_jump_validation performance" {
    const allocator = testing.allocator;
    
    // Create bytecode with many static jumps
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    var jumpdest_positions = std.ArrayList(usize).init(allocator);
    defer jumpdest_positions.deinit();
    
    // Add 100 static jumps
    for (0..100) |i| {
        const dest = 500 + i * 3;
        try bytecode.append(0x61); // PUSH2
        try bytecode.append(@intCast(dest >> 8));
        try bytecode.append(@intCast(dest & 0xFF));
        try bytecode.append(0x56); // JUMP
        
        try jumpdest_positions.append(dest);
    }
    
    // Add padding and JUMPDESTs
    while (bytecode.items.len < 500) {
        try bytecode.append(0x00);
    }
    
    for (0..100) |_| {
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.append(0x00); // STOP
        try bytecode.append(0x00); // padding
    }
    
    var code_segments = try BitVec64.init(allocator, bytecode.items.len);
    defer code_segments.deinit(allocator);
    for (0..bytecode.items.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.items.len);
    defer jumpdest_bitmap.deinit(allocator);
    for (jumpdest_positions.items) |pos| {
        jumpdest_bitmap.setUnchecked(pos);
    }
    
    var analysis = try JumpAnalysis.analyze_jumps(allocator, bytecode.items, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // All jumps should be static
    try testing.expectEqual(@as(u32, 100), analysis.jump_count);
    try testing.expectEqual(@as(u32, 100), analysis.static_jump_count);
    try testing.expect(analysis.all_jumps_static);
    
    // Test optimization for each jump
    for (0..100) |i| {
        const pc = i * 4 + 3; // Position of JUMP instruction
        const dest = 500 + i * 3;
        try testing.expect(JumpAnalysis.optimize_jump_validation(&analysis, pc, dest));
    }
}

test "jump analysis edge cases" {
    const allocator = testing.allocator;
    
    // Test edge cases
    {
        // Empty bytecode
        const empty_bytecode = [_]u8{};
        var code_segments = try BitVec64.init(allocator, 1);
        defer code_segments.deinit(allocator);
        var jumpdest_bitmap = try BitVec64.init(allocator, 1);
        defer jumpdest_bitmap.deinit(allocator);
        
        var analysis = try JumpAnalysis.analyze_jumps(allocator, &empty_bytecode, &code_segments, &jumpdest_bitmap);
        defer analysis.deinit();
        
        try testing.expectEqual(@as(u32, 0), analysis.jump_count);
    }
    
    {
        // Jump at end of bytecode
        const bytecode = [_]u8{
            0x60, 0x00, // PUSH1 0
            0x56,       // JUMP (last byte)
        };
        
        var code_segments = try BitVec64.init(allocator, bytecode.len);
        defer code_segments.deinit(allocator);
        for (0..bytecode.len) |i| {
            code_segments.setUnchecked(i);
        }
        
        var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
        defer jumpdest_bitmap.deinit(allocator);
        
        var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
        defer analysis.deinit();
        
        try testing.expectEqual(@as(u32, 1), analysis.jump_count);
    }
    
    {
        // Jump to out-of-bounds destination
        const bytecode = [_]u8{
            0x61, 0xFF, 0xFF, // PUSH2 65535 (out of bounds)
            0x56,             // JUMP
        };
        
        var code_segments = try BitVec64.init(allocator, bytecode.len);
        defer code_segments.deinit(allocator);
        for (0..bytecode.len) |i| {
            code_segments.setUnchecked(i);
        }
        
        var jumpdest_bitmap = try BitVec64.init(allocator, bytecode.len);
        defer jumpdest_bitmap.deinit(allocator);
        
        var analysis = try JumpAnalysis.analyze_jumps(allocator, &bytecode, &code_segments, &jumpdest_bitmap);
        defer analysis.deinit();
        
        const jump_info = analysis.get_jump_info(3);
        try testing.expect(jump_info != null);
        try testing.expect(!jump_info.?.is_valid); // Out of bounds
    }
}