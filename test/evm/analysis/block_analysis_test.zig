const std = @import("std");
const CodeAnalysis = @import("evm").frame.CodeAnalysis;
const opcode = @import("evm").opcodes.opcode;
const testing = std.testing;

// Helper to create bytecode easily
fn bytecode(ops: []const u8) []const u8 {
    return ops;
}

fn push1(value: u8) [2]u8 {
    return .{ @intFromEnum(opcode.Enum.PUSH1), value };
}

fn push2(value: u16) [3]u8 {
    return .{ @intFromEnum(opcode.Enum.PUSH2), @intCast(value >> 8), @intCast(value & 0xFF) };
}

fn push32(value: u256) [33]u8 {
    var result: [33]u8 = undefined;
    result[0] = @intFromEnum(opcode.Enum.PUSH32);
    var i: usize = 1;
    while (i <= 32) : (i += 1) {
        result[i] = @intCast((value >> @intCast((32 - i) * 8)) & 0xFF);
    }
    return result;
}

test "analysis - example1" {
    // EVMOne test: push(0x2a) + push(0x1e) + OP_MSTORE8 + OP_MSIZE + push(0) + OP_SSTORE
    const allocator = testing.allocator;
    
    const code = push1(0x2a) ++ push1(0x1e) ++ 
        bytecode(&[_]u8{@intFromEnum(opcode.Enum.MSTORE8)}) ++
        bytecode(&[_]u8{@intFromEnum(opcode.Enum.MSIZE)}) ++
        push1(0) ++
        bytecode(&[_]u8{@intFromEnum(opcode.Enum.SSTORE)});
        
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, &code);
    defer analysis.deinit(allocator);
    
    // Should have 1 block
    try testing.expectEqual(@as(u16, 1), analysis.block_count);
    
    const block = &analysis.block_metadata[0];
    // Gas costs: PUSH1(3) + PUSH1(3) + MSTORE8(3) + MSIZE(2) + PUSH1(3) + SSTORE(100 in old EVM)
    // For size optimization we might use lower SSTORE cost
    try testing.expect(block.gas_cost >= 14);
    try testing.expectEqual(@as(i16, 0), block.stack_req);
    try testing.expectEqual(@as(i16, 2), block.stack_max); // Peak at 2 items before MSTORE8
}

test "analysis - stack up and down" {
    // EVMOne test: OP_DUP2 + 6 * OP_DUP1 + 10 * OP_POP + push(0)
    const allocator = testing.allocator;
    
    var code_list = std.ArrayList(u8).init(allocator);
    defer code_list.deinit();
    
    // DUP2
    try code_list.append(@intFromEnum(opcode.Enum.DUP2));
    
    // 6 * DUP1
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try code_list.append(@intFromEnum(opcode.Enum.DUP1));
    }
    
    // 10 * POP
    i = 0;
    while (i < 10) : (i += 1) {
        try code_list.append(@intFromEnum(opcode.Enum.POP));
    }
    
    // push(0)
    try code_list.appendSlice(&push1(0));
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code_list.items);
    defer analysis.deinit(allocator);
    
    try testing.expectEqual(@as(u16, 1), analysis.block_count);
    
    const block = &analysis.block_metadata[0];
    // Gas: DUP2(3) + 6*DUP1(3) + 10*POP(2) + PUSH1(3) = 3 + 18 + 20 + 3 = 44
    try testing.expectEqual(@as(u32, 44), block.gas_cost);
    // DUP2 needs 2 items on stack, DUP1 needs 1
    try testing.expectEqual(@as(i16, 2), block.stack_req);
    // Stack grows by 7 (1 from DUP2 + 6 from DUP1s) then shrinks by 10, then +1
    try testing.expectEqual(@as(i16, 7), block.stack_max);
}

test "analysis - jumpdest skip" {
    // If the JUMPDEST is the first instruction in a basic block it should be just omitted
    // and no new block should be created in this place.
    const allocator = testing.allocator;
    
    const code = bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.STOP),
        @intFromEnum(opcode.Enum.JUMPDEST),
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should have 2 blocks: [STOP] and [JUMPDEST]
    try testing.expectEqual(@as(u16, 2), analysis.block_count);
    
    // JUMPDEST should be marked
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(1));
}

test "analysis - jump dead code" {
    // push(6) + JUMP + 3 * ADD + JUMPDEST
    const allocator = testing.allocator;
    
    const code = push1(6) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.JUMP),
        @intFromEnum(opcode.Enum.ADD),
        @intFromEnum(opcode.Enum.ADD),
        @intFromEnum(opcode.Enum.ADD),
        @intFromEnum(opcode.Enum.JUMPDEST),
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should have 2 blocks (dead code is skipped)
    try testing.expectEqual(@as(u16, 2), analysis.block_count);
    
    // First block: PUSH1 + JUMP
    try testing.expectEqual(@as(u32, 3 + 8), analysis.block_metadata[0].gas_cost);
    
    // JUMPDEST at offset 6
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(6));
}

