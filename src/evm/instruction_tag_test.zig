const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const Tag = @import("instruction.zig").Tag;
const InstructionType = @import("instruction.zig").InstructionType;
const NoopInstruction = @import("instruction.zig").NoopInstruction;
const JumpPcInstruction = @import("instruction.zig").JumpPcInstruction;
const BlockInstruction = @import("instruction.zig").BlockInstruction;
const WordInstruction = @import("instruction.zig").WordInstruction;
const getInstructionSize = @import("instruction.zig").getInstructionSize;

test "Instruction tag enum values" {
    // Verify synthetic tags have expected values
    try std.testing.expect(@intFromEnum(Tag.noop) >= 0x100);
    try std.testing.expect(@intFromEnum(Tag.jump_pc) >= 0x100);
    try std.testing.expect(@intFromEnum(Tag.block_info) >= 0x100);
    
    // Verify real opcodes have values <= 0xFF
    try std.testing.expect(@intFromEnum(Tag.op_stop) <= 0xFF);
    try std.testing.expect(@intFromEnum(Tag.op_add) <= 0xFF);
    try std.testing.expect(@intFromEnum(Tag.op_keccak256) <= 0xFF);
}

test "Instruction packed struct size" {
    // Verify instruction header is exactly 32 bits
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Instruction));
    
    // Test creating instruction with real opcode
    const inst = Instruction{
        .tag = .op_add,
        .id = 12345,
    };
    try std.testing.expectEqual(Tag.op_add, inst.tag);
    try std.testing.expectEqual(@as(u16, 12345), inst.id);
}

test "Instruction size categorization" {
    // 0-byte instructions (tag-only)
    try std.testing.expectEqual(@as(usize, 0), getInstructionSize(.noop));
    try std.testing.expectEqual(@as(usize, 0), getInstructionSize(.conditional_jump_unresolved));
    try std.testing.expectEqual(@as(usize, 0), getInstructionSize(.conditional_jump_invalid));
    
    // 2-byte instructions
    try std.testing.expectEqual(@as(usize, 2), getInstructionSize(.jump_pc));
    try std.testing.expectEqual(@as(usize, 2), getInstructionSize(.conditional_jump_pc));
    try std.testing.expectEqual(@as(usize, 2), getInstructionSize(.pc));
    
    // 8-byte instructions
    try std.testing.expectEqual(@as(usize, 8), getInstructionSize(.block_info));
    
    // Real opcodes don't have instruction sizes (direct dispatch)
    try std.testing.expectEqual(@as(usize, 0), getInstructionSize(.op_add));
    try std.testing.expectEqual(@as(usize, 0), getInstructionSize(.op_stop));
}

test "InstructionType comptime function" {
    // Verify InstructionType returns correct types for synthetic instructions
    try std.testing.expectEqual(NoopInstruction, InstructionType(.noop));
    try std.testing.expectEqual(JumpPcInstruction, InstructionType(.jump_pc));
    try std.testing.expectEqual(BlockInstruction, InstructionType(.block_info));
    try std.testing.expectEqual(WordInstruction, InstructionType(.word));
    
    // Real opcodes return void
    try std.testing.expectEqual(void, InstructionType(.op_add));
    try std.testing.expectEqual(void, InstructionType(.op_stop));
}

test "BlockInstruction gas and stack tracking" {
    const block = BlockInstruction{
        .gas_cost = 1000,
        .stack_req = 3,
        .stack_max_growth = 2,
    };
    
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(BlockInstruction));
    try std.testing.expectEqual(@as(u32, 1000), block.gas_cost);
    try std.testing.expectEqual(@as(u16, 3), block.stack_req);
    try std.testing.expectEqual(@as(u16, 2), block.stack_max_growth);
}

test "WordInstruction with bytecode slice" {
    const bytecode = [_]u8{ 0x60, 0x40 }; // PUSH1 0x40
    
    const word_inst = WordInstruction{
        .word_bytes = bytecode[1..2], // Just the 0x40 byte
    };
    
    const expected_size = @sizeOf([]const u8); // Size of a slice
    try std.testing.expectEqual(expected_size, @sizeOf(WordInstruction));
    try std.testing.expectEqual(@as(usize, 1), word_inst.word_bytes.len);
    try std.testing.expectEqual(@as(u8, 0x40), word_inst.word_bytes[0]);
}

test "Maximum ID value for 16-bit field" {
    const max_id: u16 = std.math.maxInt(u16);
    const inst = Instruction{
        .tag = .op_stop,
        .id = max_id,
    };
    
    try std.testing.expectEqual(@as(u16, 65535), inst.id); // 2^16 - 1
    try std.testing.expectEqual(Tag.op_stop, inst.tag);
}