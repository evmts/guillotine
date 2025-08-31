const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const ArrayList = std.ArrayListAligned;

/// PC mapping entry for tracing
pub fn PCMapEntry(comptime FrameType: type) type {
    return struct {
        dispatch_index: usize,
        pc: FrameType.PcType,
        opcode: u8,
        is_synthetic: bool,
    };
}

/// Build a mapping from dispatch indices to PC values and opcodes for tracing
pub fn buildPCMapping(
    comptime FrameType: type,
    comptime DispatchType: type,
    allocator: std.mem.Allocator,
    schedule: []const DispatchType.Item,
    bytecode: anytype,
) ![]PCMapEntry(FrameType) {
    const Self = DispatchType;
    const PCMapEntryType = PCMapEntry(FrameType);
    const PCMapList = ArrayList(PCMapEntryType, null);
    var pc_map = PCMapList{};
    errdefer pc_map.deinit(allocator);

    // Create iterator to traverse bytecode
    var iter = bytecode.createIterator();
    var dispatch_index: usize = 0;

    // Skip first_block_gas if present
    // First_block_gas is only added if calculateFirstBlockGas(bytecode) > 0
    const first_block_gas = Self.calculateFirstBlockGas(bytecode);
    if (first_block_gas > 0 and schedule.len > 0) {
        dispatch_index = 1;
    }

    while (true) {
        const instr_pc = iter.pc;
        const maybe = iter.next();
        if (maybe == null) break;
        const op_data = maybe.?;

        switch (op_data) {
            .regular => |data| {
                // Map this regular opcode to its dispatch index
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = data.opcode,
                    .is_synthetic = false,
                });
                dispatch_index += 1;

                // PC, CODESIZE, CODECOPY opcodes have additional dispatch items
                if (data.opcode == @intFromEnum(Opcode.PC) or
                    data.opcode == @intFromEnum(Opcode.CODESIZE) or
                    data.opcode == @intFromEnum(Opcode.CODECOPY))
                {
                    dispatch_index += 1; // Account for metadata
                }
            },
            .push => |data| {
                const push_opcode = 0x60 + data.size - 1;
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = push_opcode,
                    .is_synthetic = false,
                });
                dispatch_index += 1;

                // PUSH operations have additional value item
                dispatch_index += 1;
            },
            .jumpdest => |data| {
                _ = data;
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = @intFromEnum(Opcode.JUMPDEST),
                    .is_synthetic = false,
                });
                dispatch_index += 1;

                // JUMPDEST has additional metadata
                dispatch_index += 1;
            },
            // Handle fusion operations
            .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion, .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_jump_fusion, .push_jumpi_fusion => |data| {
                _ = data;
                const synthetic_opcode: u8 = switch (op_data) {
                    .push_add_fusion => @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE),
                    .push_mul_fusion => @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE),
                    .push_sub_fusion => @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE),
                    .push_div_fusion => @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE),
                    .push_and_fusion => @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE),
                    .push_or_fusion => @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE),
                    .push_xor_fusion => @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE),
                    .push_jump_fusion => @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE),
                    .push_jumpi_fusion => @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE),
                    else => unreachable,
                };

                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = synthetic_opcode,
                    .is_synthetic = true,
                });
                dispatch_index += 1;

                // Fusion ops may have additional value item
                dispatch_index += 1;
            },
            .stop => {
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = @intFromEnum(Opcode.STOP),
                    .is_synthetic = false,
                });
                dispatch_index += 1;
            },
            .invalid => {
                try pc_map.append(allocator, .{
                    .dispatch_index = dispatch_index,
                    .pc = @intCast(instr_pc),
                    .opcode = @intFromEnum(Opcode.INVALID),
                    .is_synthetic = false,
                });
                dispatch_index += 1;
            },
        }
    }

    return pc_map.toOwnedSlice(allocator);
}