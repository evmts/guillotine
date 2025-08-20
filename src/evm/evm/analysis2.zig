const std = @import("std");
const Opcode = @import("../opcodes/opcode.zig").Enum;
const opcode_mod = @import("../opcodes/opcode.zig");
const tailcalls = @import("tailcalls.zig");
const Log = @import("../log.zig");

/// Map an opcode byte to its tailcall function pointer
fn get_tailcall_for_opcode(opcode_byte: u8) tailcalls.TailcallFunc {
    // Handle push opcodes
    if (opcode_mod.is_push(opcode_byte)) {
        return &tailcalls.op_push;
    }
    
    // Handle invalid opcodes
    if (!opcode_mod.is_valid_opcode(opcode_byte)) {
        return &tailcalls.op_invalid;
    }
    
    const opcode = @as(Opcode, @enumFromInt(opcode_byte));
    return switch (opcode) {
        .STOP => &tailcalls.op_stop,
        .ADD => &tailcalls.op_add,
        .MUL => &tailcalls.op_mul,
        .SUB => &tailcalls.op_sub,
        .DIV => &tailcalls.op_div,
        .SDIV => &tailcalls.op_sdiv,
        .MOD => &tailcalls.op_mod,
        .SMOD => &tailcalls.op_smod,
        .ADDMOD => &tailcalls.op_addmod,
        .MULMOD => &tailcalls.op_mulmod,
        .EXP => &tailcalls.op_exp,
        .SIGNEXTEND => &tailcalls.op_signextend,
        .LT => &tailcalls.op_lt,
        .GT => &tailcalls.op_gt,
        .SLT => &tailcalls.op_slt,
        .SGT => &tailcalls.op_sgt,
        .EQ => &tailcalls.op_eq,
        .ISZERO => &tailcalls.op_iszero,
        .AND => &tailcalls.op_and,
        .OR => &tailcalls.op_or,
        .XOR => &tailcalls.op_xor,
        .NOT => &tailcalls.op_not,
        .BYTE => &tailcalls.op_byte,
        .SHL => &tailcalls.op_shl,
        .SHR => &tailcalls.op_shr,
        .SAR => &tailcalls.op_sar,
        .KECCAK256 => &tailcalls.op_keccak256,
        .ADDRESS => &tailcalls.op_address,
        .BALANCE => &tailcalls.op_balance,
        .ORIGIN => &tailcalls.op_origin,
        .CALLER => &tailcalls.op_caller,
        .CALLVALUE => &tailcalls.op_callvalue,
        .CALLDATALOAD => &tailcalls.op_calldataload,
        .CALLDATASIZE => &tailcalls.op_calldatasize,
        .CALLDATACOPY => &tailcalls.op_calldatacopy,
        .CODESIZE => &tailcalls.op_codesize,
        .CODECOPY => &tailcalls.op_codecopy,
        .GASPRICE => &tailcalls.op_gasprice,
        .EXTCODESIZE => &tailcalls.op_extcodesize,
        .EXTCODECOPY => &tailcalls.op_extcodecopy,
        .RETURNDATASIZE => &tailcalls.op_returndatasize,
        .RETURNDATACOPY => &tailcalls.op_returndatacopy,
        .EXTCODEHASH => &tailcalls.op_extcodehash,
        .BLOCKHASH => &tailcalls.op_blockhash,
        .COINBASE => &tailcalls.op_coinbase,
        .TIMESTAMP => &tailcalls.op_timestamp,
        .NUMBER => &tailcalls.op_number,
        .PREVRANDAO => &tailcalls.op_difficulty,
        .GASLIMIT => &tailcalls.op_gaslimit,
        .CHAINID => &tailcalls.op_chainid,
        .SELFBALANCE => &tailcalls.op_selfbalance,
        .BASEFEE => &tailcalls.op_basefee,
        .BLOBHASH => &tailcalls.op_blobhash,
        .BLOBBASEFEE => &tailcalls.op_blobbasefee,
        .POP => &tailcalls.op_pop,
        .MLOAD => &tailcalls.op_mload,
        .MSTORE => &tailcalls.op_mstore,
        .MSTORE8 => &tailcalls.op_mstore8,
        .SLOAD => &tailcalls.op_sload,
        .SSTORE => &tailcalls.op_sstore,
        .JUMP => &tailcalls.op_jump,
        .JUMPI => &tailcalls.op_jumpi,
        .PC => &tailcalls.op_pc,
        .MSIZE => &tailcalls.op_msize,
        .GAS => &tailcalls.op_gas,
        .JUMPDEST => &tailcalls.op_jumpdest,
        .TLOAD => &tailcalls.op_tload,
        .TSTORE => &tailcalls.op_tstore,
        .MCOPY => &tailcalls.op_mcopy,
        .PUSH0 => &tailcalls.op_push0,
        .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
        .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
        .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
        .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => unreachable, // handled above
        .DUP1 => &tailcalls.op_dup1,
        .DUP2 => &tailcalls.op_dup2,
        .DUP3 => &tailcalls.op_dup3,
        .DUP4 => &tailcalls.op_dup4,
        .DUP5 => &tailcalls.op_dup5,
        .DUP6 => &tailcalls.op_dup6,
        .DUP7 => &tailcalls.op_dup7,
        .DUP8 => &tailcalls.op_dup8,
        .DUP9 => &tailcalls.op_dup9,
        .DUP10 => &tailcalls.op_dup10,
        .DUP11 => &tailcalls.op_dup11,
        .DUP12 => &tailcalls.op_dup12,
        .DUP13 => &tailcalls.op_dup13,
        .DUP14 => &tailcalls.op_dup14,
        .DUP15 => &tailcalls.op_dup15,
        .DUP16 => &tailcalls.op_dup16,
        .SWAP1 => &tailcalls.op_swap1,
        .SWAP2 => &tailcalls.op_swap2,
        .SWAP3 => &tailcalls.op_swap3,
        .SWAP4 => &tailcalls.op_swap4,
        .SWAP5 => &tailcalls.op_swap5,
        .SWAP6 => &tailcalls.op_swap6,
        .SWAP7 => &tailcalls.op_swap7,
        .SWAP8 => &tailcalls.op_swap8,
        .SWAP9 => &tailcalls.op_swap9,
        .SWAP10 => &tailcalls.op_swap10,
        .SWAP11 => &tailcalls.op_swap11,
        .SWAP12 => &tailcalls.op_swap12,
        .SWAP13 => &tailcalls.op_swap13,
        .SWAP14 => &tailcalls.op_swap14,
        .SWAP15 => &tailcalls.op_swap15,
        .SWAP16 => &tailcalls.op_swap16,
        .LOG0 => &tailcalls.op_log0,
        .LOG1 => &tailcalls.op_log1,
        .LOG2 => &tailcalls.op_log2,
        .LOG3 => &tailcalls.op_log3,
        .LOG4 => &tailcalls.op_log4,
        .CREATE => &tailcalls.op_create,
        .CALL => &tailcalls.op_call,
        .CALLCODE => &tailcalls.op_callcode,
        .RETURN => &tailcalls.op_return,
        .DELEGATECALL => &tailcalls.op_delegatecall,
        .CREATE2 => &tailcalls.op_create2,
        .STATICCALL => &tailcalls.op_staticcall,
        .REVERT => &tailcalls.op_revert,
        .INVALID => &tailcalls.op_invalid,
        .SELFDESTRUCT => &tailcalls.op_selfdestruct,
        // New EOF opcodes - not yet implemented
        .RETURNDATALOAD => &tailcalls.op_invalid,
        .EXTCALL => &tailcalls.op_invalid,
        .EXTDELEGATECALL => &tailcalls.op_invalid,
        .EXTSTATICCALL => &tailcalls.op_invalid,
    };
}

