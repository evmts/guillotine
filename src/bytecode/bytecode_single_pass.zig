/// Single-pass bytecode analysis and preprocessing
/// Combines validation, analysis, and dispatch schedule creation into one efficient pass
/// This module replaces the multi-pass approach with a unified architecture
const std = @import("std");
const log = @import("../log.zig");
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Fusion types for optimized opcode sequences
pub const FusionType = enum(u8) {
    none = 0,
    push_add,
    push_mul,
    push_sub,
    push_div,
    push_and,
    push_or,
    push_xor,
    push_jump,
    push_jumpi,
    push_mload,
    push_mstore,
    push_mstore8,
    constant_fold,
    multi_push_2,
    multi_push_3,
    multi_pop_2,
    multi_pop_3,
    iszero_jumpi,
    dup2_mstore_push,
};

/// Instruction size lookup table - O(1) size determination
const INSTRUCTION_SIZES: [256]u8 = blk: {
    var sizes = [_]u8{1} ** 256; // Most instructions are 1 byte
    
    // PUSH instructions have data
    for (0x60..0x80) |push_op| {
        sizes[push_op] = 1 + (push_op - 0x5F);
    }
    
    break :blk sizes;
};

/// 2-opcode fusion lookup table for O(1) pattern detection
/// Note: For PUSH opcodes, this checks the opcode AFTER the push data
const FUSION_TABLE: [256][256]FusionType = blk: {
    var table = [_][256]FusionType{[_]FusionType{.none} ** 256} ** 256;
    
    // Populate 2-opcode fusions for PUSH + operation
    for (0x60..0x80) |push_op| { // PUSH1-PUSH32
        table[push_op][0x01] = .push_add;
        table[push_op][0x02] = .push_mul;
        table[push_op][0x03] = .push_sub;
        table[push_op][0x04] = .push_div;
        table[push_op][0x16] = .push_and;
        table[push_op][0x17] = .push_or;
        table[push_op][0x18] = .push_xor;
        table[push_op][0x56] = .push_jump;
        table[push_op][0x57] = .push_jumpi;
        table[push_op][0x51] = .push_mload;
        table[push_op][0x52] = .push_mstore;
        table[push_op][0x53] = .push_mstore8;
    }
    
    // Special patterns for consecutive operations
    table[0x50][0x50] = .multi_pop_2;   // POP POP
    table[0x81][0x52] = .dup2_mstore_push; // DUP2 MSTORE (check for PUSH later)
    
    break :blk table;
};

/// Result of single-pass analysis
pub fn SinglePassResult(comptime FrameType: type) type {
    const DispatchType = @import("../preprocessor/dispatch.zig").Dispatch(FrameType);
    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{
        .max_bytecode_size = 24576,
        .max_initcode_size = 49152,
        .fusions_enabled = true,
    });
    
    return struct {
        /// Packed bitmap for bytecode properties
        packed_bitmap: []BytecodeType.PackedBits,
        /// Dispatch schedule for execution
        dispatch_schedule: []DispatchType.Item,
        /// Jump destination map for JUMP/JUMPI validation
        jump_table: DispatchType.JumpTable,
        /// Runtime bytecode (excludes metadata)
        runtime_code: []const u8,
    };
}

/// Processing context for single-pass analysis
fn ProcessContext(comptime FrameType: type) type {
    const DispatchType = @import("../preprocessor/dispatch.zig").Dispatch(FrameType);
    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{
        .max_bytecode_size = 24576,
        .max_initcode_size = 49152,
        .fusions_enabled = true,
    });
    
    return struct {
        allocator: std.mem.Allocator,
        bytecode: []const u8,
        runtime_code: []const u8,
        opcode_handlers: *const [256]FrameType.OpcodeHandler,
        
        // Outputs being built
        packed_bitmap: []BytecodeType.PackedBits,
        schedule_items: std.ArrayList(DispatchType.Item),
        
        // Jump destination tracking
        jumpdest_map: std.AutoHashMap(FrameType.PcType, usize),
        unresolved_jumps: std.ArrayList(UnresolvedJump),
        
        // Current state
        pc: FrameType.PcType,
        schedule_index: usize,
        first_block_gas: u64,
        
        const UnresolvedJump = struct {
            schedule_index: usize,
            target_pc: FrameType.PcType,
        };
    };
}

