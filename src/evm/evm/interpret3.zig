const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const StackFrame = @import("../stack_frame.zig").StackFrame;
const opcode_mod = @import("../opcodes/opcode.zig");
const Opcode = opcode_mod.Enum;
const Stack = @import("../stack/stack.zig");
const Memory = @import("../memory/memory.zig");
const execution = @import("../execution/package.zig");
const primitives = @import("primitives");
const tailcalls = @import("tailcalls.zig");
const Log = @import("../log.zig");
const SimpleAnalysis = @import("analysis2.zig").SimpleAnalysis;

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - using StackFrame signature
const TailcallFunc = *const fn (frame: *StackFrame) Error!noreturn;

// TODO we need to be precise about storage at the end
const EXTRA_BUFFER = 8192;

// Main interpret function using StackFrame
pub fn interpret3(frame: *StackFrame, code: []const u8) Error!noreturn {
    if (code.len > std.math.maxInt(u16)) {
        std.log.err("Bytecode length {} exceeds maximum supported size {}", .{ code.len, std.math.maxInt(u16) });
        unreachable; // Hard limit due to u16 PC indexing
    }

    const estimated_size = code.len * 100 + EXTRA_BUFFER;
    const buffer = try std.heap.page_allocator.alloc(u8, estimated_size);
    defer std.heap.page_allocator.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const allocator = fba.allocator();

    const result = try SimpleAnalysis.analyze(allocator, code);
    var analysis = result.analysis;
    defer analysis.deinit(allocator);

    const metadata = result.metadata;
    defer allocator.free(metadata);

    var ops = std.ArrayList(TailcallFunc).init(allocator);
    defer ops.deinit();

    var pc: usize = 0;
    var op_count: usize = 0;
    while (pc < code.len) {
        const byte = code[pc];

        if (opcode_mod.is_push(byte)) {
            const push_size = opcode_mod.get_push_size(byte);
            // Use op_push for all PUSH operations (handles all sizes efficiently)
            try ops.append(&tailcalls.op_push);
            pc += 1 + push_size;
            op_count += 1;
            continue;
        }

        // Check for INVALID opcode
        // Note: INVALID can appear in legitimate code as a trap/revert mechanism
        // Don't stop processing as there may be JUMPDESTs after it
        if (byte == @intFromEnum(Opcode.INVALID)) {
            @branchHint(.cold);
            try ops.append(&tailcalls.op_invalid);
            pc += 1;
            op_count += 1;
            continue;
        }

        // For non-PUSH instructions, check if it's a valid opcode
        if (!opcode_mod.is_valid_opcode(byte)) {
            // Check for Solidity metadata markers (0xa1 or 0xa2 followed by 0x65)
            // Note: 0xa1 and 0xa2 are not valid EVM opcodes but are used by Solidity for metadata
            if ((byte == 0xa1 or byte == 0xa2) and pc + 1 < code.len and code[pc + 1] == 0x65) {
                @branchHint(.likely);
                Log.debug("[interpret3] Found Solidity metadata marker at PC={}, stopping", .{pc});
                break; // Stop processing - we've hit metadata
            }
            // TODO we will want to remove this and fail hard before beta
            Log.warn("[interpret3] WARNING: Unknown opcode 0x{x:0>2} at PC={}, treating as INVALID", .{ byte, pc });
            try ops.append(&tailcalls.op_invalid);
            pc += 1;
            op_count += 1;
            continue;
        }

        const opcode = @as(Opcode, @enumFromInt(byte));

        const fn_ptr = switch (opcode) {
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
            .PREVRANDAO => &tailcalls.op_difficulty, // PREVRANDAO replaced DIFFICULTY
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
            // unreachable because we should have handled push already!
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => unreachable,
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

        try ops.append(fn_ptr);
        pc += 1;
        op_count += 1;
    }

    // Always append a STOP at the end to ensure proper termination
    // This handles both empty code and code that doesn't end with STOP
    try ops.append(&tailcalls.op_stop);

    const ops_slice = try ops.toOwnedSlice();

    // Phase 2: Fusion pass - replace patterns in-place
    // Look for PUSH+opcode sequences and replace them
    if (ops_slice.len > 1) {
        var i: usize = 0;
        while (i < ops_slice.len - 1) : (i += 1) {
            // Check if it's a PUSH instruction
            const is_push = ops_slice[i] == &tailcalls.op_push;

            if (!is_push) continue;

            // Get the PC for this instruction
            const inst_pc = analysis.getPc(@intCast(i));
            if (inst_pc == SimpleAnalysis.MAX_USIZE or inst_pc >= code.len) continue;

            // Check if it's a valid PUSH opcode
            const opcode = code[inst_pc];
            if (opcode < 0x60 or opcode > 0x7F) continue;

            // Get the next operation
            const next_op = ops_slice[i + 1];
            const push_size = opcode - 0x5F;

            // Determine which fusion to apply
            var fused_op: ?*const anyopaque = null;

            // Special handling for jumps - need to validate destination
            if (next_op == &tailcalls.op_jump or next_op == &tailcalls.op_jumpi) {
                // Read the push value to validate jump destination
                const value_start = inst_pc + 1;
                var push_value: usize = 0;
                var j: usize = 0;
                while (j < push_size and value_start + j < code.len) : (j += 1) {
                    push_value = (push_value << 8) | code[value_start + j];
                }

                // Only fuse if destination is a valid JUMPDEST
                if (push_value < code.len and code[push_value] == 0x5B) {
                    fused_op = if (next_op == &tailcalls.op_jump)
                        &tailcalls.op_push_then_jump
                    else
                        &tailcalls.op_push_then_jumpi;
                }
            }
            if (next_op == &tailcalls.op_mload) {
                fused_op = &tailcalls.op_push_then_mload;
            }
            if (next_op == &tailcalls.op_mstore) {
                fused_op = &tailcalls.op_push_then_mstore;
            }
            if (next_op == &tailcalls.op_eq) {
                fused_op = &tailcalls.op_push_then_eq;
            }
            if (next_op == &tailcalls.op_lt) {
                fused_op = &tailcalls.op_push_then_lt;
            }
            if (next_op == &tailcalls.op_gt) {
                fused_op = &tailcalls.op_push_then_gt;
            }
            if (next_op == &tailcalls.op_and) {
                fused_op = &tailcalls.op_push_then_and;
            }
            if (next_op == &tailcalls.op_add) {
                fused_op = &tailcalls.op_push_then_add;
            }
            if (next_op == &tailcalls.op_sub) {
                fused_op = &tailcalls.op_push_then_sub;
            }
            if (next_op == &tailcalls.op_mul) {
                fused_op = &tailcalls.op_push_then_mul;
            }
            if (next_op == &tailcalls.op_div) {
                fused_op = &tailcalls.op_push_then_div;
            }
            if (next_op == &tailcalls.op_sload) {
                fused_op = &tailcalls.op_push_then_sload;
            }
            if (next_op == &tailcalls.op_dup1) {
                fused_op = &tailcalls.op_push_then_dup1;
            }
            if (next_op == &tailcalls.op_swap1) {
                fused_op = &tailcalls.op_push_then_swap1;
            }

            // Skip if no fusion found
            if (fused_op == null) continue;

            // Apply the fusion
            ops_slice[i] = @as(TailcallFunc, @ptrCast(@alignCast(fused_op.?)));
            ops_slice[i + 1] = &tailcalls.op_nop;
            i += 1; // Skip the next instruction since we just fused it
        }
    }

    // Store analysis, metadata, ops, and ip in the StackFrame
    frame.analysis = analysis;
    frame.metadata = metadata;
    frame.ops = @ptrCast(ops_slice.ptr);
    frame.ip = 0;

    if (ops_slice.len == 0) {
        unreachable;
    }

    // Add iteration tracking for safety
    if (comptime SAFE) {
        frame.tailcall_max_iterations = 100_000_000; // Increase for complex contracts like snailtracer
        frame.tailcall_iterations = 0;
    }

    Log.debug("[interpret3] Starting execution with {} ops", .{ops_slice.len});

    // This will recursively tail-call functions until an Error is thrown. Error will be thrown even in success cases
    const first_op = ops_slice[0];
    // Pass the StackFrame with all the data it needs
    return try (@call(.always_tail, first_op, .{frame}));
}