/// Simple analysis result for tailcall dispatch with precomputed mappings
pub const SimpleAnalysis = struct {
    /// Mapping from instruction index to PC value
    inst_to_pc: []u16,
    /// Mapping from PC to instruction index (MAX_USIZE if not an instruction start)
    pc_to_inst: []u16,
    /// Reference to the original bytecode for reading push values
    bytecode: []const u8,

    pub const MAX_USIZE: u16 = std.math.maxInt(u16);
    
    /// Up-front allocation size for SimpleAnalysis
    /// This is a worst-case calculation assuming:
    /// - Maximum bytecode size (64KB = max u16)
    /// - Every byte is an instruction (worst case)
    /// - inst_to_pc: max 64K instructions * 2 bytes = 128KB
    /// - pc_to_inst: 64KB * 2 bytes = 128KB
    /// Total: 256KB for worst case
    pub const UP_FRONT_ALLOCATION = (std.math.maxInt(u16) + 1) * @sizeOf(u16) * 2;

    pub fn deinit(self: *SimpleAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.inst_to_pc);
        allocator.free(self.pc_to_inst);
    }

    /// Get the PC value for a given instruction index
    pub fn getPc(self: *const SimpleAnalysis, inst_idx: u16) u16 {
        return self.inst_to_pc[inst_idx];
    }

    /// Get the instruction index for a given PC
    pub fn getInstIdx(self: *const SimpleAnalysis, pc: u16) u16 {
        return self.pc_to_inst[pc];
    }

    /// Build analysis from bytecode and return metadata separately
    pub fn analyze(allocator: std.mem.Allocator, code: []const u8) !struct { analysis: SimpleAnalysis, metadata: []u32 } {
        if (code.len > std.math.maxInt(u16)) return error.OutOfMemory; // enforce u16 bounds
        var inst_to_pc_list = std.ArrayList(u16).init(allocator);
        defer inst_to_pc_list.deinit();

        var metadata_list = std.ArrayList(u32).init(allocator);
        defer metadata_list.deinit();

        var pc_to_inst = try allocator.alloc(u16, code.len);
        @memset(pc_to_inst, MAX_USIZE);

        var pc: u16 = 0;
        var inst_idx: u16 = 0;

        while (pc < code.len) {
            const byte = code[pc];

            // Record instruction start
            try inst_to_pc_list.append(pc);
            pc_to_inst[pc] = inst_idx;

            // Build metadata for this instruction
            if (byte >= 0x60 and byte <= 0x7F) {
                // PUSH1-PUSH32
                const push_size = byte - 0x5F;

                // Metadata usage pattern:
                // - Small pushes (PUSH1-4): store the immediate value directly when fully available
                //   This avoids an extra bytecode read at runtime for the hot path
                // - Larger pushes (PUSH5-32): store the PC to read the value on demand
                // - Truncated small pushes: store PC so runtime can fall back to generic path
                if (push_size <= 4 and @as(usize, pc) + 1 + push_size <= code.len) {
                    var value: u32 = 0;
                    var i: usize = 0;
                    while (i < push_size) : (i += 1) {
                        value = (value << 8) | code[@as(usize, pc) + 1 + i];
                    }
                    try metadata_list.append(value);
                } else {
                    try metadata_list.append(@intCast(pc));
                }

                pc += 1 + push_size;
            } else if (byte == 0x5F) {
                // PUSH0 - store 0 directly
                try metadata_list.append(0);
                pc += 1;
            } else if (byte == 0x58) {
                // PC opcode - store the PC value
                try metadata_list.append(@intCast(pc));
                pc += 1;
            } else {
                // Other opcodes - no metadata needed
                try metadata_list.append(0);
                pc += 1;
            }

            inst_idx += 1;
        }

        return .{
            .analysis = SimpleAnalysis{
                .inst_to_pc = try inst_to_pc_list.toOwnedSlice(),
                .pc_to_inst = pc_to_inst,
                .bytecode = code,
            },
            .metadata = try metadata_list.toOwnedSlice(),
        };
    }
};