/// Main single-pass analysis function
pub fn analyzeAndPreprocess(
    comptime FrameType: type,
    allocator: std.mem.Allocator,
    bytecode_raw: []const u8,
    opcode_handlers: *const [256]FrameType.OpcodeHandler,
) !SinglePassResult(FrameType) {
    const DispatchType = @import("../preprocessor/dispatch.zig").Dispatch(FrameType);
    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{
        .max_bytecode_size = 24576,
        .max_initcode_size = 49152,
        .fusions_enabled = true,
    });
    
    // Check bytecode size limit
    if (bytecode_raw.len > 24576) {
        return error.BytecodeTooLarge;
    }
    
    // Detect and strip Solidity metadata
    const runtime_code = stripSolidityMetadata(bytecode_raw);
    
    // Pre-allocate structures based on bytecode size
    const estimated_items = runtime_code.len * 2; // Conservative estimate
    
    var context = ProcessContext(FrameType){
        .allocator = allocator,
        .bytecode = bytecode_raw,
        .runtime_code = runtime_code,
        .opcode_handlers = opcode_handlers,
        .packed_bitmap = try allocator.alloc(BytecodeType.PackedBits, runtime_code.len),
        .schedule_items = try std.ArrayList(DispatchType.Item).initCapacity(allocator, estimated_items),
        .jumpdest_map = std.AutoHashMap(FrameType.PcType, usize).init(allocator),
        .unresolved_jumps = std.ArrayList(ProcessContext(FrameType).UnresolvedJump){},
        .pc = 0,
        .schedule_index = 0,
        .first_block_gas = 0,
    };
    
    errdefer {
        allocator.free(context.packed_bitmap);
        context.schedule_items.deinit(context.allocator);
        context.jumpdest_map.deinit();
        context.unresolved_jumps.deinit(context.allocator);
    }
    
    // Initialize packed bitmap
    for (context.packed_bitmap) |*bits| {
        bits.* = BytecodeType.PackedBits{
            .is_push_data = false,
            .is_op_start = false,
            .is_jumpdest = false,
            .is_fusion_candidate = false,
        };
    }
    
    // Empty bytecode is valid
    if (runtime_code.len == 0) {
        // Add terminal STOP handlers
        try context.schedule_items.append(context.allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
        try context.schedule_items.append(context.allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
        
        return SinglePassResult(FrameType){
            .packed_bitmap = context.packed_bitmap,
            .dispatch_schedule = try context.schedule_items.toOwnedSlice(context.allocator),
            .jump_table = DispatchType.JumpTable{ .entries = &[_]DispatchType.JumpTable.JumpTableEntry{} },
            .runtime_code = runtime_code,
        };
    }
    
    // Calculate first block gas
    context.first_block_gas = calculateFirstBlockGas(FrameType, &context);
    if (context.first_block_gas > 0) {
        try context.schedule_items.append(context.allocator, .{ .first_block_gas = .{ .gas = @intCast(context.first_block_gas) } });
    }
    
    // Main single-pass loop
    while (context.pc < runtime_code.len) {
        // Mark instruction start
        context.packed_bitmap[context.pc].is_op_start = true;
        
        // Detect fusion patterns
        const fusion_type = detectFusion(FrameType, &context);
        
        if (fusion_type != .none) {
            try processFusion(FrameType, &context, fusion_type);
        } else {
            // Process regular opcode
            const opcode = runtime_code[context.pc];
            try processOpcode(FrameType, &context, opcode);
        }
    }
    
    // Add terminal STOP handlers for safety
    try context.schedule_items.append(context.allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
    try context.schedule_items.append(context.allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
    
    // Resolve all jump targets
    const schedule = try context.schedule_items.toOwnedSlice(context.allocator);
    try resolveJumps(FrameType, &context, schedule);
    
    // Build jump table from collected data
    const jump_table = try buildJumpTable(FrameType, allocator, &context.jumpdest_map, schedule);
    
    return SinglePassResult(FrameType){
        .packed_bitmap = context.packed_bitmap,
        .dispatch_schedule = schedule,
        .jump_table = jump_table,
        .runtime_code = runtime_code,
    };
}

/// Strip Solidity metadata from bytecode
fn stripSolidityMetadata(code: []const u8) []const u8 {
    if (code.len < 2) return code;
    
    // Look for metadata marker near the end
    const search_start = if (code.len > 100) code.len - 100 else 0;
    var i = search_start;
    while (i < code.len - 1) : (i += 1) {
        // Check for CBOR metadata markers
        if ((code[i] == 0xa2 or code[i] == 0xa1) and i + 10 < code.len) {
            // Check for "ipfs" or "bzzr" following the marker
            if ((code[i] == 0xa2 and i + 5 < code.len and
                code[i + 1] == 0x64 and // string of length 4
                code[i + 2] == 0x69 and // 'i'
                code[i + 3] == 0x70 and // 'p'
                code[i + 4] == 0x66 and // 'f'
                code[i + 5] == 0x73) or // 's'
                (code[i] == 0xa1 and i + 6 < code.len and
                    code[i + 1] == 0x65 and // string of length 5
                    code[i + 2] == 0x62 and // 'b'
                    code[i + 3] == 0x7a and // 'z'
                    code[i + 4] == 0x7a and // 'z'
                    code[i + 5] == 0x72)) // 'r'
            {
                // Found metadata, trim the bytecode here
                return code[0..i];
            }
        }
    }
    return code;
}

/// Calculate gas for first basic block
fn calculateFirstBlockGas(comptime FrameType: type, context: *ProcessContext(FrameType)) u64 {
    const opcode_info = @import("../opcodes/opcode_data.zig").OPCODE_INFO;
    var gas: u64 = 0;
    var pc: FrameType.PcType = 0;
    
    while (pc < context.runtime_code.len) {
        const opcode = context.runtime_code[pc];
        
        // Check for terminating opcodes
        switch (opcode) {
            0x56, 0x57, 0x5b, 0x00, 0xf3, 0xfd, 0xfe, 0xff => return gas,
            else => {},
        }
        
        // Add gas cost for this opcode
        gas = std.math.add(u64, gas, opcode_info[opcode].gas_cost) catch gas;
        
        // Advance PC
        pc += INSTRUCTION_SIZES[opcode];
    }
    
    return gas;
}

/// Detect fusion patterns at current PC
fn detectFusion(comptime FrameType: type, context: *ProcessContext(FrameType)) FusionType {
    const pc = context.pc;
    const bytecode = context.runtime_code;
    
    if (pc >= bytecode.len) return .none;
    
    const opcode = bytecode[pc];
    
    // Check advanced patterns first (they're more specific)
    
    // Constant folding: PUSH1 x, PUSH1 y, ADD/SUB/MUL
    if (pc + 4 < bytecode.len and opcode == 0x60 and bytecode[pc + 2] == 0x60) {
        const arith_op = bytecode[pc + 4];
        if (arith_op == 0x01 or arith_op == 0x02 or arith_op == 0x03) {
            return .constant_fold;
        }
    }
    
    // Multi-push patterns disabled for correctness validation in initial single-pass rollout
    
    // Multi-pop: consecutive POP instructions
    if (opcode == 0x50 and pc + 1 < bytecode.len and bytecode[pc + 1] == 0x50) {
        if (pc + 2 < bytecode.len and bytecode[pc + 2] == 0x50) {
            return .multi_pop_3;
        }
        return .multi_pop_2;
    }
    
    // ISZERO-JUMPI pattern
    if (opcode == 0x15 and pc + 1 < bytecode.len) { // ISZERO
        const next_op = bytecode[pc + 1];
        if (isPushOpcode(next_op)) {
            const push_size = next_op - 0x5F;
            const jumpi_pc = pc + 2 + push_size;
            if (jumpi_pc < bytecode.len and bytecode[jumpi_pc] == 0x57) { // JUMPI
                return .iszero_jumpi;
            }
        }
    }
    
    // DUP2-MSTORE-PUSH pattern
    if (opcode == 0x81 and pc + 1 < bytecode.len and bytecode[pc + 1] == 0x52) { // DUP2 MSTORE
        if (pc + 2 < bytecode.len and isPushOpcode(bytecode[pc + 2])) {
            return .dup2_mstore_push;
        }
    }
    
    // Check 2-opcode fusions for PUSH + operation
    if (isPushOpcode(opcode)) {
        const push_size = opcode - 0x5F;
        const next_pc = pc + 1 + push_size;
        if (next_pc < bytecode.len) {
            const next_op = bytecode[next_pc];
            const fusion = FUSION_TABLE[opcode][next_op];
            if (fusion != .none) {
                return fusion;
            }
        }
    }
    
    return .none;
}

/// Check if opcode is a PUSH instruction
inline fn isPushOpcode(opcode: u8) bool {
    return opcode >= 0x60 and opcode <= 0x7F;
}

/// Process a regular opcode
fn processOpcode(comptime FrameType: type, context: *ProcessContext(FrameType), opcode: u8) !void {
    _ = @import("../preprocessor/dispatch.zig").Dispatch(FrameType);
    
    // Validate opcode (undefined opcodes treated as INVALID)
    const opcode_enum = std.meta.intToEnum(Opcode, opcode) catch Opcode.INVALID;
    
    // Get handler
    // Handle special opcodes that need metadata
    switch (opcode) {
        0x5B => { // JUMPDEST
            context.packed_bitmap[context.pc].is_jumpdest = true;
            log.warn("[single-pass] JUMPDEST pc=0x{x}, sched_idx={}", .{ context.pc, context.schedule_items.items.len });
            // Store the schedule index where the JUMPDEST handler will be
            try context.jumpdest_map.put(@intCast(context.pc), context.schedule_items.items.len);
            // Add the JUMPDEST handler
            const handler = context.opcode_handlers.*[@intFromEnum(opcode_enum)];
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            // Then add the metadata
            try context.schedule_items.append(context.allocator, .{ .jump_dest = .{ .gas = 1 } });
            context.pc += 1;
        },
        0x60...0x7F => { // PUSH1-PUSH32
            const push_size = opcode - 0x5F;
            
            // Validate push data exists
            if (context.pc + push_size >= context.runtime_code.len) {
                return error.TruncatedPush;
            }
            
            // Extract push value
            var value: u256 = 0;
            for (1..push_size + 1) |i| {
                context.packed_bitmap[context.pc + i].is_push_data = true;
                value = std.math.shl(u256, value, 8) | context.runtime_code[context.pc + i];
            }
            
            // Add the PUSH handler
            const handler = context.opcode_handlers.*[@intFromEnum(opcode_enum)];
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            
            // Add metadata
            if (push_size <= 8 and value <= std.math.maxInt(u64)) {
                try context.schedule_items.append(context.allocator, .{ .push_inline = .{ .value = @intCast(value) } });
            } else {
                const value_ptr = try context.allocator.create(u256);
                value_ptr.* = value;
                try context.schedule_items.append(context.allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
            
            context.pc += 1 + push_size;
        },
        0x58 => { // PC
            const handler = context.opcode_handlers.*[@intFromEnum(opcode_enum)];
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            try context.schedule_items.append(context.allocator, .{ .pc = .{ .value = @intCast(context.pc) } });
            context.pc += 1;
        },
        0x56, 0x57 => { // JUMP, JUMPI
            const handler = context.opcode_handlers.*[@intFromEnum(opcode_enum)];
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            try context.schedule_items.append(context.allocator, .{ .jump_dest = .{ .gas = 0 } });
            context.pc += 1;
        },
        else => {
            // Regular opcode - just add the handler
            const handler = context.opcode_handlers.*[@intFromEnum(opcode_enum)];
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            context.pc += 1;
        },
    }
}

/// Process a fusion pattern
fn processFusion(comptime FrameType: type, context: *ProcessContext(FrameType), fusion_type: FusionType) !void {
    _ = @import("../preprocessor/dispatch.zig").Dispatch(FrameType);
    const frame_handlers = @import("../frame/frame_handlers.zig");
    
    // Mark fusion candidate
    context.packed_bitmap[context.pc].is_fusion_candidate = true;
    
    switch (fusion_type) {
        .constant_fold => {
            // PUSH1 x, PUSH1 y, ADD/SUB/MUL
            const value1 = context.runtime_code[context.pc + 1];
            const value2 = context.runtime_code[context.pc + 3];
            const arith_op = context.runtime_code[context.pc + 4];
            
            const folded_value: u256 = switch (arith_op) {
                0x01 => @as(u256, value1) +% @as(u256, value2), // ADD
                0x02 => @as(u256, value1) *% @as(u256, value2), // MUL
                0x03 => @as(u256, value1) -% @as(u256, value2), // SUB
                else => unreachable,
            };
            
            const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.CONSTANT_FOLD));
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            
            if (folded_value <= std.math.maxInt(u64)) {
                try context.schedule_items.append(context.allocator, .{ .push_inline = .{ .value = @intCast(folded_value) } });
            } else {
                const value_ptr = try context.allocator.create(u256);
                value_ptr.* = folded_value;
                try context.schedule_items.append(context.allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
            
            context.pc += 5;
        },
        .multi_push_3 => {
            const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_3));
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            
            // Process 3 PUSH instructions
            var pc = context.pc;
            for (0..3) |_| {
                const push_op = context.runtime_code[pc];
                const push_size = push_op - 0x5F;
                
                var value: u256 = 0;
                for (1..push_size + 1) |i| {
                    value = std.math.shl(u256, value, 8) | context.runtime_code[pc + i];
                }
                
                if (value <= std.math.maxInt(u64)) {
                    try context.schedule_items.append(context.allocator, .{ .push_inline = .{ .value = @intCast(value) } });
                } else {
                    const value_ptr = try context.allocator.create(u256);
                    value_ptr.* = value;
                    try context.schedule_items.append(context.allocator, .{ .push_pointer = .{ .value = value_ptr } });
                }
                
                pc += 1 + push_size;
            }
            
            context.pc = pc;
        },
        .multi_push_2 => {
            const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_2));
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            
            // Process 2 PUSH instructions
            var pc = context.pc;
            for (0..2) |_| {
                const push_op = context.runtime_code[pc];
                const push_size = push_op - 0x5F;
                
                var value: u256 = 0;
                for (1..push_size + 1) |i| {
                    value = std.math.shl(u256, value, 8) | context.runtime_code[pc + i];
                }
                
                if (value <= std.math.maxInt(u64)) {
                    try context.schedule_items.append(context.allocator, .{ .push_inline = .{ .value = @intCast(value) } });
                } else {
                    const value_ptr = try context.allocator.create(u256);
                    value_ptr.* = value;
                    try context.schedule_items.append(context.allocator, .{ .push_pointer = .{ .value = value_ptr } });
                }
                
                pc += 1 + push_size;
            }
            
            context.pc = pc;
        },
        .multi_pop_3 => {
            const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_3));
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            context.pc += 3;
        },
        .multi_pop_2 => {
            const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_2));
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            context.pc += 2;
        },
        .iszero_jumpi => {
            const push_op = context.runtime_code[context.pc + 1];
            const push_size = push_op - 0x5F;
            
            var target: u256 = 0;
            for (1..push_size + 1) |i| {
                target = std.math.shl(u256, target, 8) | context.runtime_code[context.pc + 1 + i];
            }
            
            const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.ISZERO_JUMPI));
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            
            if (target <= std.math.maxInt(u64)) {
                try context.schedule_items.append(context.allocator, .{ .push_inline = .{ .value = @intCast(target) } });
            } else {
                const value_ptr = try context.allocator.create(u256);
                value_ptr.* = target;
                try context.schedule_items.append(context.allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
            
            context.pc += 2 + push_size + 1; // ISZERO + PUSH + data + JUMPI
        },
        .dup2_mstore_push => {
            const push_op = context.runtime_code[context.pc + 2];
            const push_size = push_op - 0x5F;
            
            var value: u256 = 0;
            for (1..push_size + 1) |i| {
                value = std.math.shl(u256, value, 8) | context.runtime_code[context.pc + 2 + i];
            }
            
            const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.DUP2_MSTORE_PUSH));
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            
            if (value <= std.math.maxInt(u64)) {
                try context.schedule_items.append(context.allocator, .{ .push_inline = .{ .value = @intCast(value) } });
            } else {
                const value_ptr = try context.allocator.create(u256);
                value_ptr.* = value;
                try context.schedule_items.append(context.allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
            
            context.pc += 3 + push_size;
        },
        .push_add, .push_mul, .push_sub, .push_div,
        .push_and, .push_or, .push_xor,
        .push_jump, .push_jumpi,
        .push_mload, .push_mstore, .push_mstore8 => {
            // Handle 2-opcode PUSH + operation fusions
            const push_op = context.runtime_code[context.pc];
            const push_size = push_op - 0x5F;
            
            var value: u256 = 0;
            for (1..push_size + 1) |i| {
                value = std.math.shl(u256, value, 8) | context.runtime_code[context.pc + i];
            }
            
            const is_inline = value <= std.math.maxInt(u64);
            const synthetic_opcode = getSyntheticOpcode(fusion_type, is_inline);
            const handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);
            
            try context.schedule_items.append(context.allocator, .{ .opcode_handler = handler });
            
            // Handle static jumps specially
            if (fusion_type == .push_jump or fusion_type == .push_jumpi) {
                const JumpSyntheticHandlers = @import("../instructions/handlers_jump_synthetic.zig").Handlers(FrameType);
                const jump_handler = if (fusion_type == .push_jump)
                    &JumpSyntheticHandlers.jump_to_static_location
                else
                    &JumpSyntheticHandlers.jumpi_to_static_location;
                
                context.schedule_items.items[context.schedule_items.items.len - 1] = .{ .opcode_handler = jump_handler };
                
                // Add unresolved jump for later resolution
                if (value <= std.math.maxInt(FrameType.PcType)) {
                    const metadata_index = context.schedule_items.items.len;
                    try context.schedule_items.append(context.allocator, .{ .jump_static = .{ .dispatch = undefined } });
                    try context.unresolved_jumps.append(context.allocator, .{
                        .schedule_index = metadata_index,
                        .target_pc = @intCast(value),
                    });
                } else {
                    try context.schedule_items.append(context.allocator, .{ .jump_static = .{ .dispatch = undefined } });
                }
            } else {
                // Regular fusion metadata
                if (is_inline) {
                    try context.schedule_items.append(context.allocator, .{ .push_inline = .{ .value = @intCast(value) } });
                } else {
                    const value_ptr = try context.allocator.create(u256);
                    value_ptr.* = value;
                    try context.schedule_items.append(context.allocator, .{ .push_pointer = .{ .value = value_ptr } });
                }
            }
            
            context.pc += 1 + push_size + 1; // PUSH + data + operation
        },
        .none => unreachable,
    }
}

