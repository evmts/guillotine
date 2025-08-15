const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const Tag = @import("instruction.zig").Tag;
const InstructionType = @import("instruction.zig").InstructionType;
const ExecInstruction = @import("instruction.zig").ExecInstruction;
const NoopInstruction = @import("instruction.zig").NoopInstruction;
const JumpPcInstruction = @import("instruction.zig").JumpPcInstruction;
const BlockInstruction = @import("instruction.zig").BlockInstruction;
const WordInstruction = @import("instruction.zig").WordInstruction;
const getInstructionSize = @import("instruction.zig").getInstructionSize;

test "Instruction tag enum values" {
    // Verify tag enum has expected values
    try std.testing.expect(@intFromEnum(Tag.noop) < 256);
    try std.testing.expect(@intFromEnum(Tag.exec) < 256);
    try std.testing.expect(@intFromEnum(Tag.jump_pc) < 256);
    try std.testing.expect(@intFromEnum(Tag.block_info) < 256);
}

test "Instruction packed struct size" {
    // Verify instruction header is exactly 32 bits
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Instruction));
    
    // Test creating instruction
    const inst = Instruction{
        .tag = .exec,
        .id = 12345,
    };
    try std.testing.expectEqual(Tag.exec, inst.tag);
    try std.testing.expectEqual(@as(u24, 12345), inst.id);
}

test "Instruction size categorization" {
    // 8-byte instructions
    try std.testing.expectEqual(@as(usize, 8), getInstructionSize(.noop));
    try std.testing.expectEqual(@as(usize, 8), getInstructionSize(.jump_pc));
    try std.testing.expectEqual(@as(usize, 8), getInstructionSize(.conditional_jump_unresolved));
    try std.testing.expectEqual(@as(usize, 8), getInstructionSize(.conditional_jump_invalid));
    
    // 16-byte instructions
    try std.testing.expectEqual(@as(usize, 16), getInstructionSize(.exec));
    try std.testing.expectEqual(@as(usize, 16), getInstructionSize(.conditional_jump_pc));
    try std.testing.expectEqual(@as(usize, 16), getInstructionSize(.pc));
    try std.testing.expectEqual(@as(usize, 16), getInstructionSize(.block_info));
    
    // 24-byte instructions
    try std.testing.expectEqual(@as(usize, 24), getInstructionSize(.dynamic_gas));
    try std.testing.expectEqual(@as(usize, 24), getInstructionSize(.word));
}

test "InstructionType comptime function" {
    // Verify InstructionType returns correct types
    try std.testing.expectEqual(NoopInstruction, InstructionType(.noop));
    try std.testing.expectEqual(ExecInstruction, InstructionType(.exec));
    try std.testing.expectEqual(JumpPcInstruction, InstructionType(.jump_pc));
    try std.testing.expectEqual(BlockInstruction, InstructionType(.block_info));
    try std.testing.expectEqual(WordInstruction, InstructionType(.word));
}

test "ExecInstruction struct layout" {
    const dummy_fn = struct {
        fn exec(ctx: *anyopaque) !void {
            _ = ctx;
        }
    }.exec;
    
    const dummy_inst = Instruction{ .tag = .noop, .id = 0 };
    
    const exec_inst = ExecInstruction{
        .exec_fn = dummy_fn,
        .next_inst = &dummy_inst,
    };
    
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ExecInstruction));
    try std.testing.expectEqual(dummy_fn, exec_inst.exec_fn);
    try std.testing.expect(exec_inst.next_inst == &dummy_inst);
}

test "BlockInstruction gas and stack tracking" {
    const dummy_inst = Instruction{ .tag = .noop, .id = 0 };
    
    const block = BlockInstruction{
        .gas_cost = 1000,
        .stack_req = 3,
        .stack_max_growth = 2,
        .next_inst = &dummy_inst,
    };
    
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(BlockInstruction));
    try std.testing.expectEqual(@as(u32, 1000), block.gas_cost);
    try std.testing.expectEqual(@as(u16, 3), block.stack_req);
    try std.testing.expectEqual(@as(u16, 2), block.stack_max_growth);
}

test "WordInstruction with bytecode slice" {
    const bytecode = [_]u8{ 0x60, 0x40 }; // PUSH1 0x40
    const dummy_inst = Instruction{ .tag = .noop, .id = 0 };
    
    const word_inst = WordInstruction{
        .word_bytes = bytecode[1..2], // Just the 0x40 byte
        .next_inst = &dummy_inst,
    };
    
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(WordInstruction));
    try std.testing.expectEqual(@as(usize, 1), word_inst.word_bytes.len);
    try std.testing.expectEqual(@as(u8, 0x40), word_inst.word_bytes[0]);
}

test "Maximum ID value for 24-bit field" {
    const max_id: u24 = std.math.maxInt(u24);
    const inst = Instruction{
        .tag = .exec,
        .id = max_id,
    };
    
    try std.testing.expectEqual(@as(u24, 16777215), inst.id); // 2^24 - 1
    try std.testing.expectEqual(Tag.exec, inst.tag);
}