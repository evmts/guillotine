const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const bytecode_mod = @import("bytecode.zig");
const ArrayList = std.ArrayListAligned;

/// This is a refactored version of calculateFirstBlockGas that doesn't use the iterator
pub fn calculateFirstBlockGasNoIterator(bytecode: anytype) u64 {
    var gas: u64 = 0;
    const opcode_info = @import("opcode_data.zig").OPCODE_INFO;
    
    // Direct bytecode traversal without iterator
    var pc: usize = 0;
    while (pc < bytecode.len()) {
        const opcode_byte = bytecode.getOpcodeUnsafe(@intCast(pc));
        const opcode = std.meta.intToEnum(Opcode, opcode_byte) catch {
            // Invalid opcode
            const gas_to_add = @as(u64, opcode_info[0xFE].gas_cost); // INVALID gas cost
            gas = std.math.add(u64, gas, gas_to_add) catch return std.math.maxInt(u64);
            return gas;
        };
        
        switch (opcode) {
            .JUMPDEST => {
                // JUMPDEST terminates the block but its gas is not included
                return gas;
            },
            .STOP, .RETURN, .REVERT, .INVALID, .SELFDESTRUCT => {
                const gas_to_add = @as(u64, opcode_info[opcode_byte].gas_cost);
                gas = std.math.add(u64, gas, gas_to_add) catch return std.math.maxInt(u64);
                return gas;
            },
            .JUMP, .JUMPI => {
                const gas_to_add = @as(u64, opcode_info[opcode_byte].gas_cost);
                gas = std.math.add(u64, gas, gas_to_add) catch return std.math.maxInt(u64);
                return gas;
            },
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, 
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
            .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
            .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                const push_size = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH1) + 1;
                const gas_to_add = @as(u64, opcode_info[opcode_byte].gas_cost);
                gas = std.math.add(u64, gas, gas_to_add) catch return std.math.maxInt(u64);
                pc += push_size; // Skip push data
            },
            else => {
                const gas_to_add = @as(u64, opcode_info[opcode_byte].gas_cost);
                gas = std.math.add(u64, gas, gas_to_add) catch return std.math.maxInt(u64);
            },
        }
        
        pc += 1;
    }
    
    return gas;
}

/// This is a refactored version of init that uses pre-analyzed data instead of iterator
pub fn initFromAnalysisTemplate(
    comptime FrameType: type,
    allocator: std.mem.Allocator,
    bytecode: anytype,
    analysis: anytype,
    opcode_handlers: anytype,
) ![]anytype {
    const log = @import("log.zig");
    log.debug("Dispatch.initFromAnalysis starting...", .{});
    
    var schedule_items = ArrayList(anytype, null){};
    errdefer schedule_items.deinit(allocator);
    
    // Calculate gas cost for first basic block
    const first_block_gas = calculateFirstBlockGasNoIterator(bytecode);
    
    // Add first_block_gas entry if there's any gas to charge
    if (first_block_gas > 0) {
        try schedule_items.append(allocator, .{ .first_block_gas = .{ .gas = first_block_gas } });
        log.debug("Added first_block_gas: {d}", .{first_block_gas});
    }
    
    // Process bytecode directly without iterator
    // We'll need to track push data information from analysis
    var push_idx: usize = 0;
    var jumpdest_idx: usize = 0;
    
    var pc: usize = 0;
    while (pc < bytecode.len()) {
        // Skip if not an opcode start (push data)
        if (!bytecode.packed_bitmap[pc].is_op_start) {
            pc += 1;
            continue;
        }
        
        const opcode_byte = bytecode.getOpcodeUnsafe(@intCast(pc));
        const opcode = std.meta.intToEnum(Opcode, opcode_byte) catch {
            // Invalid opcode
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.INVALID)] });
            pc += 1;
            continue;
        };
        
        // Check if this PC is a fusion candidate
        if (bytecode.packed_bitmap[pc].is_fusion_candidate) {
            // Handle fusion - this would need the fusion type detection logic
            const fusion_data = bytecode.getFusionData(@intCast(pc));
            // Add fusion handling here...
            // For now, skip to demonstrate the pattern
        }
        
        switch (opcode) {
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
            .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
            .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                // Find the push data from analysis
                if (push_idx < analysis.push_data.items.len and 
                    analysis.push_data.items[push_idx].pc == pc) {
                    const push_info = analysis.push_data.items[push_idx];
                    push_idx += 1;
                    
                    try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[opcode_byte] });
                    
                    if (push_info.is_inline) {
                        // Inline value for small pushes
                        const inline_value: u64 = @intCast(push_info.value);
                        try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_value } });
                    } else {
                        // Pointer to value for large pushes
                        const value_ptr = try allocator.create(FrameType.WordType);
                        value_ptr.* = push_info.value;
                        try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
                    }
                    
                    pc += push_info.size; // Skip push data
                } else {
                    // This shouldn't happen if analysis is correct
                    return error.AnalysisMismatch;
                }
            },
            .JUMPDEST => {
                // Find jumpdest info from analysis
                if (jumpdest_idx < analysis.jump_destinations.items.len and
                    analysis.jump_destinations.items[jumpdest_idx].pc == pc) {
                    const jumpdest_info = analysis.jump_destinations.items[jumpdest_idx];
                    jumpdest_idx += 1;
                    
                    try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)] });
                    try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = jumpdest_info.gas_cost } });
                } else {
                    // This shouldn't happen if analysis is correct
                    return error.AnalysisMismatch;
                }
            },
            .PC => {
                try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[opcode_byte] });
                try schedule_items.append(allocator, .{ .pc = .{ .value = @intCast(pc) } });
            },
            .CODESIZE => {
                try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[opcode_byte] });
                try schedule_items.append(allocator, .{ .codesize = .{ .size = @intCast(bytecode.runtime_code.len) } });
            },
            .CODECOPY => {
                try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[opcode_byte] });
                const bytecode_data = bytecode.runtime_code;
                try schedule_items.append(allocator, .{ .codecopy = .{ .bytecode_ptr = bytecode_data.ptr, .size = @intCast(bytecode_data.len) } });
            },
            else => {
                // Regular opcode
                try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[opcode_byte] });
            },
        }
        
        pc += 1;
    }
    
    // Safety: Append two STOP handlers as terminators
    try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
    try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
    
    const final_schedule = try schedule_items.toOwnedSlice(allocator);
    log.debug("Dispatch.initFromAnalysis complete, schedule length: {}", .{final_schedule.len});
    return final_schedule;
}

// Additional helper functions for PC mapping and other iterator-based functions would go here...