/// Up-front allocation size for metadata array
/// Worst case: every instruction needs metadata (1 u32 per instruction)
/// Maximum 64K instructions * 4 bytes = 256KB
pub const METADATA_UP_FRONT_ALLOCATION = (std.math.maxInt(u16) + 1) * @sizeOf(u32);

/// Up-front allocation size for ops array
/// Worst case: every byte is an opcode + 1 for terminating STOP
/// Maximum 64K opcodes * pointer size
pub const OPS_UP_FRONT_ALLOCATION = ((std.math.maxInt(u16) + 1) + 1) * @sizeOf(tailcalls.TailcallFunc);

/// Allocation information for pre-allocation strategy
pub const AllocationInfo = struct {
    size: usize,
    alignment: usize = 8,
    can_grow: bool = false,
};

/// Count actual instructions in bytecode, skipping push data
pub fn count_instructions(code: []const u8) usize {
    var inst_count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const byte = code[pc];
        if (byte >= 0x60 and byte <= 0x7F) {
            // PUSH instruction - skip push data
            const push_size = byte - 0x5F;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
        inst_count += 1;
    }
    return inst_count;
}

/// Calculate allocation requirements for SimpleAnalysis arrays
/// Based on actual instruction count, calculates space needed for inst_to_pc and pc_to_inst
pub fn calculate_analysis_allocation(bytecode_size: usize) AllocationInfo {
    // For backwards compatibility, still use bytecode_size as worst case
    // Callers should use calculate_analysis_allocation_exact for optimal allocation
    const max_instructions = bytecode_size;
    return .{
        .size = max_instructions * @sizeOf(u16) * 2, // inst_to_pc + pc_to_inst
        .alignment = @alignOf(u16),
        .can_grow = false,
    };
}

/// Calculate exact allocation requirements for SimpleAnalysis arrays
/// Based on actual instruction count, calculates space needed for inst_to_pc and pc_to_inst
pub fn calculate_analysis_allocation_exact(instruction_count: usize, bytecode_size: usize) AllocationInfo {
    // inst_to_pc needs instruction_count entries
    // pc_to_inst needs bytecode_size entries for O(1) lookup
    return .{
        .size = instruction_count * @sizeOf(u16) + bytecode_size * @sizeOf(u16),
        .alignment = @alignOf(u16),
        .can_grow = false,
    };
}

/// Calculate allocation requirements for metadata array
/// Based on bytecode size, calculates space needed for metadata
pub fn calculate_metadata_allocation(bytecode_size: usize) AllocationInfo {
    // Worst case: every byte is an instruction needing metadata
    const max_instructions = bytecode_size;
    return .{
        .size = max_instructions * @sizeOf(u32),
        .alignment = @alignOf(u32),
        .can_grow = false,
    };
}

/// Calculate exact allocation requirements for metadata array
/// Based on actual instruction count, calculates space needed for metadata
pub fn calculate_metadata_allocation_exact(instruction_count: usize) AllocationInfo {
    return .{
        .size = instruction_count * @sizeOf(u32),
        .alignment = @alignOf(u32),
        .can_grow = false,
    };
}

