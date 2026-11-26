const std = @import("std");
const ir_builder = @import("ir_builder.zig");
const IR = @import("ir.zig");

test "IR builder handles CODECOPY" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode with CODECOPY (0x39)
    // PUSH1 0x10  (offset)
    // PUSH1 0x00  (destOffset) 
    // PUSH1 0x20  (length)
    // CODECOPY
    // STOP
    const bytecode = [_]u8{ 
        0x60, 0x10,  // PUSH1 0x10
        0x60, 0x00,  // PUSH1 0x00
        0x60, 0x20,  // PUSH1 0x20
        0x39,        // CODECOPY
        0x00,        // STOP
    };
    
    var program = try ir_builder.build(allocator, &bytecode);
    defer program.deinit(allocator);
    
    std.debug.print("\nProgram has {} instructions\n", .{program.instructions.len});
    for (program.instructions, 0..) |instr, i| {
        std.debug.print("  [{d}] op={s}\n", .{i, @tagName(instr.op)});
    }
    
    // The program should have all instructions, not stop early at CODECOPY
    try std.testing.expect(program.instructions.len >= 4);
}

test "IR builder handles arithmetic opcodes" {
    const allocator = std.testing.allocator;
    
    // Bytecode with ADD (0x01)
    // PUSH1 0x02
    // PUSH1 0x03
    // ADD
    // STOP
    const bytecode = [_]u8{ 
        0x60, 0x02,  // PUSH1 0x02
        0x60, 0x03,  // PUSH1 0x03
        0x01,        // ADD
        0x00,        // STOP
    };
    
    var program = try ir_builder.build(allocator, &bytecode);
    defer program.deinit(allocator);
    
    std.debug.print("\nProgram has {} instructions\n", .{program.instructions.len});
    for (program.instructions, 0..) |instr, i| {
        std.debug.print("  [{d}] op={s}\n", .{i, @tagName(instr.op)});
    }
    
    // Should process all instructions
    try std.testing.expect(program.instructions.len >= 3);
}

test "IR builder handles typical Solidity init code pattern" {
    const allocator = std.testing.allocator;
    
    // Minimal pattern: codecopy and return
    // PUSH1 0x0a    (runtime code size)
    // DUP1
    // PUSH1 0x10    (runtime code offset in bytecode) 
    // PUSH1 0x00    (memory destination)
    // CODECOPY      (copy runtime code to memory)
    // PUSH1 0x00    (memory offset)
    // RETURN        (return runtime code)
    const bytecode = [_]u8{
        0x60, 0x0a,  // PUSH1 0x0a
        0x80,        // DUP1
        0x60, 0x10,  // PUSH1 0x10
        0x60, 0x00,  // PUSH1 0x00
        0x39,        // CODECOPY
        0x60, 0x00,  // PUSH1 0x00
        0xf3,        // RETURN
    };
    
    var program = try ir_builder.build(allocator, &bytecode);
    defer program.deinit(allocator);
    
    std.debug.print("\nSolidity init pattern - Program has {} instructions\n", .{program.instructions.len});
    for (program.instructions, 0..) |instr, i| {
        std.debug.print("  [{d}] op={s}\n", .{i, @tagName(instr.op)});
    }
    
    // Should handle the full sequence and end with RETURN
    const last_real_op = program.instructions[program.instructions.len - 2]; // -1 is sentinel
    try std.testing.expectEqual(IR.IROp.@"return", last_real_op.op);
}