/// Get synthetic opcode for fusion type
fn getSyntheticOpcode(fusion_type: FusionType, is_inline: bool) u8 {
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
        .push_mload => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER),
        .push_mstore => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER),
        .push_mstore8 => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER),
        else => unreachable,
    };
}

/// Resolve jump targets after schedule is built
fn resolveJumps(comptime FrameType: type, context: *ProcessContext(FrameType), schedule: []@import("../preprocessor/dispatch.zig").Dispatch(FrameType).Item) !void {
    for (context.unresolved_jumps.items) |unresolved| {
        if (context.jumpdest_map.get(unresolved.target_pc)) |target_schedule_idx| {
            // Update the jump_static metadata with resolved dispatch pointer
            schedule[unresolved.schedule_index].jump_static = .{
                .dispatch = @as(*const anyopaque, @ptrCast(schedule.ptr + target_schedule_idx)),
            };
        }
        // Invalid jump destinations leave undefined dispatch pointer
    }
}

/// Build jump table from collected data
fn buildJumpTable(
    comptime FrameType: type,
    allocator: std.mem.Allocator,
    jumpdest_map: *std.AutoHashMap(FrameType.PcType, usize),
    schedule: []const @import("../preprocessor/dispatch.zig").Dispatch(FrameType).Item,
) !@import("../preprocessor/dispatch.zig").Dispatch(FrameType).JumpTable {
    const DispatchType = @import("../preprocessor/dispatch.zig").Dispatch(FrameType);
    
    const entries = try allocator.alloc(DispatchType.JumpTable.JumpTableEntry, jumpdest_map.count());
    errdefer allocator.free(entries);
    
    var i: usize = 0;
    var iter = jumpdest_map.iterator();
    while (iter.next()) |entry| {
        log.warn("[jump-table] entry pc=0x{x} -> sched[{}]", .{ entry.key_ptr.*, entry.value_ptr.* });
        entries[i] = .{
            .pc = entry.key_ptr.*,
            .dispatch = DispatchType{
                .cursor = schedule.ptr + entry.value_ptr.*,
            },
        };
        i += 1;
    }
    
    // Sort entries by PC
    std.sort.block(DispatchType.JumpTable.JumpTableEntry, entries, {}, struct {
        pub fn lessThan(context: void, a: DispatchType.JumpTable.JumpTableEntry, b: DispatchType.JumpTable.JumpTableEntry) bool {
            _ = context;
            return a.pc < b.pc;
        }
    }.lessThan);
    
    return DispatchType.JumpTable{ .entries = entries };
}

