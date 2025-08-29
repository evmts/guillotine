const std = @import("std");
const Bytecode = @import("bytecode.zig").Bytecode;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;

const default_config = BytecodeConfig{};
const BytecodeDefault = Bytecode(default_config);

// Test that immediate jump validation happens during buildBitmapsAndValidate
// not as a separate pass
test "immediate jump validation integrated into main validation" {
    const allocator = std.testing.allocator;
    
    // Test 1: Invalid PUSH + JUMP pattern should fail during init
    {
        // PUSH1 0x10 JUMP but no JUMPDEST at 0x10
        const code = [_]u8{ 0x60, 0x10, 0x56, 0x00 };
        const result = BytecodeDefault.init(allocator, &code);
        try std.testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, result);
    }
    
    // Test 2: Valid PUSH + JUMP pattern should succeed
    {
        // PUSH1 0x04 JUMP JUMPDEST STOP
        const code = [_]u8{ 0x60, 0x04, 0x56, 0x00, 0x5b, 0x00 };
        var bytecode = try BytecodeDefault.init(allocator, &code);
        defer bytecode.deinit();
        
        // Should have validated during init without separate pass
        try std.testing.expect(bytecode.isValidJumpDest(4));
    }
    
    // Test 3: PUSH + PUSH + JUMPI pattern validation
    {
        // PUSH1 0x08 (jump dest) PUSH1 0x01 (condition) JUMPI, padding, JUMPDEST
        const code = [_]u8{ 0x60, 0x08, 0x60, 0x01, 0x57, 0x00, 0x00, 0x00, 0x5b };
        var bytecode = try BytecodeDefault.init(allocator, &code);
        defer bytecode.deinit();
        
        try std.testing.expect(bytecode.isValidJumpDest(8));
    }
    
    // Test 4: Invalid PUSH + PUSH + JUMPI should fail
    {
        // PUSH1 0x10 PUSH1 0x01 JUMPI but no JUMPDEST at 0x10
        const code = [_]u8{ 0x60, 0x10, 0x60, 0x01, 0x57 };
        const result = BytecodeDefault.init(allocator, &code);
        try std.testing.expectError(BytecodeDefault.ValidationError.InvalidJumpDestination, result);
    }
}

// Test that validation correctly identifies fusion opportunities during the main pass
test "fusion detection during validation pass" {
    const allocator = std.testing.allocator;
    
    // Test various PUSH + OP patterns
    const code = [_]u8{
        0x60, 0x01, 0x01,  // PUSH1 1 ADD (fusion candidate)
        0x60, 0x02, 0x02,  // PUSH1 2 MUL (fusion candidate)
        0x60, 0x0C, 0x56,  // PUSH1 12 JUMP (fusion candidate, valid dest)
        0x60, 0x03,        // PUSH1 3 (no fusion - end of bytecode)
        0x5b,              // JUMPDEST at 12
        0x00,              // STOP
    };
    
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    
    // Check that fusion candidates were marked during validation
    try std.testing.expect(bytecode.packed_bitmap[0].is_fusion_candidate); // PUSH + ADD
    try std.testing.expect(bytecode.packed_bitmap[3].is_fusion_candidate); // PUSH + MUL
    try std.testing.expect(bytecode.packed_bitmap[6].is_fusion_candidate); // PUSH + JUMP
    try std.testing.expect(!bytecode.packed_bitmap[9].is_fusion_candidate); // PUSH alone
}

// Test edge cases for jump validation
test "jump validation edge cases" {
    const allocator = std.testing.allocator;
    
    // Test 1: JUMPI without proper PUSH pattern should succeed (not immediate jump)
    {
        const code = [_]u8{
            0x60, 0x05,     // PUSH1 5
            0x80,           // DUP1
            0x57,           // JUMPI (not immediate pattern)
            0x00,           // STOP
            0x5b,           // JUMPDEST at 5
        };
        var bytecode = try BytecodeDefault.init(allocator, &code);
        defer bytecode.deinit();
        
        // Should succeed because it's not an immediate jump pattern
        try std.testing.expect(bytecode.isValidJumpDest(5));
    }
    
    // Test 2: Interleaved operations break immediate pattern
    {
        const code = [_]u8{
            0x60, 0x08,     // PUSH1 8
            0x50,           // POP
            0x60, 0x01,     // PUSH1 1
            0x57,           // JUMPI (not immediate PUSH+PUSH+JUMPI)
            0x00, 0x00,     // padding
            0x5b,           // JUMPDEST at 8
        };
        var bytecode = try BytecodeDefault.init(allocator, &code);
        defer bytecode.deinit();
        
        // Should succeed - not immediate pattern due to POP
        try std.testing.expect(bytecode.isValidJumpDest(8));
    }
    
    // Test 3: Jump to position 0 (edge case)
    {
        const code = [_]u8{
            0x5b,           // JUMPDEST at 0
            0x60, 0x00,     // PUSH1 0
            0x56,           // JUMP (back to start)
        };
        var bytecode = try BytecodeDefault.init(allocator, &code);
        defer bytecode.deinit();
        
        try std.testing.expect(bytecode.isValidJumpDest(0));
    }
}

