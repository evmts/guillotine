const std = @import("std");
const Evm = @import("evm");
const BasicBlockAnalysis = Evm.BasicBlockAnalysis;
const testing = std.testing;
const ExecutionError = Evm.ExecutionError;
const Stack = Evm.Stack;

test "basic block analysis improves validation performance" {
    const allocator = testing.allocator;
    
    // Create bytecode with predictable basic blocks
    // Block 1: Initial setup
    // Block 2: Loop body (no jumps)
    // Block 3: Conditional jump creates boundary
    // Block 4: Jump destination
    const bytecode = [_]u8{
        // Block 1: Push initial values
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        
        // Block 2: Arithmetic sequence
        0x01,       // ADD
        0x80,       // DUP1
        0x80,       // DUP1
        0x02,       // MUL
        0x81,       // DUP2
        0x03,       // SUB
        
        // Block 3: Conditional jump (ends block)
        0x60, 0x00, // PUSH1 0
        0x14,       // EQ
        0x60, 0x14, // PUSH1 20 (jump target)
        0x57,       // JUMPI
        
        // Block 4: After conditional
        0x50,       // POP
        0x50,       // POP
        0x00,       // STOP
        
        // Block 5: Jump destination
        0x5b,       // JUMPDEST (PC 20)
        0x60, 0xff, // PUSH1 255
        0x00,       // STOP
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    // Verify correct number of blocks identified
    try testing.expectEqual(@as(usize, 5), analysis.blocks.len);
    
    // Verify block boundaries
    const block1 = analysis.blocks[0];
    try testing.expectEqual(@as(u32, 0), block1.start_pc);
    try testing.expectEqual(@as(u32, 3), block1.end_pc);
    try testing.expectEqual(@as(i16, 2), block1.net_stack_change); // +1 +1 = 2
    
    const block2 = analysis.blocks[1];
    try testing.expectEqual(@as(u32, 4), block2.start_pc);
    try testing.expectEqual(@as(u32, 9), block2.end_pc);
    try testing.expectEqual(@as(u16, 2), block2.min_stack_entry); // Needs 2 for ADD
    try testing.expectEqual(@as(i16, 1), block2.net_stack_change); // -1+1+1-1+1-1 = 1
    
    // Verify jump block
    const block3 = analysis.blocks[2];
    try testing.expect(block3.ends_with_jump);
    
    // Verify terminal blocks
    const block4 = analysis.blocks[3];
    try testing.expect(block4.is_terminal);
    
    const block5 = analysis.blocks[4];
    try testing.expect(block5.is_terminal);
}

test "basic block validation catches stack underflow" {
    const allocator = testing.allocator;
    
    // Bytecode that will underflow if started with empty stack
    const bytecode = [_]u8{
        0x01, // ADD (needs 2 items)
        0x00, // STOP
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    try testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    
    const block = analysis.blocks[0];
    try testing.expectEqual(@as(u16, 2), block.min_stack_entry); // Needs 2 items
    
    // Validation should fail with empty stack
    try testing.expectError(ExecutionError.Error.StackUnderflow, analysis.validateStackAtPc(0, 0));
    try testing.expectError(ExecutionError.Error.StackUnderflow, analysis.validateStackAtPc(0, 1));
    
    // Should succeed with sufficient stack
    try analysis.validateStackAtPc(0, 2);
    try analysis.validateStackAtPc(0, 10);
}

test "basic block validation catches stack overflow" {
    const allocator = testing.allocator;
    
    // Bytecode that pushes many values
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Push 10 values
    for (0..10) |i| {
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
    }
    try bytecode.append(0x00); // STOP
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, bytecode.items);
    defer analysis.deinit();
    
    const block = analysis.blocks[0];
    try testing.expectEqual(@as(i16, 10), block.net_stack_change); // Pushes 10 items
    try testing.expectEqual(@as(u16, Stack.CAPACITY - 10), block.max_stack_entry);
    
    // Should fail if starting with too many items
    try testing.expectError(ExecutionError.Error.StackOverflow, 
        analysis.validateStackAtPc(0, Stack.CAPACITY - 9));
    
    // Should succeed with room for growth
    try analysis.validateStackAtPc(0, Stack.CAPACITY - 10);
    try analysis.validateStackAtPc(0, Stack.CAPACITY - 20);
}

test "basic block analysis handles complex control flow" {
    const allocator = testing.allocator;
    
    // Create bytecode with multiple jumps and branches
    const bytecode = [_]u8{
        // Block 1: Initial jump
        0x60, 0x06, // PUSH1 6
        0x56,       // JUMP
        0xfe,       // INVALID (unreachable)
        
        // Block 2: Jump destination
        0x5b,       // JUMPDEST (PC 5)
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD
        
        // Block 3: Conditional branch
        0x60, 0x03, // PUSH1 3
        0x14,       // EQ
        0x60, 0x14, // PUSH1 20
        0x57,       // JUMPI
        
        // Block 4: Fall-through path
        0x60, 0xff, // PUSH1 255
        0x00,       // STOP
        
        // Block 5: Branch target
        0x5b,       // JUMPDEST (PC 20)
        0x60, 0x42, // PUSH1 66
        0x00,       // STOP
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    // Should identify 6 blocks (including unreachable INVALID)
    try testing.expectEqual(@as(usize, 6), analysis.blocks.len);
    
    // Verify jump blocks
    try testing.expect(analysis.blocks[0].ends_with_jump); // Initial jump
    try testing.expect(analysis.blocks[3].ends_with_jump); // Conditional jump
    
    // Verify terminal blocks
    try testing.expect(analysis.blocks[1].is_terminal); // INVALID
    try testing.expect(analysis.blocks[4].is_terminal); // First STOP
    try testing.expect(analysis.blocks[5].is_terminal); // Second STOP
}

test "basic block gas calculation" {
    const allocator = testing.allocator;
    
    // Bytecode with known gas costs
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x01,       // ADD (3 gas)
        0x80,       // DUP1 (3 gas)
        0x90,       // SWAP1 (3 gas)
        0x50,       // POP (2 gas)
        0x50,       // POP (2 gas)
        0x00,       // STOP (0 gas)
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    try testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    
    const block = analysis.blocks[0];
    try testing.expect(block.total_gas_cost != null);
    try testing.expectEqual(@as(u64, 19), block.total_gas_cost.?); // 3+3+3+3+3+2+2+0
}

test "basic block analysis performance characteristics" {
    const allocator = testing.allocator;
    
    // Generate large bytecode to test performance
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Create 100 basic blocks
    for (0..100) |i| {
        // Each block: arithmetic sequence ending with conditional jump
        try bytecode.appendSlice(&[_]u8{
            0x60, @intCast(i % 256), // PUSH1 i
            0x80,                    // DUP1
            0x01,                    // ADD
            0x60, 0x00,              // PUSH1 0
            0x14,                    // EQ
            0x60, 0x00,              // PUSH1 0 (dummy target)
            0x57,                    // JUMPI
        });
    }
    try bytecode.append(0x00); // STOP
    
    var timer = try std.time.Timer.start();
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, bytecode.items);
    defer analysis.deinit();
    
    const elapsed_ns = timer.read();
    
    // Analysis should be fast even for large bytecode
    try testing.expect(elapsed_ns < 10_000_000); // Less than 10ms
    
    // Should create ~100 blocks
    try testing.expect(analysis.blocks.len >= 90);
    try testing.expect(analysis.blocks.len <= 110);
    
    std.log.info("Analyzed {} bytes into {} blocks in {}ns", .{
        bytecode.items.len,
        analysis.blocks.len,
        elapsed_ns,
    });
}