/// Calculate allocation requirements for ops array
/// Based on bytecode size, calculates space needed for function pointers
pub fn calculate_ops_allocation(bytecode_size: usize) AllocationInfo {
    // Worst case: every byte is an opcode + 1 for terminating STOP
    const max_ops = bytecode_size + 1;
    return .{
        .size = max_ops * @sizeOf(tailcalls.TailcallFunc),
        .alignment = @alignOf(tailcalls.TailcallFunc),
        .can_grow = false,
    };
}

/// Calculate exact allocation requirements for ops array
/// Based on actual instruction count, calculates space needed for function pointers
pub fn calculate_ops_allocation_exact(instruction_count: usize) AllocationInfo {
    // +1 for terminating STOP
    const ops_count = instruction_count + 1;
    return .{
        .size = ops_count * @sizeOf(tailcalls.TailcallFunc),
        .alignment = @alignOf(tailcalls.TailcallFunc),
        .can_grow = false,
    };
}

/// Build analysis and ops array with pre-allocated buffers
/// This version accepts pre-allocated slices to avoid internal allocations
pub fn prepare_with_buffers(
    inst_to_pc: []u16,
    pc_to_inst: []u16,
    metadata: []u32,
    ops: []tailcalls.TailcallFunc,
    code: []const u8,
) !struct {
    analysis: SimpleAnalysis,
    metadata: []u32,
    ops: []tailcalls.TailcallFunc,
} {
    // Verify buffer sizes are sufficient
    if (code.len > std.math.maxInt(u16)) return error.CodeTooLarge;
    
    // Count actual instructions first
    var inst_count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const byte = code[pc];
        if (byte >= 0x60 and byte <= 0x7F) {
            // PUSH instruction
            const push_size = byte - 0x5F;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
        inst_count += 1;
    }
    
    // Verify buffers are large enough
    std.debug.assert(inst_to_pc.len >= inst_count);
    std.debug.assert(pc_to_inst.len >= code.len);
    std.debug.assert(metadata.len >= inst_count);
    std.debug.assert(ops.len >= inst_count + 1); // +1 for terminating op_stop
    
    // Initialize pc_to_inst with MAX_USIZE
    @memset(pc_to_inst[0..code.len], SimpleAnalysis.MAX_USIZE);
    
    // Build analysis mappings
    pc = 0;
    var inst_idx: u16 = 0;
    
    while (pc < code.len) {
        const byte = code[pc];
        
        // Record instruction start
        inst_to_pc[inst_idx] = @intCast(pc);
        pc_to_inst[pc] = inst_idx;
        
        // Build metadata for this instruction
        if (byte >= 0x60 and byte <= 0x7F) {
            // PUSH1-PUSH32
            const push_size = byte - 0x5F;
            
            if (push_size <= 4 and pc + 1 + push_size <= code.len) {
                var value: u32 = 0;
                var i: usize = 0;
                while (i < push_size) : (i += 1) {
                    value = (value << 8) | code[pc + 1 + i];
                }
                metadata[inst_idx] = value;
            } else {
                metadata[inst_idx] = @intCast(pc);
            }
            
            pc += 1 + push_size;
        } else if (byte == 0x5F) {
            // PUSH0
            metadata[inst_idx] = 0;
            pc += 1;
        } else if (byte == 0x58) {
            // PC opcode
            metadata[inst_idx] = @intCast(pc);
            pc += 1;
        } else {
            // Other opcodes
            metadata[inst_idx] = 0;
            pc += 1;
        }
        
        inst_idx += 1;
    }
    
    // Build ops array with fusion patterns
    var i: usize = 0;
    while (i < inst_count) : (i += 1) {
        const opcode_pc = inst_to_pc[i];
        const opcode = code[opcode_pc];
        
        // Check for PUSH fusion opportunities
        if (opcode >= 0x60 and opcode <= 0x64) { // PUSH1-PUSH5
            if (i + 1 < inst_count) {
                const next_pc = inst_to_pc[i + 1];
                const next_opcode = code[next_pc];
                
                // Map fusion patterns
                const fused_op = switch (next_opcode) {
                    0x01 => &tailcalls.op_push_then_add,
                    0x02 => &tailcalls.op_push_then_mul,
                    0x03 => &tailcalls.op_push_then_sub,
                    0x10 => &tailcalls.op_push_then_lt,
                    0x11 => &tailcalls.op_push_then_gt,
                    0x14 => &tailcalls.op_push_then_eq,
                    0x16 => &tailcalls.op_push_then_and,
                    // TODO: implement these fusion operations
                    // 0x17 => &tailcalls.op_push_then_or,
                    // 0x18 => &tailcalls.op_push_then_xor,
                    // 0x1B => &tailcalls.op_push_then_shl,
                    // 0x1C => &tailcalls.op_push_then_shr,
                    else => null,
                };
                
                if (fused_op) |op| {
                    ops[i] = op;
                    i += 1; // Skip the next instruction
                    ops[i] = &tailcalls.op_nop;
                    continue;
                }
            }
        }
        
        // Regular opcode mapping
        ops[i] = get_tailcall_for_opcode(opcode);
    }
    
    // Add terminating op_stop
    ops[inst_count] = &tailcalls.op_stop;
    
    // Return slices trimmed to actual size
    return .{
        .analysis = SimpleAnalysis{
            .inst_to_pc = inst_to_pc[0..inst_count],
            .pc_to_inst = pc_to_inst[0..code.len],
            .bytecode = code,
        },
        .metadata = metadata[0..inst_count],
        .ops = ops[0..inst_count + 1],
    };
}