// Tests
const testing = std.testing;

test "single-pass handles empty bytecode" {
    const allocator = testing.allocator;
    const FrameType = struct {
        pub const PcType = u32;
        pub const WordType = u256;
        pub const Error = error{};
        pub const OpcodeHandler = *const fn () void;
    };
    
    var handlers: [256]FrameType.OpcodeHandler = undefined;
    for (&handlers) |*h| {
        h.* = @ptrCast(&testHandler);
    }
    
    const result = try analyzeAndPreprocess(FrameType, allocator, &[_]u8{}, &handlers);
    defer {
        allocator.free(result.packed_bitmap);
        allocator.free(result.dispatch_schedule);
        if (result.jump_table.entries.len > 0) {
            allocator.free(result.jump_table.entries);
        }
    }
    
    try testing.expectEqual(@as(usize, 2), result.dispatch_schedule.len); // Two STOP handlers
}

test "single-pass detects JUMPDEST" {
    const allocator = testing.allocator;
    const FrameType = struct {
        pub const PcType = u32;
        pub const WordType = u256;
        pub const Error = error{};
        pub const OpcodeHandler = *const fn () void;
    };
    
    var handlers: [256]FrameType.OpcodeHandler = undefined;
    for (&handlers) |*h| {
        h.* = @ptrCast(&testHandler);
    }
    
    const bytecode = [_]u8{ 0x5B, 0x00 }; // JUMPDEST, STOP
    const result = try analyzeAndPreprocess(FrameType, allocator, &bytecode, &handlers);
    defer {
        allocator.free(result.packed_bitmap);
        allocator.free(result.dispatch_schedule);
        if (result.jump_table.entries.len > 0) {
            allocator.free(result.jump_table.entries);
        }
    }
    
    try testing.expect(result.packed_bitmap[0].is_jumpdest);
    try testing.expectEqual(@as(usize, 1), result.jump_table.entries.len);
}

test "single-pass detects PUSH instructions" {
    const allocator = testing.allocator;
    const FrameType = struct {
        pub const PcType = u32;
        pub const WordType = u256;
        pub const Error = error{};
        pub const OpcodeHandler = *const fn () void;
    };
    
    var handlers: [256]FrameType.OpcodeHandler = undefined;
    for (&handlers) |*h| {
        h.* = @ptrCast(&testHandler);
    }
    
    const bytecode = [_]u8{ 0x60, 0x42, 0x00 }; // PUSH1 0x42, STOP
    const result = try analyzeAndPreprocess(FrameType, allocator, &bytecode, &handlers);
    defer {
        allocator.free(result.packed_bitmap);
        allocator.free(result.dispatch_schedule);
        if (result.jump_table.entries.len > 0) {
            allocator.free(result.jump_table.entries);
        }
    }
    
    try testing.expect(result.packed_bitmap[0].is_op_start);
    try testing.expect(result.packed_bitmap[1].is_push_data);
    try testing.expect(!result.packed_bitmap[1].is_op_start);
}

fn testHandler() void {}
