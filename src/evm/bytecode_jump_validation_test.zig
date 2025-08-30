const std = @import("std");
const testing = std.testing;
const BytecodeDefault = @import("bytecode.zig").BytecodeDefault;
const Opcode = @import("opcode.zig").Opcode;

test "bytecode: valid PUSH1+JUMP pattern with JUMPDEST" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 0x04, JUMP, STOP, JUMPDEST
    const bytecode = [_]u8{
        0x60, 0x04,  // PUSH1 4
        0x56,        // JUMP
        0x00,        // STOP
        0x5b,        // JUMPDEST (at position 4)
    };
    
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    // Should initialize successfully
    try testing.expect(bc.runtime_code.len == bytecode.len);
}

test "bytecode: PUSH2+JUMP pattern with valid JUMPDEST" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH2 0x0005, JUMP, STOP, JUMPDEST
    const bytecode = [_]u8{
        0x61, 0x00, 0x05,  // PUSH2 5
        0x56,              // JUMP
        0x00,              // STOP
        0x5b,              // JUMPDEST (at position 5)
    };
    
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try testing.expect(bc.runtime_code.len == bytecode.len);
}

test "bytecode: PUSH+PUSH+JUMPI pattern with valid JUMPDEST" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 dest, PUSH1 condition, JUMPI, STOP, JUMPDEST
    const bytecode = [_]u8{
        0x60, 0x06,  // PUSH1 6 (jump destination)
        0x60, 0x01,  // PUSH1 1 (condition)
        0x57,        // JUMPI
        0x00,        // STOP
        0x5b,        // JUMPDEST (at position 6)
    };
    
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try testing.expect(bc.runtime_code.len == bytecode.len);
}

test "bytecode: PUSH32 containing JUMP byte should not be detected as JUMP" {
    const allocator = testing.allocator;
    
    // PUSH32 with data that contains 0x56 (JUMP opcode value) followed by actual code
    const bytecode = [_]u8{
        0x7f, // PUSH32
        // 32 bytes of data, including 0x56 at various positions
        0x11, 0x22, 0x33, 0x44, 0x56, 0x66, 0x77, 0x88,  // 0x56 at position 5
        0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x56,  // 0x56 at position 32
        0x00, // STOP (at position 33)
    };
    
    // This should succeed - the 0x56 bytes inside PUSH32 data should NOT be treated as JUMP opcodes
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error initializing bytecode with PUSH32 containing 0x56: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try testing.expect(bc.runtime_code.len == bytecode.len);
    
    // Verify that position 5 is marked as push data, not an opcode
    try testing.expect(bc.isPushData(5));
    
    // Verify that position 33 (STOP) is an opcode start
    try testing.expect(bc.isOpStart(33));
}

test "bytecode: PUSH4 with value that looks like JUMP target should not validate" {
    const allocator = testing.allocator;
    
    // PUSH4 where the data bytes happen to be: 00 00 01 56 (where 56 is JUMP opcode)
    // This should NOT be interpreted as PUSH + JUMP
    const bytecode = [_]u8{
        0x63,              // PUSH4
        0x00, 0x00, 0x01, 0x56,  // 4 bytes of data (last byte happens to be 0x56)
        0x00,              // STOP
    };
    
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    // Should succeed - the 0x56 is data, not a JUMP opcode
    try testing.expect(bc.runtime_code.len == bytecode.len);
    
    // Verify positions 1-4 are push data
    try testing.expect(bc.isPushData(1));
    try testing.expect(bc.isPushData(2));
    try testing.expect(bc.isPushData(3));
    try testing.expect(bc.isPushData(4));
    
    // Position 5 should be the STOP opcode
    try testing.expect(bc.isOpStart(5));
}

test "bytecode: complex bytecode with mixed PUSH and JUMP patterns" {
    const allocator = testing.allocator;
    
    // Complex pattern:
    // PUSH1 0x08, JUMP, PUSH2 with 0x56 in data, JUMPDEST, STOP
    const bytecode = [_]u8{
        0x60, 0x08,        // PUSH1 8 (valid jump to JUMPDEST)
        0x56,              // JUMP (actual JUMP opcode at position 2)
        0x61, 0x56, 0x78,  // PUSH2 0x5678 (contains 0x56 as data at position 4)
        0x00,              // STOP at position 6
        0x00,              // STOP at position 7
        0x5b,              // JUMPDEST at position 8
        0x00,              // STOP at position 9
    };
    
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error in complex bytecode test: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try testing.expect(bc.runtime_code.len == bytecode.len);
    
    // Position 2 should be a real JUMP opcode
    try testing.expect(bc.isOpStart(2));
    
    // Position 4 should be push data (even though it's 0x56)
    try testing.expect(bc.isPushData(4));
    
    // Position 8 should be JUMPDEST
    try testing.expect(bc.isJumpDest(8));
}

test "bytecode: unreachable PUSH+JUMP pattern should still be valid" {
    const allocator = testing.allocator;
    
    // Bytecode with unreachable code that contains PUSH+JUMP
    const bytecode = [_]u8{
        0x00,        // STOP - execution ends here
        // Unreachable code below:
        0x60, 0x10,  // PUSH1 16 (target doesn't exist)
        0x56,        // JUMP
        0x00,        // STOP
    };
    
    // This should succeed even though the jump target (16) doesn't exist,
    // because the PUSH+JUMP is unreachable
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error with unreachable code: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try testing.expect(bc.runtime_code.len == bytecode.len);
}

test "bytecode: PUSH1+JUMP with out-of-bounds target should succeed at init" {
    const allocator = testing.allocator;
    
    // PUSH1 with target beyond bytecode length
    const bytecode = [_]u8{
        0x60, 0xFF,  // PUSH1 255 (way beyond bytecode length)
        0x56,        // JUMP
        0x00,        // STOP
    };
    
    // Should succeed at initialization (validation happens at runtime)
    const bc = BytecodeDefault.init(allocator, &bytecode) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return err;
    };
    defer bc.deinit();
    
    try testing.expect(bc.runtime_code.len == bytecode.len);
}