/// Build the tailcall ops array and return together with analysis and metadata
/// This encapsulates opcode decoding and fusion logic for PUSH+X patterns
pub fn prepare(allocator: std.mem.Allocator, code: []const u8) !struct {
    analysis: SimpleAnalysis,
    metadata: []u32,
    ops: []tailcalls.TailcallFunc,
} {
    if (code.len > std.math.maxInt(u16)) return error.OutOfMemory;

    // Phase 1: basic analysis + metadata
    const res = try SimpleAnalysis.analyze(allocator, code);
    const analysis = res.analysis;
    const metadata = res.metadata;

    // Phase 1.5: decode to ops array
    var ops_list = std.ArrayList(tailcalls.TailcallFunc).init(allocator);
    errdefer ops_list.deinit();

    var pc: usize = 0;
    while (pc < code.len) {
        const byte = code[pc];

        if (opcode_mod.is_push(byte)) {
            const push_size = opcode_mod.get_push_size(byte);
            try ops_list.append(&tailcalls.op_push);
            pc += 1 + push_size;
            continue;
        }

        if (!opcode_mod.is_valid_opcode(byte)) {
            // Solidity metadata markers 0xa1/0xa2 followed by 0x65
            if ((byte == 0xa1 or byte == 0xa2) and pc + 1 < code.len and code[pc + 1] == 0x65) {
                Log.debug("[analysis2] Found Solidity metadata marker at PC={}, stopping", .{pc});
                break;
            }
            Log.warn("[analysis2] WARNING: Unknown opcode 0x{x:0>2} at PC={}, treating as INVALID", .{ byte, pc });
            try ops_list.append(&tailcalls.op_invalid);
            pc += 1;
            continue;
        }

        const opcode = @as(Opcode, @enumFromInt(byte));
        const fn_ptr: tailcalls.TailcallFunc = switch (opcode) {
            .STOP => &tailcalls.op_stop,
            .ADD => &tailcalls.op_add,
            .MUL => &tailcalls.op_mul,
            .SUB => &tailcalls.op_sub,
            .DIV => &tailcalls.op_div,
            .SDIV => &tailcalls.op_sdiv,
            .MOD => &tailcalls.op_mod,
            .SMOD => &tailcalls.op_smod,
            .ADDMOD => &tailcalls.op_addmod,
            .MULMOD => &tailcalls.op_mulmod,
            .EXP => &tailcalls.op_exp,
            .SIGNEXTEND => &tailcalls.op_signextend,
            .LT => &tailcalls.op_lt,
            .GT => &tailcalls.op_gt,
            .SLT => &tailcalls.op_slt,
            .SGT => &tailcalls.op_sgt,
            .EQ => &tailcalls.op_eq,
            .ISZERO => &tailcalls.op_iszero,
            .AND => &tailcalls.op_and,
            .OR => &tailcalls.op_or,
            .XOR => &tailcalls.op_xor,
            .NOT => &tailcalls.op_not,
            .BYTE => &tailcalls.op_byte,
            .SHL => &tailcalls.op_shl,
            .SHR => &tailcalls.op_shr,
            .SAR => &tailcalls.op_sar,
            .KECCAK256 => &tailcalls.op_keccak256,
            .ADDRESS => &tailcalls.op_address,
            .BALANCE => &tailcalls.op_balance,
            .ORIGIN => &tailcalls.op_origin,
            .CALLER => &tailcalls.op_caller,
            .CALLVALUE => &tailcalls.op_callvalue,
            .CALLDATALOAD => &tailcalls.op_calldataload,
            .CALLDATASIZE => &tailcalls.op_calldatasize,
            .CALLDATACOPY => &tailcalls.op_calldatacopy,
            .CODESIZE => &tailcalls.op_codesize,
            .CODECOPY => &tailcalls.op_codecopy,
            .GASPRICE => &tailcalls.op_gasprice,
            .EXTCODESIZE => &tailcalls.op_extcodesize,
            .EXTCODECOPY => &tailcalls.op_extcodecopy,
            .RETURNDATASIZE => &tailcalls.op_returndatasize,
            .RETURNDATACOPY => &tailcalls.op_returndatacopy,
            .EXTCODEHASH => &tailcalls.op_extcodehash,
            .BLOCKHASH => &tailcalls.op_blockhash,
            .COINBASE => &tailcalls.op_coinbase,
            .TIMESTAMP => &tailcalls.op_timestamp,
            .NUMBER => &tailcalls.op_number,
            .PREVRANDAO => &tailcalls.op_difficulty,
            .GASLIMIT => &tailcalls.op_gaslimit,
            .CHAINID => &tailcalls.op_chainid,
            .SELFBALANCE => &tailcalls.op_selfbalance,
            .BASEFEE => &tailcalls.op_basefee,
            .BLOBHASH => &tailcalls.op_blobhash,
            .BLOBBASEFEE => &tailcalls.op_blobbasefee,
            .POP => &tailcalls.op_pop,
            .MLOAD => &tailcalls.op_mload,
            .MSTORE => &tailcalls.op_mstore,
            .MSTORE8 => &tailcalls.op_mstore8,
            .SLOAD => &tailcalls.op_sload,
            .SSTORE => &tailcalls.op_sstore,
            .JUMP => &tailcalls.op_jump,
            .JUMPI => &tailcalls.op_jumpi,
            .PC => &tailcalls.op_pc,
            .MSIZE => &tailcalls.op_msize,
            .GAS => &tailcalls.op_gas,
            .JUMPDEST => &tailcalls.op_jumpdest,
            .TLOAD => &tailcalls.op_tload,
            .TSTORE => &tailcalls.op_tstore,
            .MCOPY => &tailcalls.op_mcopy,
            .PUSH0 => &tailcalls.op_push0,
            .DUP1 => &tailcalls.op_dup1,
            .DUP2 => &tailcalls.op_dup2,
            .DUP3 => &tailcalls.op_dup3,
            .DUP4 => &tailcalls.op_dup4,
            .DUP5 => &tailcalls.op_dup5,
            .DUP6 => &tailcalls.op_dup6,
            .DUP7 => &tailcalls.op_dup7,
            .DUP8 => &tailcalls.op_dup8,
            .DUP9 => &tailcalls.op_dup9,
            .DUP10 => &tailcalls.op_dup10,
            .DUP11 => &tailcalls.op_dup11,
            .DUP12 => &tailcalls.op_dup12,
            .DUP13 => &tailcalls.op_dup13,
            .DUP14 => &tailcalls.op_dup14,
            .DUP15 => &tailcalls.op_dup15,
            .DUP16 => &tailcalls.op_dup16,
            .SWAP1 => &tailcalls.op_swap1,
            .SWAP2 => &tailcalls.op_swap2,
            .SWAP3 => &tailcalls.op_swap3,
            .SWAP4 => &tailcalls.op_swap4,
            .SWAP5 => &tailcalls.op_swap5,
            .SWAP6 => &tailcalls.op_swap6,
            .SWAP7 => &tailcalls.op_swap7,
            .SWAP8 => &tailcalls.op_swap8,
            .SWAP9 => &tailcalls.op_swap9,
            .SWAP10 => &tailcalls.op_swap10,
            .SWAP11 => &tailcalls.op_swap11,
            .SWAP12 => &tailcalls.op_swap12,
            .SWAP13 => &tailcalls.op_swap13,
            .SWAP14 => &tailcalls.op_swap14,
            .SWAP15 => &tailcalls.op_swap15,
            .SWAP16 => &tailcalls.op_swap16,
            .LOG0 => &tailcalls.op_log0,
            .LOG1 => &tailcalls.op_log1,
            .LOG2 => &tailcalls.op_log2,
            .LOG3 => &tailcalls.op_log3,
            .LOG4 => &tailcalls.op_log4,
            .CREATE => &tailcalls.op_create,
            .CALL => &tailcalls.op_call,
            .CALLCODE => &tailcalls.op_callcode,
            .RETURN => &tailcalls.op_return,
            .DELEGATECALL => &tailcalls.op_delegatecall,
            .CREATE2 => &tailcalls.op_create2,
            .STATICCALL => &tailcalls.op_staticcall,
            .REVERT => &tailcalls.op_revert,
            .INVALID => &tailcalls.op_invalid,
            .SELFDESTRUCT => &tailcalls.op_selfdestruct,
            else => &tailcalls.op_invalid,
        };

        try ops_list.append(fn_ptr);
        pc += 1;
    }

    // Always append STOP at the end for proper termination
    try ops_list.append(&tailcalls.op_stop);

    var ops_slice = try ops_list.toOwnedSlice();

    // Phase 2: fusion pass
    if (ops_slice.len > 1) {
        // Precompute typed pointers for comparisons
        const OP_PUSH = &tailcalls.op_push;
        const OP_JUMP = &tailcalls.op_jump;
        const OP_JUMPI = &tailcalls.op_jumpi;
        const OP_MLOAD = &tailcalls.op_mload;
        const OP_MSTORE = &tailcalls.op_mstore;
        const OP_EQ = &tailcalls.op_eq;
        const OP_LT = &tailcalls.op_lt;
        const OP_GT = &tailcalls.op_gt;
        const OP_AND = &tailcalls.op_and;
        const OP_ADD = &tailcalls.op_add;
        const OP_SUB = &tailcalls.op_sub;
        const OP_MUL = &tailcalls.op_mul;
        const OP_DIV = &tailcalls.op_div;
        const OP_SLOAD = &tailcalls.op_sload;
        const OP_DUP1 = &tailcalls.op_dup1;
        const OP_SWAP1 = &tailcalls.op_swap1;
        const OP_KECCAK256 = &tailcalls.op_keccak256;
        var i: usize = 0;
        while (i < ops_slice.len - 1) : (i += 1) {
            const is_push = ops_slice[i] == OP_PUSH;
            if (!is_push) continue;

            const inst_pc_u16 = analysis.getPc(@intCast(i));
            if (inst_pc_u16 == SimpleAnalysis.MAX_USIZE) continue;
            const inst_pc: usize = inst_pc_u16;
            if (inst_pc >= code.len) continue;

            const opbyte = code[inst_pc];
            if (opbyte < 0x60 or opbyte > 0x7F) continue;

            const next_op = ops_slice[i + 1];
            const push_size: usize = opbyte - 0x5F;

            var fused: ?tailcalls.TailcallFunc = null;

            // JUMP / JUMPI validation
            if (next_op == OP_JUMP or next_op == OP_JUMPI) {
                const value_start = inst_pc + 1;
                var val: usize = 0;
                var j: usize = 0;
                while (j < push_size and value_start + j < code.len) : (j += 1) {
                    val = (val << 8) | code[value_start + j];
                }
                if (val < code.len and code[val] == 0x5B) {
                    // Store the jump destination instruction index in metadata for JUMPI
                    if (next_op == OP_JUMPI) {
                        const dest_inst_idx = analysis.getInstIdx(@intCast(val));
                        if (dest_inst_idx != SimpleAnalysis.MAX_USIZE) {
                            metadata[i] = dest_inst_idx;
                        }
                    }

                    fused = if (next_op == OP_JUMP)
                        &tailcalls.op_push_then_jump
                    else
                        &tailcalls.op_push_then_jumpi;
                }
            }

            // Check if this is a small push (PUSH1-4) that has value stored in metadata
            const is_small_push = push_size <= 4 and @as(usize, inst_pc) + 1 + push_size <= code.len;

            if (fused == null and next_op == OP_MLOAD) {
                fused = if (is_small_push) &tailcalls.op_push_then_mload_small else &tailcalls.op_push_then_mload;
            }
            if (fused == null and next_op == OP_MSTORE) {
                fused = if (is_small_push) &tailcalls.op_push_then_mstore_small else &tailcalls.op_push_then_mstore;
            }
            if (fused == null and next_op == OP_EQ) {
                fused = if (is_small_push) &tailcalls.op_push_then_eq_small else &tailcalls.op_push_then_eq;
            }
            if (fused == null and next_op == OP_LT) {
                fused = if (is_small_push) &tailcalls.op_push_then_lt_small else &tailcalls.op_push_then_lt;
            }
            if (fused == null and next_op == OP_GT) {
                fused = if (is_small_push) &tailcalls.op_push_then_gt_small else &tailcalls.op_push_then_gt;
            }
            if (fused == null and next_op == OP_AND) {
                fused = if (is_small_push) &tailcalls.op_push_then_and_small else &tailcalls.op_push_then_and;
            }
            if (fused == null and next_op == OP_ADD) {
                fused = if (is_small_push) &tailcalls.op_push_then_add_small else &tailcalls.op_push_then_add;
            }
            if (fused == null and next_op == OP_SUB) {
                fused = if (is_small_push) &tailcalls.op_push_then_sub_small else &tailcalls.op_push_then_sub;
            }
            if (fused == null and next_op == OP_MUL) {
                fused = if (is_small_push) &tailcalls.op_push_then_mul_small else &tailcalls.op_push_then_mul;
            }
            if (fused == null and next_op == OP_DIV) {
                fused = if (is_small_push) &tailcalls.op_push_then_div_small else &tailcalls.op_push_then_div;
            }
            if (fused == null and next_op == OP_SLOAD) {
                fused = if (is_small_push) &tailcalls.op_push_then_sload_small else &tailcalls.op_push_then_sload;
            }
            if (fused == null and next_op == OP_DUP1) {
                fused = if (is_small_push) &tailcalls.op_push_then_dup1_small else &tailcalls.op_push_then_dup1;
            }
            if (fused == null and next_op == OP_SWAP1) {
                fused = if (is_small_push) &tailcalls.op_push_then_swap1_small else &tailcalls.op_push_then_swap1;
            }
            if (fused == null and next_op == OP_KECCAK256) {
                fused = if (is_small_push) &tailcalls.op_push_then_keccak_small else &tailcalls.op_push_then_keccak;
            }

            if (fused == null) continue;

            ops_slice[i] = fused.?;
            ops_slice[i + 1] = &tailcalls.op_nop;
            i += 1;
        }
    }

    return .{ .analysis = analysis, .metadata = metadata, .ops = ops_slice };
}

