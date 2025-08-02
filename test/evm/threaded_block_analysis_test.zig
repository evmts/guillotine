const std = @import("std");
const testing = std.testing;

test {
    std.testing.log_level = .debug;
}

const Evm = @import("evm");
const primitives = @import("primitives");
const threaded_analysis = @import("../../src/evm/frame/threaded_analysis.zig");

test "block analysis - single block with no splits" {
    const allocator = testing.allocator;
    
    // Simple bytecode that should be analyzed as a single block
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2  
        0x01,       // ADD
        0x00,       // STOP
    };
    
    var analysis = try threaded_analysis.analyzeThreaded(
        allocator,
        bytecode,
        [_]u8{0} ** 32,
        &Evm.JumpTable.init_from_hardfork(.CANCUN),
    );
    defer analysis.deinit(allocator);
    
    // Should have exactly 1 block plus instructions
    std.debug.print("\nSingle block test: blocks={}, instructions={}\n", .{analysis.blocks.len, analysis.instructions.len});
    
    // We should have:
    // 1. One block begin instruction
    // 2. Four operation instructions (PUSH1, PUSH1, ADD, STOP)
    try testing.expectEqual(@as(usize, 5), analysis.instructions.len);
    try testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    
    // The block should have correct gas and stack requirements
    const block = analysis.blocks[0];
    std.debug.print("Block 0: gas_cost={}, stack_req={}, stack_max_growth={}\n", .{block.gas_cost, block.stack_req, block.stack_max_growth});
    try testing.expect(block.gas_cost > 0); // Should have gas cost
    try testing.expectEqual(@as(u32, 0), block.stack_req); // No initial stack needed
    try testing.expectEqual(@as(u32, 2), block.stack_max_growth); // Max growth is 2 (after pushing 2 values)
}

test "block analysis - JUMPDEST creates new block" {
    const allocator = testing.allocator;
    
    // Bytecode with JUMPDEST that should create a new block
    const bytecode = &[_]u8{
        0x60, 0x04, // PUSH1 4
        0x56,       // JUMP
        0x00,       // STOP (unreachable)
        0x5b,       // JUMPDEST (pc=4)
        0x00,       // STOP
    };
    
    var analysis = try threaded_analysis.analyzeThreaded(
        allocator,
        bytecode,
        [_]u8{0} ** 32,
        &Evm.JumpTable.init_from_hardfork(.CANCUN),
    );
    defer analysis.deinit(allocator);
    
    std.debug.print("\nJUMPDEST test: blocks={}, instructions={}\n", .{analysis.blocks.len, analysis.instructions.len});
    
    // Should have 2 blocks (initial block and JUMPDEST block)
    try testing.expectEqual(@as(usize, 2), analysis.blocks.len);
    
    // Check jumpdest map
    try testing.expect(analysis.jumpdest_map.contains(4)); // JUMPDEST at pc=4
}

test "block analysis - stack requirements across blocks" {
    const allocator = testing.allocator;
    
    // First block pushes values, second block consumes them
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x5b,       // JUMPDEST - forces new block
        0x01,       // ADD - needs 2 items on stack
        0x00,       // STOP
    };
    
    var analysis = try threaded_analysis.analyzeThreaded(
        allocator,
        bytecode,
        [_]u8{0} ** 32,  
        &Evm.JumpTable.init_from_hardfork(.CANCUN),
    );
    defer analysis.deinit(allocator);
    
    std.debug.print("\nStack requirements test: blocks={}, instructions={}\n", .{analysis.blocks.len, analysis.instructions.len});
    
    // Should have 2 blocks
    try testing.expectEqual(@as(usize, 2), analysis.blocks.len);
    
    // First block should have no stack requirements
    std.debug.print("Block 0: gas_cost={}, stack_req={}, stack_max_growth={}\n", .{analysis.blocks[0].gas_cost, analysis.blocks[0].stack_req, analysis.blocks[0].stack_max_growth});
    try testing.expectEqual(@as(u32, 0), analysis.blocks[0].stack_req);
    try testing.expectEqual(@as(u32, 2), analysis.blocks[0].stack_max_growth); // Pushes 2 values
    
    // Second block should require 2 items on stack for ADD
    std.debug.print("Block 1: gas_cost={}, stack_req={}, stack_max_growth={}\n", .{analysis.blocks[1].gas_cost, analysis.blocks[1].stack_req, analysis.blocks[1].stack_max_growth});
    try testing.expectEqual(@as(u32, 2), analysis.blocks[1].stack_req); // ADD needs 2
    try testing.expectEqual(@as(u32, 0), analysis.blocks[1].stack_max_growth); // Pops 2, pushes 1, net -1, max 0
}

test "block analysis - empty bytecode" {
    const allocator = testing.allocator;
    
    const bytecode = &[_]u8{};
    
    var analysis = try threaded_analysis.analyzeThreaded(
        allocator,
        bytecode,
        [_]u8{0} ** 32,
        &Evm.JumpTable.init_from_hardfork(.CANCUN),
    );
    defer analysis.deinit(allocator);
    
    // Empty bytecode should have no blocks or instructions
    try testing.expectEqual(@as(usize, 0), analysis.instructions.len);
    try testing.expectEqual(@as(usize, 0), analysis.blocks.len);
}

test "block analysis - CODECOPY stack tracking" {
    const allocator = testing.allocator;
    
    // CODECOPY pops 3 values, so subsequent operations need their own values
    const bytecode = &[_]u8{
        // First: setup for CODECOPY
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (code offset)
        0x60, 0x00, // PUSH1 0 (dest offset)
        0x39,       // CODECOPY - pops all 3
        // Stack is now empty
        
        // Second: RETURN needs its own values
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
    };
    
    var analysis = try threaded_analysis.analyzeThreaded(
        allocator,
        bytecode,
        [_]u8{0} ** 32,
        &Evm.JumpTable.init_from_hardfork(.CANCUN),
    );
    defer analysis.deinit(allocator);
    
    std.debug.print("\nCODECOPY stack test: blocks={}, instructions={}\n", .{analysis.blocks.len, analysis.instructions.len});
    
    // Should be able to execute without stack underflow
    // The block analyzer should recognize that after CODECOPY the stack is empty
    try testing.expect(analysis.instructions.len > 0);
}

test "block analysis - large block split" {
    const allocator = testing.allocator;
    
    // Create bytecode that should trigger block split due to size/gas
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Add 40 PUSH1 operations (should trigger split at 32 instructions)
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(i)); // value
    }
    try bytecode.append(0x00); // STOP
    
    var analysis = try threaded_analysis.analyzeThreaded(
        allocator,
        bytecode.items,
        [_]u8{0} ** 32,
        &Evm.JumpTable.init_from_hardfork(.CANCUN),
    );
    defer analysis.deinit(allocator);
    
    std.debug.print("\nLarge block test: blocks={}, instructions={}\n", .{analysis.blocks.len, analysis.instructions.len});
    
    // Should have split into multiple blocks
    try testing.expect(analysis.blocks.len >= 2);
}