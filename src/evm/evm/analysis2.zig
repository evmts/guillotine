const std = @import("std");
const Opcode = @import("../opcodes/opcode.zig").Enum;
const opcode_mod = @import("../opcodes/opcode.zig");
const tailcalls = @import("tailcalls.zig");
const Log = @import("../log.zig");

/// Simple analysis result for tailcall dispatch with precomputed mappings
pub const SimpleAnalysis = struct {
    /// Mapping from instruction index to PC value
    inst_to_pc: []u16,
    /// Mapping from PC to instruction index (MAX_USIZE if not an instruction start)
    pc_to_inst: []u16,
    /// Reference to the original bytecode for reading push values
    bytecode: []const u8,
    /// Total number of instructions
    inst_count: u16,

    pub const MAX_USIZE: u16 = std.math.maxInt(u16);

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
                .inst_count = inst_idx,
            },
            .metadata = try metadata_list.toOwnedSlice(),
        };
    }
};

/// Build the tailcall ops array and return together with analysis and metadata
/// This encapsulates opcode decoding and fusion logic for PUSH+X patterns
pub fn prepare(allocator: std.mem.Allocator, code: []const u8) !struct {
    analysis: SimpleAnalysis,
    metadata: []u32,
    ops: []*const anyopaque,
} {
    if (code.len > std.math.maxInt(u16)) return error.OutOfMemory;

    // Phase 1: basic analysis + metadata
    const res = try SimpleAnalysis.analyze(allocator, code);
    const analysis = res.analysis;
    const metadata = res.metadata;

    // Phase 1.5: decode to ops array
    var ops_list = std.ArrayList(*const anyopaque).init(allocator);
    errdefer ops_list.deinit();

    var pc: usize = 0;
    while (pc < code.len) {
        const byte = code[pc];

        if (opcode_mod.is_push(byte)) {
            const push_size = opcode_mod.get_push_size(byte);
            try ops_list.append(@ptrCast(&tailcalls.op_push));
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
            try ops_list.append(@ptrCast(&tailcalls.op_invalid));
            pc += 1;
            continue;
        }

        const opcode = @as(Opcode, @enumFromInt(byte));
        const fn_ptr: *const anyopaque = switch (opcode) {
            .STOP => @ptrCast(&tailcalls.op_stop),
            .ADD => @ptrCast(&tailcalls.op_add),
            .MUL => @ptrCast(&tailcalls.op_mul),
            .SUB => @ptrCast(&tailcalls.op_sub),
            .DIV => @ptrCast(&tailcalls.op_div),
            .SDIV => @ptrCast(&tailcalls.op_sdiv),
            .MOD => @ptrCast(&tailcalls.op_mod),
            .SMOD => @ptrCast(&tailcalls.op_smod),
            .ADDMOD => @ptrCast(&tailcalls.op_addmod),
            .MULMOD => @ptrCast(&tailcalls.op_mulmod),
            .EXP => @ptrCast(&tailcalls.op_exp),
            .SIGNEXTEND => @ptrCast(&tailcalls.op_signextend),
            .LT => @ptrCast(&tailcalls.op_lt),
            .GT => @ptrCast(&tailcalls.op_gt),
            .SLT => @ptrCast(&tailcalls.op_slt),
            .SGT => @ptrCast(&tailcalls.op_sgt),
            .EQ => @ptrCast(&tailcalls.op_eq),
            .ISZERO => @ptrCast(&tailcalls.op_iszero),
            .AND => @ptrCast(&tailcalls.op_and),
            .OR => @ptrCast(&tailcalls.op_or),
            .XOR => @ptrCast(&tailcalls.op_xor),
            .NOT => @ptrCast(&tailcalls.op_not),
            .BYTE => @ptrCast(&tailcalls.op_byte),
            .SHL => @ptrCast(&tailcalls.op_shl),
            .SHR => @ptrCast(&tailcalls.op_shr),
            .SAR => @ptrCast(&tailcalls.op_sar),
            .KECCAK256 => @ptrCast(&tailcalls.op_keccak256),
            .ADDRESS => @ptrCast(&tailcalls.op_address),
            .BALANCE => @ptrCast(&tailcalls.op_balance),
            .ORIGIN => @ptrCast(&tailcalls.op_origin),
            .CALLER => @ptrCast(&tailcalls.op_caller),
            .CALLVALUE => @ptrCast(&tailcalls.op_callvalue),
            .CALLDATALOAD => @ptrCast(&tailcalls.op_calldataload),
            .CALLDATASIZE => @ptrCast(&tailcalls.op_calldatasize),
            .CALLDATACOPY => @ptrCast(&tailcalls.op_calldatacopy),
            .CODESIZE => @ptrCast(&tailcalls.op_codesize),
            .CODECOPY => @ptrCast(&tailcalls.op_codecopy),
            .GASPRICE => @ptrCast(&tailcalls.op_gasprice),
            .EXTCODESIZE => @ptrCast(&tailcalls.op_extcodesize),
            .EXTCODECOPY => @ptrCast(&tailcalls.op_extcodecopy),
            .RETURNDATASIZE => @ptrCast(&tailcalls.op_returndatasize),
            .RETURNDATACOPY => @ptrCast(&tailcalls.op_returndatacopy),
            .EXTCODEHASH => @ptrCast(&tailcalls.op_extcodehash),
            .BLOCKHASH => @ptrCast(&tailcalls.op_blockhash),
            .COINBASE => @ptrCast(&tailcalls.op_coinbase),
            .TIMESTAMP => @ptrCast(&tailcalls.op_timestamp),
            .NUMBER => @ptrCast(&tailcalls.op_number),
            .PREVRANDAO => @ptrCast(&tailcalls.op_difficulty),
            .GASLIMIT => @ptrCast(&tailcalls.op_gaslimit),
            .CHAINID => @ptrCast(&tailcalls.op_chainid),
            .SELFBALANCE => @ptrCast(&tailcalls.op_selfbalance),
            .BASEFEE => @ptrCast(&tailcalls.op_basefee),
            .BLOBHASH => @ptrCast(&tailcalls.op_blobhash),
            .BLOBBASEFEE => @ptrCast(&tailcalls.op_blobbasefee),
            .POP => @ptrCast(&tailcalls.op_pop),
            .MLOAD => @ptrCast(&tailcalls.op_mload),
            .MSTORE => @ptrCast(&tailcalls.op_mstore),
            .MSTORE8 => @ptrCast(&tailcalls.op_mstore8),
            .SLOAD => @ptrCast(&tailcalls.op_sload),
            .SSTORE => @ptrCast(&tailcalls.op_sstore),
            .JUMP => @ptrCast(&tailcalls.op_jump),
            .JUMPI => @ptrCast(&tailcalls.op_jumpi),
            .PC => @ptrCast(&tailcalls.op_pc),
            .MSIZE => @ptrCast(&tailcalls.op_msize),
            .GAS => @ptrCast(&tailcalls.op_gas),
            .JUMPDEST => @ptrCast(&tailcalls.op_jumpdest),
            .TLOAD => @ptrCast(&tailcalls.op_tload),
            .TSTORE => @ptrCast(&tailcalls.op_tstore),
            .MCOPY => @ptrCast(&tailcalls.op_mcopy),
            .PUSH0 => @ptrCast(&tailcalls.op_push0),
            .DUP1 => @ptrCast(&tailcalls.op_dup1),
            .DUP2 => @ptrCast(&tailcalls.op_dup2),
            .DUP3 => @ptrCast(&tailcalls.op_dup3),
            .DUP4 => @ptrCast(&tailcalls.op_dup4),
            .DUP5 => @ptrCast(&tailcalls.op_dup5),
            .DUP6 => @ptrCast(&tailcalls.op_dup6),
            .DUP7 => @ptrCast(&tailcalls.op_dup7),
            .DUP8 => @ptrCast(&tailcalls.op_dup8),
            .DUP9 => @ptrCast(&tailcalls.op_dup9),
            .DUP10 => @ptrCast(&tailcalls.op_dup10),
            .DUP11 => @ptrCast(&tailcalls.op_dup11),
            .DUP12 => @ptrCast(&tailcalls.op_dup12),
            .DUP13 => @ptrCast(&tailcalls.op_dup13),
            .DUP14 => @ptrCast(&tailcalls.op_dup14),
            .DUP15 => @ptrCast(&tailcalls.op_dup15),
            .DUP16 => @ptrCast(&tailcalls.op_dup16),
            .SWAP1 => @ptrCast(&tailcalls.op_swap1),
            .SWAP2 => @ptrCast(&tailcalls.op_swap2),
            .SWAP3 => @ptrCast(&tailcalls.op_swap3),
            .SWAP4 => @ptrCast(&tailcalls.op_swap4),
            .SWAP5 => @ptrCast(&tailcalls.op_swap5),
            .SWAP6 => @ptrCast(&tailcalls.op_swap6),
            .SWAP7 => @ptrCast(&tailcalls.op_swap7),
            .SWAP8 => @ptrCast(&tailcalls.op_swap8),
            .SWAP9 => @ptrCast(&tailcalls.op_swap9),
            .SWAP10 => @ptrCast(&tailcalls.op_swap10),
            .SWAP11 => @ptrCast(&tailcalls.op_swap11),
            .SWAP12 => @ptrCast(&tailcalls.op_swap12),
            .SWAP13 => @ptrCast(&tailcalls.op_swap13),
            .SWAP14 => @ptrCast(&tailcalls.op_swap14),
            .SWAP15 => @ptrCast(&tailcalls.op_swap15),
            .SWAP16 => @ptrCast(&tailcalls.op_swap16),
            .LOG0 => @ptrCast(&tailcalls.op_log0),
            .LOG1 => @ptrCast(&tailcalls.op_log1),
            .LOG2 => @ptrCast(&tailcalls.op_log2),
            .LOG3 => @ptrCast(&tailcalls.op_log3),
            .LOG4 => @ptrCast(&tailcalls.op_log4),
            .CREATE => @ptrCast(&tailcalls.op_create),
            .CALL => @ptrCast(&tailcalls.op_call),
            .CALLCODE => @ptrCast(&tailcalls.op_callcode),
            .RETURN => @ptrCast(&tailcalls.op_return),
            .DELEGATECALL => @ptrCast(&tailcalls.op_delegatecall),
            .CREATE2 => @ptrCast(&tailcalls.op_create2),
            .STATICCALL => @ptrCast(&tailcalls.op_staticcall),
            .REVERT => @ptrCast(&tailcalls.op_revert),
            .INVALID => @ptrCast(&tailcalls.op_invalid),
            .SELFDESTRUCT => @ptrCast(&tailcalls.op_selfdestruct),
            else => @ptrCast(&tailcalls.op_invalid),
        };

        try ops_list.append(fn_ptr);
        pc += 1;
    }

    // Always append STOP at the end for proper termination
    try ops_list.append(@ptrCast(&tailcalls.op_stop));

    var ops_slice = try ops_list.toOwnedSlice();

    // Phase 2: fusion pass
    if (ops_slice.len > 1) {
        // Precompute typed pointers for comparisons
        const OP_PUSH: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_push));
        const OP_JUMP: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_jump));
        const OP_JUMPI: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_jumpi));
        const OP_MLOAD: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_mload));
        const OP_MSTORE: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_mstore));
        const OP_EQ: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_eq));
        const OP_LT: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_lt));
        const OP_GT: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_gt));
        const OP_AND: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_and));
        const OP_ADD: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_add));
        const OP_SUB: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_sub));
        const OP_MUL: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_mul));
        const OP_DIV: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_div));
        const OP_SLOAD: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_sload));
        const OP_DUP1: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_dup1));
        const OP_SWAP1: *const anyopaque = @as(*const anyopaque, @ptrCast(&tailcalls.op_swap1));
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

            var fused: ?*const anyopaque = null;

            // JUMP / JUMPI validation
            if (next_op == OP_JUMP or next_op == OP_JUMPI) {
                const value_start = inst_pc + 1;
                var val: usize = 0;
                var j: usize = 0;
                while (j < push_size and value_start + j < code.len) : (j += 1) {
                    val = (val << 8) | code[value_start + j];
                }
                if (val < code.len and code[val] == 0x5B) {
                    fused = if (next_op == OP_JUMP)
                        @ptrCast(&tailcalls.op_push_then_jump)
                    else
                        @ptrCast(&tailcalls.op_push_then_jumpi);
                }
            }

            if (fused == null and next_op == OP_MLOAD) fused = @ptrCast(&tailcalls.op_push_then_mload);
            if (fused == null and next_op == OP_MSTORE) fused = @ptrCast(&tailcalls.op_push_then_mstore);
            if (fused == null and next_op == OP_EQ) fused = @ptrCast(&tailcalls.op_push_then_eq);
            if (fused == null and next_op == OP_LT) fused = @ptrCast(&tailcalls.op_push_then_lt);
            if (fused == null and next_op == OP_GT) fused = @ptrCast(&tailcalls.op_push_then_gt);
            if (fused == null and next_op == OP_AND) fused = @ptrCast(&tailcalls.op_push_then_and);
            if (fused == null and next_op == OP_ADD) fused = @ptrCast(&tailcalls.op_push_then_add);
            if (fused == null and next_op == OP_SUB) fused = @ptrCast(&tailcalls.op_push_then_sub);
            if (fused == null and next_op == OP_MUL) fused = @ptrCast(&tailcalls.op_push_then_mul);
            if (fused == null and next_op == OP_DIV) fused = @ptrCast(&tailcalls.op_push_then_div);
            if (fused == null and next_op == OP_SLOAD) fused = @ptrCast(&tailcalls.op_push_then_sload);
            if (fused == null and next_op == OP_DUP1) fused = @ptrCast(&tailcalls.op_push_then_dup1);
            if (fused == null and next_op == OP_SWAP1) fused = @ptrCast(&tailcalls.op_push_then_swap1);

            if (fused == null) continue;

            ops_slice[i] = fused.?;
            ops_slice[i + 1] = @ptrCast(&tailcalls.op_nop);
            i += 1;
        }
    }

    return .{ .analysis = analysis, .metadata = metadata, .ops = ops_slice };
}

test "analysis2: PUSH small value bounds check and metadata" {
    const allocator = std.testing.allocator;
    // PUSH1 0xAA; STOP
    const code = &[_]u8{ 0x60, 0xAA, 0x00 };
    var result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    try std.testing.expectEqual(@as(u16, 0), result.analysis.getInstIdx(0));
    try std.testing.expectEqual(@as(u16, 1), result.analysis.getInstIdx(1));
    try std.testing.expectEqual(@as(u16, 2), result.analysis.getInstIdx(2));
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
    // Two instructions
    try std.testing.expectEqual(@as(u16, 2), result.analysis.inst_count);
    // First is PUSH0 -> metadata 0
    try std.testing.expectEqual(@as(u32, 0), result.metadata[0]);
}