test "prepare_with_buffers" {
    const testing = std.testing;
    
    // Test simple bytecode: PUSH1 0x05 ADD PUSH1 0x10 MUL STOP
    const code = &[_]u8{ 0x60, 0x05, 0x01, 0x60, 0x10, 0x02, 0x00 };
    
    // Allocate buffers based on bytecode size
    var inst_to_pc: [10]u16 = undefined;
    var pc_to_inst: [10]u16 = undefined;
    var metadata: [10]u32 = undefined;
    var ops: [11]tailcalls.TailcallFunc = undefined;
    
    const result = try prepare_with_buffers(
        &inst_to_pc,
        &pc_to_inst,
        &metadata,
        &ops,
        code,
    );
    
    // Verify analysis
    try testing.expectEqual(@as(usize, 5), result.analysis.inst_to_pc.len);
    try testing.expectEqual(@as(usize, 7), result.analysis.pc_to_inst.len);
    
    // Verify metadata for PUSH instructions
    try testing.expectEqual(@as(u32, 0x05), result.metadata[0]); // PUSH1 0x05
    try testing.expectEqual(@as(u32, 0x10), result.metadata[2]); // PUSH1 0x10
    
    // Verify ops include fusion
    // First PUSH should be fused with ADD
    const first_op = @intFromPtr(result.ops[0]);
    const push_add_op = @intFromPtr(&tailcalls.op_push_then_add);
    try testing.expectEqual(push_add_op, first_op);
    
    // Second operation should be NOP (consumed by fusion)
    const second_op = @intFromPtr(result.ops[1]);
    const nop_op = @intFromPtr(&tailcalls.op_nop);
    try testing.expectEqual(nop_op, second_op);
}

