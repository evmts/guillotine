const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;

/// Enumeration of fusion operation types for opcode optimization
pub const FusionType = enum {
    push_add,
    push_mul,
    push_sub,
    push_div,
    push_and,
    push_or,
    push_xor,
    push_jump,
    push_jumpi,
};

/// Calculate gas cost for the first basic block of bytecode.
/// Returns the total gas cost from the start until the first JUMPDEST, terminator opcode, or end of bytecode.
pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
    var gas: u64 = 0;
    var iter = bytecode.createIterator();
    const opcode_info = @import("opcode_data.zig").OPCODE_INFO;

    var op_count: u32 = 0;
    
    while (true) {
        const maybe = iter.next();
        if (maybe == null) break;
        const op_data = maybe.?;
        op_count += 1;

        switch (op_data) {
            .regular => |data| {
                const gas_to_add = @as(u64, opcode_info[data.opcode].gas_cost);
                // Don't return maxInt on overflow - just return current gas
                const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                gas = new_gas;
                // Stop at JUMP/JUMPI/STOP/RETURN/REVERT/INVALID/SELFDESTRUCT
                switch (data.opcode) {
                    0x56, 0x57, 0x00, 0xf3, 0xfd, 0xfe, 0xff => {
                        return gas;
                    },
                    else => {},
                }
            },
            .push => |data| {
                const push_opcode = 0x60 + data.size - 1;
                const gas_to_add = @as(u64, opcode_info[push_opcode].gas_cost);
                // Don't return maxInt on overflow - just return current gas
                const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                gas = new_gas;
            },
            .jumpdest => {
                // JUMPDEST terminates the block but its gas is not included
                return gas;
            },
            .stop, .invalid => {
                const gas_to_add = @as(u64, opcode_info[0x00].gas_cost); // STOP gas cost
                gas = std.math.add(u64, gas, gas_to_add) catch gas;
                return gas;
            },
            else => {
                // For fusion operations, approximate gas cost
                const new_gas = std.math.add(u64, gas, 6) catch gas;
                gas = new_gas;
            },
        }
    }
    
    return gas;
}

/// Get the correct synthetic opcode index for a fusion operation
pub fn getSyntheticOpcode(fusion_type: FusionType, is_inline: bool) u8 {
    return switch (fusion_type) {
        .push_add => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER),
        .push_mul => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER),
        .push_sub => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER),
        .push_div => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER),
        .push_and => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER),
        .push_or => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER),
        .push_xor => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER),
        .push_jump => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER),
        .push_jumpi => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER),
    };
}