test "analysis - jumpi creates new block" {
    // push(0) + JUMPI + JUMPDEST
    const allocator = testing.allocator;
    
    const code = push1(0) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.JUMPI),
        @intFromEnum(opcode.Enum.JUMPDEST),
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should have 3 blocks:
    // Block 0: PUSH1 + JUMPI
    // Block 1: empty (fall-through from JUMPI)
    // Block 2: JUMPDEST
    try testing.expectEqual(@as(u16, 3), analysis.block_count);
    
    // First block gas: PUSH1(3) + JUMPI(10) = 13
    try testing.expectEqual(@as(u32, 13), analysis.block_metadata[0].gas_cost);
    
    // Second block (empty) should have 0 gas
    try testing.expectEqual(@as(u32, 0), analysis.block_metadata[1].gas_cost);
    
    // Third block: just JUMPDEST
    try testing.expectEqual(@as(u32, 1), analysis.block_metadata[2].gas_cost);
}

test "analysis - multiple jumpdests" {
    // Test multiple JUMPDESTs in sequence
    const allocator = testing.allocator;
    
    const code = bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.JUMPDEST),
        @intFromEnum(opcode.Enum.JUMPDEST),
        @intFromEnum(opcode.Enum.JUMPDEST),
    }) ++ push1(1) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.JUMPDEST),
        @intFromEnum(opcode.Enum.JUMPDEST),
        @intFromEnum(opcode.Enum.JUMPDEST),
    }) ++ push1(2) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.JUMPI),
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Verify all JUMPDESTs are marked
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(0));
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(1));
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(2));
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(5));
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(6));
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(7));
}

test "analysis - empty code" {
    const allocator = testing.allocator;
    
    const code = bytecode(&[_]u8{});
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Empty code should have 0 blocks
    try testing.expectEqual(@as(u16, 0), analysis.block_count);
}

test "analysis - only jumpdest" {
    const allocator = testing.allocator;
    
    const code = bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMPDEST)});
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    try testing.expectEqual(@as(u16, 1), analysis.block_count);
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(0));
}

test "analysis - terminated last block" {
    // Even if the last basic block is properly terminated an additional artificial block
    // might be created with only STOP instruction.
    const allocator = testing.allocator;
    
    const code = push1(0) ++ push1(0) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.RETURN),
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should have 1 block
    try testing.expectEqual(@as(u16, 1), analysis.block_count);
}

test "analysis - push value storage" {
    const allocator = testing.allocator;
    
    // Test different PUSH sizes
    const code = push1(0x42) ++ 
        push2(0x1234) ++
        push32(0xDEADBEEFCAFEBABE);
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    try testing.expectEqual(@as(u16, 1), analysis.block_count);
    
    // Verify PC to block mapping for PUSH data
    // PUSH1: PC 0-1
    try testing.expectEqual(@as(u16, 0), analysis.pc_to_block[0]);
    try testing.expectEqual(@as(u16, 0), analysis.pc_to_block[1]);
    
    // PUSH2: PC 2-4
    try testing.expectEqual(@as(u16, 0), analysis.pc_to_block[2]);
    try testing.expectEqual(@as(u16, 0), analysis.pc_to_block[3]);
    try testing.expectEqual(@as(u16, 0), analysis.pc_to_block[4]);
    
    // PUSH32: PC 5-37
    try testing.expectEqual(@as(u16, 0), analysis.pc_to_block[5]);
    try testing.expectEqual(@as(u16, 0), analysis.pc_to_block[36]);
}

test "analysis - complex control flow" {
    // Test a more complex control flow with multiple jumps
    const allocator = testing.allocator;
    
    // Structure:
    // 0: PUSH1 10
    // 2: JUMPI      (conditional jump to 10)
    // 3: PUSH1 5
    // 5: JUMP       (unconditional jump to 10)
    // 6: JUMPDEST   (dead code)
    // 7: PUSH1 99
    // 9: STOP
    // 10: JUMPDEST  (jump target)
    // 11: PUSH1 42
    // 13: STOP
    
    const code = push1(10) ++ bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMPI)}) ++
        push1(5) ++ bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMP)}) ++
        bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMPDEST)}) ++
        push1(99) ++ bytecode(&[_]u8{@intFromEnum(opcode.Enum.STOP)}) ++
        bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMPDEST)}) ++
        push1(42) ++ bytecode(&[_]u8{@intFromEnum(opcode.Enum.STOP)});
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should have multiple blocks
    try testing.expect(analysis.block_count >= 3);
    
    // Verify jump destinations
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(6));  // Dead JUMPDEST
    try testing.expect(analysis.jumpdest_bitmap.isSetUnchecked(10)); // Live JUMPDEST
}