test "analysis allocation calculations" {
    const testing = std.testing;
    
    // Test small bytecode
    const small_size = 100;
    const small_analysis = calculate_analysis_allocation(small_size);
    const small_metadata = calculate_metadata_allocation(small_size);
    const small_ops = calculate_ops_allocation(small_size);
    
    try testing.expectEqual(small_size * @sizeOf(u16) * 2, small_analysis.size);
    try testing.expectEqual(small_size * @sizeOf(u32), small_metadata.size);
    try testing.expectEqual((small_size + 1) * @sizeOf(tailcalls.TailcallFunc), small_ops.size);
    
    // Test larger bytecode (16KB like Snailtracer)
    const large_size = 16384;
    const large_analysis = calculate_analysis_allocation(large_size);
    const large_metadata = calculate_metadata_allocation(large_size);
    const large_ops = calculate_ops_allocation(large_size);
    
    try testing.expectEqual(large_size * @sizeOf(u16) * 2, large_analysis.size);
    try testing.expectEqual(large_size * @sizeOf(u32), large_metadata.size);
    try testing.expectEqual((large_size + 1) * @sizeOf(tailcalls.TailcallFunc), large_ops.size);
    
    // Verify alignment and growth properties
    try testing.expectEqual(@alignOf(u16), small_analysis.alignment);
    try testing.expectEqual(@alignOf(u32), small_metadata.alignment);
    try testing.expectEqual(@alignOf(tailcalls.TailcallFunc), small_ops.alignment);
    try testing.expectEqual(false, small_analysis.can_grow);
    try testing.expectEqual(false, small_metadata.can_grow);
    try testing.expectEqual(false, small_ops.can_grow);
}