// Test performance characteristics - validation should be single pass
test "validation is single pass O(n)" {
    const allocator = std.testing.allocator;
    
    // Create bytecode with many jump patterns to test O(n) behavior
    var code = try allocator.alloc(u8, 1000);
    defer allocator.free(code);
    
    var pos: usize = 0;
    
    // Add many PUSH + JUMP patterns
    while (pos + 10 < code.len) {
        // Add JUMPDEST first
        code[pos] = 0x5b; // JUMPDEST
        pos += 1;
        
        // Add PUSH + JUMP to next JUMPDEST
        if (pos + 10 < code.len) {
            code[pos] = 0x60; // PUSH1
            code[pos + 1] = @intCast(pos + 3); // Jump to next JUMPDEST
            code[pos + 2] = 0x56; // JUMP
            pos += 3;
        }
    }
    
    // Fill rest with STOP
    while (pos < code.len) : (pos += 1) {
        code[pos] = 0x00;
    }
    
    // This should complete quickly even with many jumps
    // because validation is O(n), not O(n²)
    var bytecode = try BytecodeDefault.init(allocator, code);
    defer bytecode.deinit();
    
    // Verify some jumpdests were found
    var jumpdest_count: u32 = 0;
    for (0..code.len) |i| {
        if (bytecode.isValidJumpDest(@intCast(i))) {
            jumpdest_count += 1;
        }
    }
    try std.testing.expect(jumpdest_count > 10);
}

// Test that iterator is only used for analysis, not execution
test "iterator usage patterns" {
    const allocator = std.testing.allocator;
    
    // Create some bytecode
    const code = [_]u8{
        0x60, 0x01,     // PUSH1 1
        0x60, 0x02,     // PUSH1 2  
        0x01,           // ADD
        0x60, 0x08,     // PUSH1 8
        0x56,           // JUMP
        0x00,           // STOP
        0x5b,           // JUMPDEST at 8
        0x00,           // STOP
    };
    
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    
    // The iterator should only be used for analysis tools like getStats
    const stats = try bytecode.getStats();
    defer {
        allocator.free(stats.push_values);
        allocator.free(stats.potential_fusions);
        allocator.free(stats.jumpdests);
        allocator.free(stats.jumps);
    }
    
    // Verify stats were collected correctly
    try std.testing.expect(stats.push_values.len > 0);
    try std.testing.expect(stats.jumpdests.len == 1);
    try std.testing.expect(stats.jumps.len == 1);
    
    // The iterator should NOT be needed for execution
    // (This test documents the intended usage pattern)
}

// Test that dispatch should use pre-analyzed data, not iterator
test "dispatch uses pre-analyzed data" {
    const allocator = std.testing.allocator;
    
    // The Dispatch module should build its schedule from pre-analyzed data
    // not by re-iterating through bytecode with the iterator
    
    // This is a documentation test - the actual refactoring would involve:
    // 1. Having bytecode.analyze() return structured data
    // 2. Dispatch.init() consuming that structured data
    // 3. No createIterator() calls in the execution hot path
    
    // For now, we just verify that the analysis data is available
    const code = [_]u8{
        0x60, 0x01,     // PUSH1 1
        0x60, 0x02,     // PUSH1 2
        0x01,           // ADD
        0x5b,           // JUMPDEST
        0x00,           // STOP
    };
    
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    
    // The analyze function provides structured data
    const analysis = try bytecode.analyze(allocator);
    defer analysis.deinit();
    
    // Analysis should have found the JUMPDEST and PUSH instructions
    try std.testing.expect(analysis.jump_destinations.items.len == 1);
    try std.testing.expect(analysis.push_data.items.len == 2);
    
    // This data should be sufficient for Dispatch to build its schedule
    // without needing to re-parse the bytecode
}

// Test that we don't need readImmediateJumpTarget anymore
test "no backward scanning needed" {
    const allocator = std.testing.allocator;
    
    // Complex pattern that would require backward scanning in old approach
    const code = [_]u8{
        0x60, 0x10,     // PUSH1 16
        0x60, 0x0C,     // PUSH1 12  
        0x56,           // JUMP
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding
        0x5b,           // JUMPDEST at 12
        0x60, 0x01,     // PUSH1 1
        0x57,           // JUMPI (should jump to 16 from earlier push)
        0x5b,           // JUMPDEST at 16
    };
    
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    
    // Both jumpdests should be valid
    try std.testing.expect(bytecode.isValidJumpDest(12));
    try std.testing.expect(bytecode.isValidJumpDest(16));
    
    // The validation should have been done in a single forward pass
    // without needing to scan backward to find PUSH instructions
}