test "analysis - all terminating opcodes" {
    // Test that all terminating opcodes properly end blocks
    const allocator = testing.allocator;
    
    const terminating_ops = [_]opcode.Enum{
        .STOP,
        .RETURN,
        .REVERT,
        .INVALID,
        .SELFDESTRUCT,
    };
    
    for (terminating_ops) |op| {
        const code = bytecode(&[_]u8{@intFromEnum(op)}) ++ 
            bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMPDEST)});
        
        var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
        defer analysis.deinit(allocator);
        
        // Should create a new block after terminating instruction
        try testing.expectEqual(@as(u16, 2), analysis.block_count);
    }
}

test "analysis - stack validation edge cases" {
    const allocator = testing.allocator;
    
    // Test underflow case: ADD needs 2 items but starts with 0
    const underflow_code = bytecode(&[_]u8{@intFromEnum(opcode.Enum.ADD)});
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, underflow_code);
    defer analysis.deinit(allocator);
    
    try testing.expectEqual(@as(u16, 1), analysis.block_count);
    try testing.expectEqual(@as(i16, 2), analysis.block_metadata[0].stack_req);
    
    // Test maximum stack growth
    var max_stack_code = std.ArrayList(u8).init(allocator);
    defer max_stack_code.deinit();
    
    // Push 100 values
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try max_stack_code.appendSlice(&push1(@intCast(i)));
    }
    
    var analysis2 = try CodeAnalysis.analyze_bytecode_blocks(allocator, max_stack_code.items);
    defer analysis2.deinit(allocator);
    
    try testing.expectEqual(@as(u16, 1), analysis2.block_count);
    try testing.expectEqual(@as(i16, 0), analysis2.block_metadata[0].stack_req);
    try testing.expectEqual(@as(i16, 100), analysis2.block_metadata[0].stack_max);
}

test "analysis - gas calculation accuracy" {
    const allocator = testing.allocator;
    
    // Test specific gas costs
    const code = bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.ADD),        // 3 gas
        @intFromEnum(opcode.Enum.MUL),        // 5 gas
        @intFromEnum(opcode.Enum.SUB),        // 3 gas
        @intFromEnum(opcode.Enum.DIV),        // 5 gas
        @intFromEnum(opcode.Enum.SDIV),       // 5 gas
        @intFromEnum(opcode.Enum.MOD),        // 5 gas
        @intFromEnum(opcode.Enum.SMOD),       // 5 gas
        @intFromEnum(opcode.Enum.ADDMOD),     // 8 gas
        @intFromEnum(opcode.Enum.MULMOD),     // 8 gas
        @intFromEnum(opcode.Enum.EXP),        // 10 gas (base)
        @intFromEnum(opcode.Enum.SIGNEXTEND), // 5 gas
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    try testing.expectEqual(@as(u16, 1), analysis.block_count);
    // Total: 3+5+3+5+5+5+5+8+8+10+5 = 62 gas
    try testing.expectEqual(@as(u32, 62), analysis.block_metadata[0].gas_cost);
}

test "analysis - create operations tracking" {
    const allocator = testing.allocator;
    
    const code = push1(0) ++ push1(0) ++ push1(0) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.CREATE),
    }) ++ push1(0) ++ push1(0) ++ push1(0) ++ push1(0) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.CREATE2),
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should track that contract has CREATE operations
    try testing.expect(analysis.has_create);
}

test "analysis - selfdestruct tracking" {
    const allocator = testing.allocator;
    
    const code = push1(0) ++ bytecode(&[_]u8{
        @intFromEnum(opcode.Enum.SELFDESTRUCT),
    });
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should track that contract has SELFDESTRUCT
    try testing.expect(analysis.has_selfdestruct);
}

test "analysis - pc to block mapping completeness" {
    const allocator = testing.allocator;
    
    // Complex code with multiple blocks
    const code = push1(8) ++ bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMPI)}) ++
        push1(42) ++ bytecode(&[_]u8{@intFromEnum(opcode.Enum.STOP)}) ++
        bytecode(&[_]u8{@intFromEnum(opcode.Enum.JUMPDEST)}) ++
        push1(99) ++ bytecode(&[_]u8{@intFromEnum(opcode.Enum.STOP)});
    
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Every PC should map to a valid block
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const block_idx = analysis.pc_to_block[i];
        try testing.expect(block_idx < analysis.block_count);
    }
}