test "analysis2: PUSH small value bounds check and metadata" {
    const allocator = std.testing.allocator;
    // PUSH1 0xAA; STOP
    const code = &[_]u8{ 0x60, 0xAA, 0x00 };
    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    try std.testing.expectEqual(@as(u16, 0), result.analysis.getInstIdx(0));
    try std.testing.expectEqual(@as(u16, SimpleAnalysis.MAX_USIZE), result.analysis.getInstIdx(1)); // PC 1 is push data, not instruction
    try std.testing.expectEqual(@as(u16, 1), result.analysis.getInstIdx(2));
    // First instruction is PUSH1: metadata should store value 0xAA
    try std.testing.expectEqual(@as(u32, 0xAA), result.metadata[0]);
}

test "analysis2: PUSH0 metadata and length" {
    const allocator = std.testing.allocator;
    // PUSH0; STOP
    const code = &[_]u8{ 0x5F, 0x00 };
    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    // First is PUSH0 -> metadata 0
    try std.testing.expectEqual(@as(u32, 0), result.metadata[0]);
}

test "analysis2: PUSH1-4 metadata fast path optimization" {
    const allocator = std.testing.allocator;
    // PUSH1 0xAA, PUSH2 0x1234, PUSH3 0xABCDEF, PUSH4 0x11223344, STOP
    const code = &[_]u8{
        0x60, 0xAA, // PUSH1 0xAA
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x62, 0xAB, 0xCD, 0xEF, // PUSH3 0xABCDEF
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x00, // STOP
    };

    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);

    // Verify metadata contains precomputed values for PUSH1-4
    try std.testing.expectEqual(@as(u32, 0xAA), result.metadata[0]); // PUSH1
    try std.testing.expectEqual(@as(u32, 0x1234), result.metadata[1]); // PUSH2
    try std.testing.expectEqual(@as(u32, 0xABCDEF), result.metadata[2]); // PUSH3
    try std.testing.expectEqual(@as(u32, 0x11223344), result.metadata[3]); // PUSH4
    try std.testing.expectEqual(@as(u32, 0), result.metadata[4]); // STOP (no metadata)
}
