const std = @import("std");

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
                        // Debug: log when we encounter a terminator
                        if (data.opcode == 0x57) {
                            // log.debug("calculateFirstBlockGas: Found JUMPI at op_count={}, gas={}", .{op_count, gas});
                        }
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
                // TODO: More accurate gas estimation for fusion ops
                const new_gas = std.math.add(u64, gas, 6) catch gas;
                gas = new_gas;
            },
        }
    }

    // Log if gas consumption seems excessive
    if (gas > 10000 or op_count > 100) {
        // log.warn("calculateFirstBlockGas: First block gas={}, op_count={}, bytecode_len={}", .{ gas, op_count, bytecode.len() });
    }
    
    return gas;
}