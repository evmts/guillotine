const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const StackFrame = @import("../stack_frame.zig").StackFrame;
const execution = @import("../execution/package.zig");
const builtin = @import("builtin");
const PrefetchOptions = @import("std").builtin.PrefetchOptions;
const primitives = @import("primitives");
const U256 = primitives.Uint(256, 4);

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - only takes StackFrame
const TailcallFunc = *const fn (frame: *StackFrame) Error!noreturn;

inline fn prefetchBlockAt(frame: *StackFrame, target_idx: u16) void {
    inline for (0..2) |i| {
        const idx = target_idx + i;
        if (idx < frame.ops.len) {
            @prefetch(frame.ops.ptr + idx, .{ .rw = .read, .locality = 2, .cache = .data });
            @prefetch(frame.metadata.ptr + idx, .{ .rw = .read, .locality = 2, .cache = .data });
            @prefetch(frame.ops[idx], .{ .rw = .read, .locality = 2, .cache = .instruction });
        }
    }
}

pub inline fn next(frame: *StackFrame) Error!noreturn {
    frame.ip += 1;
    const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(frame.ops[frame.ip])));
    return @call(.always_tail, func_ptr, .{frame});
}

// Opcode implementations

pub fn op_stop(frame: *StackFrame) Error!noreturn {
    _ = frame;
    return Error.STOP;
}

pub fn op_add(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_add(frame);
    return next(frame);
}

pub fn op_mul(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_mul(frame);
    return next(frame);
}

pub fn op_sub(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_sub(frame);
    return next(frame);
}

pub fn op_div(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_div(frame);
    return next(frame);
}

pub fn op_sdiv(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_sdiv(frame);
    return next(frame);
}

pub fn op_mod(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_mod(frame);
    return next(frame);
}

pub fn op_smod(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_smod(frame);
    return next(frame);
}

pub fn op_addmod(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_addmod(frame);
    return next(frame);
}

pub fn op_mulmod(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_mulmod(frame);
    return next(frame);
}

pub fn op_exp(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_exp(frame);
    return next(frame);
}

pub fn op_signextend(frame: *StackFrame) Error!noreturn {
    try execution.arithmetic.op_signextend(frame);
    return next(frame);
}

pub fn op_lt(frame: *StackFrame) Error!noreturn {
    try execution.comparison.op_lt(frame);
    return next(frame);
}

pub fn op_gt(frame: *StackFrame) Error!noreturn {
    try execution.comparison.op_gt(frame);
    return next(frame);
}

pub fn op_slt(frame: *StackFrame) Error!noreturn {
    try execution.comparison.op_slt(frame);
    return next(frame);
}

pub fn op_sgt(frame: *StackFrame) Error!noreturn {
    try execution.comparison.op_sgt(frame);
    return next(frame);
}

pub fn op_eq(frame: *StackFrame) Error!noreturn {
    try execution.comparison.op_eq(frame);
    return next(frame);
}

pub fn op_iszero(frame: *StackFrame) Error!noreturn {
    try execution.comparison.op_iszero(frame);
    return next(frame);
}

pub fn op_and(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_and(frame);
    return next(frame);
}

pub fn op_or(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_or(frame);
    return next(frame);
}

pub fn op_xor(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_xor(frame);
    return next(frame);
}

pub fn op_not(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_not(frame);
    return next(frame);
}

pub fn op_byte(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_byte(frame);
    return next(frame);
}

pub fn op_shl(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_shl(frame);
    return next(frame);
}

pub fn op_shr(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_shr(frame);
    return next(frame);
}

pub fn op_sar(frame: *StackFrame) Error!noreturn {
    try execution.bitwise.op_sar(frame);
    return next(frame);
}

pub fn op_keccak256(frame: *StackFrame) Error!noreturn {
    inline for (0..2) |i| {
        @prefetch(frame.ops.ptr + frame.ip + i, .{ .rw = .read, .locality = 3, .cache = .data });
        @prefetch(frame.metadata.ptr + frame.ip + i, .{ .rw = .read, .locality = 3, .cache = .data });
    }

    try execution.crypto.op_keccak256(frame);
    return next(frame);
}

// Continue with more opcodes...
pub fn op_address(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_address(frame);
    return next(frame);
}

pub fn op_balance(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_balance(frame);
    return next(frame);
}

pub fn op_origin(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_origin(frame);
    return next(frame);
}

pub fn op_caller(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_caller(frame);
    return next(frame);
}

pub fn op_callvalue(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_callvalue(frame);
    return next(frame);
}

pub fn op_calldataload(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_calldataload(frame);
    return next(frame);
}

pub fn op_calldatasize(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_calldatasize(frame);
    return next(frame);
}

pub fn op_calldatacopy(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_calldatacopy(frame);
    return next(frame);
}

pub fn op_codesize(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_codesize(frame);
    return next(frame);
}

pub fn op_codecopy(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_codecopy(frame);
    return next(frame);
}

pub fn op_gasprice(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_gasprice(frame);
    return next(frame);
}

pub fn op_extcodesize(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_extcodesize(frame);
    return next(frame);
}

pub fn op_extcodecopy(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_extcodecopy(frame);
    return next(frame);
}

pub fn op_returndatasize(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_returndatasize(frame);
    return next(frame);
}

pub fn op_returndatacopy(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_returndatacopy(frame);
    return next(frame);
}

pub fn op_extcodehash(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_extcodehash(frame);
    return next(frame);
}

// Block info opcodes
pub fn op_blockhash(frame: *StackFrame) Error!noreturn {
    try execution.block.op_blockhash(frame);
    return next(frame);
}

pub fn op_coinbase(frame: *StackFrame) Error!noreturn {
    try execution.block.op_coinbase(frame);
    return next(frame);
}

pub fn op_timestamp(frame: *StackFrame) Error!noreturn {
    try execution.block.op_timestamp(frame);
    return next(frame);
}

pub fn op_number(frame: *StackFrame) Error!noreturn {
    try execution.block.op_number(frame);
    return next(frame);
}

pub fn op_difficulty(frame: *StackFrame) Error!noreturn {
    try execution.block.op_difficulty(frame);
    return next(frame);
}

pub fn op_gaslimit(frame: *StackFrame) Error!noreturn {
    try execution.block.op_gaslimit(frame);
    return next(frame);
}

pub fn op_chainid(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_chainid(frame);
    return next(frame);
}

pub fn op_selfbalance(frame: *StackFrame) Error!noreturn {
    try execution.environment.op_selfbalance(frame);
    return next(frame);
}

pub fn op_basefee(frame: *StackFrame) Error!noreturn {
    try execution.block.op_basefee(frame);
    return next(frame);
}

pub fn op_blobhash(frame: *StackFrame) Error!noreturn {
    try execution.block.op_blobhash(frame);
    return next(frame);
}

pub fn op_blobbasefee(frame: *StackFrame) Error!noreturn {
    try execution.block.op_blobbasefee(frame);
    return next(frame);
}

// Stack operations
pub fn op_pop(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_pop(frame);
    return next(frame);
}

pub fn op_push0(frame: *StackFrame) Error!noreturn {
    frame.stack.append_unsafe(0);
    return next(frame);
}

// Handle PUSH operations with data bytes
pub fn op_push(frame: *StackFrame) Error!noreturn {
    // Get the PC to determine opcode type
    const pc = frame.analysis.getPc(@intCast(frame.ip));
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE or pc >= frame.analysis.bytecode.len) {
        @branchHint(.cold);
        return Error.InvalidOpcode;
    }

    const opcode = frame.analysis.bytecode[pc];

    if (opcode == 0x5F) {
        frame.stack.append_unsafe(0);
        return next(frame);
    }

    // Handle PUSH1-PUSH32
    std.debug.assert(opcode >= 0x60 and opcode <= 0x7F);
    const push_size = opcode - 0x5F;

    // Fast path for PUSH1-4: use precomputed metadata (O(1))
    if (push_size <= 4) {
        const value = frame.metadata[frame.ip];
        frame.stack.append_unsafe(value);
        return next(frame);
    }

    // Slow path for PUSH5-32: read from bytecode
    const value_start = pc + 1;
    var value: u256 = 0;
    var i: usize = 0;
    while (i < push_size and value_start + i < frame.analysis.bytecode.len) : (i += 1) {
        value = (value << 8) | frame.analysis.bytecode[value_start + i];
    }

    frame.stack.append_unsafe(value);
    return next(frame);
}

// DUP operations
pub fn op_dup1(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup1(frame);
    return next(frame);
}

pub fn op_dup2(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup2(frame);
    return next(frame);
}

pub fn op_dup3(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup3(frame);
    return next(frame);
}

pub fn op_dup4(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup4(frame);
    return next(frame);
}

pub fn op_dup5(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup5(frame);
    return next(frame);
}

pub fn op_dup6(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup6(frame);
    return next(frame);
}

pub fn op_dup7(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup7(frame);
    return next(frame);
}

pub fn op_dup8(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup8(frame);
    return next(frame);
}

pub fn op_dup9(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup9(frame);
    return next(frame);
}

pub fn op_dup10(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup10(frame);
    return next(frame);
}

pub fn op_dup11(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup11(frame);
    return next(frame);
}

pub fn op_dup12(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup12(frame);
    return next(frame);
}

pub fn op_dup13(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup13(frame);
    return next(frame);
}

pub fn op_dup14(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup14(frame);
    return next(frame);
}

pub fn op_dup15(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup15(frame);
    return next(frame);
}

pub fn op_dup16(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_dup16(frame);
    return next(frame);
}

// SWAP operations
pub fn op_swap1(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap1(frame);
    return next(frame);
}

pub fn op_swap2(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap2(frame);
    return next(frame);
}

pub fn op_swap3(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap3(frame);
    return next(frame);
}

pub fn op_swap4(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap4(frame);
    return next(frame);
}

pub fn op_swap5(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap5(frame);
    return next(frame);
}

pub fn op_swap6(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap6(frame);
    return next(frame);
}

pub fn op_swap7(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap7(frame);
    return next(frame);
}

pub fn op_swap8(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap8(frame);
    return next(frame);
}

pub fn op_swap9(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap9(frame);
    return next(frame);
}

pub fn op_swap10(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap10(frame);
    return next(frame);
}

pub fn op_swap11(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap11(frame);
    return next(frame);
}

pub fn op_swap12(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap12(frame);
    return next(frame);
}

pub fn op_swap13(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap13(frame);
    return next(frame);
}

pub fn op_swap14(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap14(frame);
    return next(frame);
}

pub fn op_swap15(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap15(frame);
    return next(frame);
}

pub fn op_swap16(frame: *StackFrame) Error!noreturn {
    try execution.stack.op_swap16(frame);
    return next(frame);
}

// Memory operations
pub fn op_mload(frame: *StackFrame) Error!noreturn {
    try execution.memory.op_mload(frame);
    return next(frame);
}

pub fn op_mstore(frame: *StackFrame) Error!noreturn {
    try execution.memory.op_mstore(frame);
    return next(frame);
}

pub fn op_mstore8(frame: *StackFrame) Error!noreturn {
    try execution.memory.op_mstore8(frame);
    return next(frame);
}

pub fn op_msize(frame: *StackFrame) Error!noreturn {
    try execution.memory.op_msize(frame);
    return next(frame);
}

pub fn op_mcopy(frame: *StackFrame) Error!noreturn {
    try execution.memory.op_mcopy(frame);
    return next(frame);
}

// Storage operations
pub fn op_sload(frame: *StackFrame) Error!noreturn {
    try execution.storage.op_sload(frame);
    return next(frame);
}

pub fn op_sstore(frame: *StackFrame) Error!noreturn {
    try execution.storage.op_sstore(frame);
    return next(frame);
}

pub fn op_tload(frame: *StackFrame) Error!noreturn {
    try execution.storage.op_tload(frame);
    return next(frame);
}

pub fn op_tstore(frame: *StackFrame) Error!noreturn {
    try execution.storage.op_tstore(frame);
    return next(frame);
}

// Control flow - TODO: Implement jump logic
pub fn op_jump(frame: *StackFrame) Error!noreturn {
    const dest = frame.stack.pop_unsafe();
    const inst_idx = frame.analysis.getInstIdx(@intCast(dest));

    if (inst_idx == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE or
        dest >= frame.analysis.bytecode.len or
        frame.analysis.bytecode[@intCast(dest)] != 0x5B)
    {
        @branchHint(.cold);
        return Error.InvalidJump;
    }

    prefetchBlockAt(frame, inst_idx);

    frame.ip = inst_idx;
    return next(frame);
}

pub fn op_jumpi(frame: *StackFrame) Error!noreturn {
    const dest = frame.stack.pop_unsafe();
    const condition = frame.stack.pop_unsafe();

    if (condition != 0) {
        // Validate jump
        const inst_idx = frame.analysis.getInstIdx(@intCast(dest));
        if (inst_idx == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE or
            dest >= frame.analysis.bytecode.len or
            frame.analysis.bytecode[@intCast(dest)] != 0x5B)
        {
            @branchHint(.cold);
            return Error.InvalidJump;
        }

        prefetchBlockAt(frame, inst_idx);

        frame.ip = inst_idx;
        return next(frame);
    }

    // Fallthrough case - prefetch sequential instructions
    return next(frame);
}

pub fn op_pc(frame: *StackFrame) Error!noreturn {
    const pc = frame.metadata[frame.ip];
    frame.stack.append_unsafe(pc);
    return next(frame);
}

pub fn op_gas(frame: *StackFrame) Error!noreturn {
    try execution.control.op_gas(frame);
    return next(frame);
}

pub fn op_jumpdest(frame: *StackFrame) Error!noreturn {
    // JUMPDEST is a no-op, just continue
    return next(frame);
}

pub fn op_nop(frame: *StackFrame) Error!noreturn {
    // No-op for replaced instructions in fusion patterns
    return next(frame);
}

// Fused PUSH+JUMP operation
pub fn op_push_then_jump(frame: *StackFrame) Error!noreturn {
    const dest_inst_idx = frame.metadata[frame.ip];

    if (comptime SAFE) {
        if (dest_inst_idx >= frame.analysis.inst_count) return Error.InvalidJump;
        const dest_pc = frame.analysis.getPc(@intCast(dest_inst_idx));
        if (dest_pc >= frame.analysis.bytecode.len or
            frame.analysis.bytecode[dest_pc] != 0x5B)
        {
            return Error.InvalidJump;
        }
    }

    prefetchBlockAt(frame, @intCast(dest_inst_idx));

    frame.ip = dest_inst_idx;
    return next(frame);
}

// Fused PUSH+JUMPI operation
pub fn op_push_then_jumpi(frame: *StackFrame) Error!noreturn {
    const condition = frame.stack.pop_unsafe();

    if (condition != 0) {
        const dest_inst_idx = frame.metadata[frame.ip];

        if (dest_inst_idx >= frame.analysis.inst_count) {
            return Error.InvalidJump;
        }

        if (comptime SAFE) {
            const dest_pc = frame.analysis.getPc(@intCast(dest_inst_idx));
            if (dest_pc >= frame.analysis.bytecode.len or
                frame.analysis.bytecode[dest_pc] != 0x5B)
            {
                return Error.InvalidJump;
            }
        }

        prefetchBlockAt(frame, @intCast(dest_inst_idx));
        frame.ip = dest_inst_idx;
        return next(frame);
    }

    return next(frame);
}

// Helper function to read push value from bytecode
// TODO make a safe version
inline fn readPushValue(frame: *StackFrame) u256 {
    const pc = frame.analysis.getPc(@intCast(frame.ip));
    const bytecode = frame.analysis.bytecode;

    // Add bounds checking for pc - check for invalid PC first
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE or pc >= bytecode.len) {
        return 0; // Return 0 for invalid or out of bounds access
    }

    const opcode = bytecode[pc];
    const push_size = opcode - 0x5F;
    const value_start = pc + 1;
    // Read the push value
    var value: u256 = 0;
    var i: usize = 0;
    while (i < push_size and value_start + i < bytecode.len) : (i += 1) {
        value = (value << 8) | bytecode[value_start + i];
    }
    return value;
}

// Memory operation fusions
pub fn op_push_then_mload(frame: *StackFrame) Error!noreturn {
    const offset = readPushValue(frame);

    // Push offset to stack then call mload
    frame.stack.append_unsafe(offset);
    try execution.memory.op_mload(frame);
    return next(frame);
}

pub fn op_push_then_mstore(frame: *StackFrame) Error!noreturn {
    const offset = readPushValue(frame);
    const value = frame.stack.peek_unsafe();

    // Push value and offset to stack then call mstore
    frame.stack.set_top_unsafe(value);
    frame.stack.append_unsafe(offset);
    try execution.memory.op_mstore(frame);
    return next(frame);
}

// Comparison operation fusions
pub fn op_push_then_eq(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = readPushValue(frame);
    const other = frame.stack.peek_unsafe();

    const result: u256 = if (other == push_val) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_lt(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = readPushValue(frame);
    const other = frame.stack.peek_unsafe();

    // Note: In EVM, LT pops a then b, and checks if a < b
    // PUSH pushes the value that becomes 'a', so we check push_val < other
    const result: u256 = if (push_val < other) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_gt(frame: *StackFrame) Error!noreturn {
    std.debug.assert(frame.stack.size() >= 1);
    const top = readPushValue(frame);
    const second_from_top = frame.stack.peek_unsafe();
    const result: u256 = switch (std.math.order(top, second_from_top)) {
        .gt => 1,
        .eq, .lt => 0,
    };
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Bitwise operation fusions
pub fn op_push_then_and(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = readPushValue(frame);
    const other = frame.stack.peek_unsafe();

    const result = other & push_val;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Arithmetic operation fusions
pub fn op_push_then_add(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = readPushValue(frame);
    const other = frame.stack.peek_unsafe();

    const result = other +% push_val; // Wrapping add
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_sub(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = readPushValue(frame);
    const other = frame.stack.peek_unsafe();

    // Note: In EVM, SUB pops a then b, and computes a - b
    // PUSH pushes the value that becomes 'a', so we compute push_val - other
    const result = push_val -% other; // Wrapping sub
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_mul(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = readPushValue(frame);
    const other = frame.stack.peek_unsafe();

    const result = other *% push_val; // Wrapping mul
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_div(frame: *StackFrame) Error!noreturn {
    const top = readPushValue(frame);
    const second_from_top = frame.stack.peek_unsafe();
    const result = if (second_from_top == 0) blk: {
        break :blk 0;
    } else blk: {
        const result_u256 = U256.from_u256_unsafe(top).wrapping_div(U256.from_u256_unsafe(second_from_top));
        break :blk result_u256.to_u256_unsafe();
    };
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Storage operation fusions
pub fn op_push_then_sload(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const key = readPushValue(frame);

    // Push key to stack then call sload
    frame.stack.append_unsafe(key);
    try execution.storage.op_sload(frame);
    return next(frame);
}

// Stack operation fusions
pub fn op_push_then_dup1(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const value = readPushValue(frame);

    // Push the value twice (PUSH then DUP1 effect)
    frame.stack.append_unsafe(value);
    frame.stack.append_unsafe(value);
    return next(frame);
}

pub fn op_push_then_swap1(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = readPushValue(frame);
    const top = frame.stack.peek_unsafe();

    // Push in swapped order
    frame.stack.set_top_unsafe(push_val);
    frame.stack.append_unsafe(top);
    return next(frame);
}

// === SMALL VALUE FUSION OPERATIONS (PUSH1-4) ===
// These operations read the push value directly from metadata for O(1) access

// Memory operation fusions - small values
pub fn op_push_then_mload_small(frame: *StackFrame) Error!noreturn {
    const offset = frame.metadata[frame.ip];

    // Push offset to stack then call mload
    frame.stack.append_unsafe(offset);
    try execution.memory.op_mload(frame);
    return next(frame);
}

pub fn op_push_then_mstore_small(frame: *StackFrame) Error!noreturn {
    const offset = frame.metadata[frame.ip];
    const value = frame.stack.peek_unsafe();

    // Push value and offset to stack then call mstore
    frame.stack.set_top_unsafe(value);
    frame.stack.append_unsafe(offset);
    try execution.memory.op_mstore(frame);
    return next(frame);
}

// Comparison operation fusions - small values
pub fn op_push_then_eq_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    const result: u256 = if (other == push_val) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_lt_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    // Note: In EVM, LT pops a then b, and checks if a < b
    // PUSH pushes the value that becomes 'a', so we check push_val < other
    const result: u256 = if (push_val < other) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_gt_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    // Note: In EVM, GT pops a then b, and checks if a > b
    // PUSH pushes the value that becomes 'a', so we check push_val > other
    const result: u256 = if (push_val > other) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Bitwise operation fusions - small values
pub fn op_push_then_and_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    const result = other & push_val;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Arithmetic operation fusions - small values
pub fn op_push_then_add_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    const result = other +% push_val; // Wrapping add
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_sub_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    // Note: In EVM, SUB pops a then b, and computes a - b
    // PUSH pushes the value that becomes 'a', so we compute push_val - other
    const result = push_val -% other; // Wrapping sub
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_mul_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    const result = other *% push_val; // Wrapping mul
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_div_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const other = frame.stack.peek_unsafe();

    // Note: In EVM, DIV pops a then b, and computes a / b
    // PUSH pushes the value that becomes 'a', so we compute push_val / other
    const result = if (other == 0) 0 else push_val / other;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Storage operation fusions - small values
pub fn op_push_then_sload_small(frame: *StackFrame) Error!noreturn {
    const key = frame.metadata[frame.ip];

    // Push key to stack then call sload
    frame.stack.append_unsafe(key);
    try execution.storage.op_sload(frame);
    return next(frame);
}

// Stack operation fusions - small values
pub fn op_push_then_dup1_small(frame: *StackFrame) Error!noreturn {
    const value = frame.metadata[frame.ip];

    // Push the value twice (PUSH then DUP1 effect)
    frame.stack.append_unsafe(value);
    frame.stack.append_unsafe(value);
    return next(frame);
}

pub fn op_push_then_swap1_small(frame: *StackFrame) Error!noreturn {
    const push_val = frame.metadata[frame.ip];
    const top = frame.stack.peek_unsafe();

    // Push in swapped order
    frame.stack.set_top_unsafe(push_val);
    frame.stack.append_unsafe(top);
    return next(frame);
}

// Log operations
pub fn op_log0(frame: *StackFrame) Error!noreturn {
    try execution.log.log_0(frame);
    return next(frame);
}

pub fn op_log1(frame: *StackFrame) Error!noreturn {
    try execution.log.log_1(frame);
    return next(frame);
}

pub fn op_log2(frame: *StackFrame) Error!noreturn {
    try execution.log.log_2(frame);
    return next(frame);
}

pub fn op_log3(frame: *StackFrame) Error!noreturn {
    try execution.log.log_3(frame);
    return next(frame);
}

pub fn op_log4(frame: *StackFrame) Error!noreturn {
    try execution.log.log_4(frame);
    return next(frame);
}

// System operations
pub fn op_create(frame: *StackFrame) Error!noreturn {
    try execution.system.op_create(frame);
    return next(frame);
}

pub fn op_call(frame: *StackFrame) Error!noreturn {
    try execution.system.op_call(frame);
    return next(frame);
}

pub fn op_callcode(frame: *StackFrame) Error!noreturn {
    try execution.system.op_callcode(frame);
    return next(frame);
}

pub fn op_return(frame: *StackFrame) Error!noreturn {
    try execution.control.op_return(frame);
    return Error.RETURN;
}

pub fn op_delegatecall(frame: *StackFrame) Error!noreturn {
    try execution.system.op_delegatecall(frame);
    return next(frame);
}

pub fn op_create2(frame: *StackFrame) Error!noreturn {
    try execution.system.op_create2(frame);
    return next(frame);
}

pub fn op_staticcall(frame: *StackFrame) Error!noreturn {
    try execution.system.op_staticcall(frame);
    return next(frame);
}

pub fn op_revert(frame: *StackFrame) Error!noreturn {
    try execution.control.op_revert(frame);
    return Error.REVERT;
}

pub fn op_invalid(frame: *StackFrame) Error!noreturn {
    _ = frame;
    return Error.INVALID;
}

pub fn op_selfdestruct(frame: *StackFrame) Error!noreturn {
    try execution.system.op_selfdestruct(frame);
    return Error.STOP;
}

// Loop condition fusion: DUP1, PUSH, LT, PUSH, JUMPI
// This pattern appears in compiled for/while loops: DUP1 (counter), PUSH limit, LT, PUSH dest, JUMPI
pub fn op_loop_condition(frame: *StackFrame) Error!noreturn {
    // 1. DUP1 logic: Duplicate the loop counter (top of stack)
    const counter = frame.stack.peek_unsafe();
    frame.stack.append_unsafe(counter);

    // 2. PUSH limit: Get the limit value from metadata for the second instruction
    const limit = frame.metadata[frame.ip + 1];
    frame.stack.append_unsafe(limit);

    const b = frame.stack.pop_unsafe(); // limit
    const a = frame.stack.pop_unsafe(); // counter
    const is_less: u256 = if (a < b) 1 else 0;
    frame.stack.append_unsafe(is_less);

    const dest_inst_idx = frame.metadata[frame.ip + 3];

    // This is always a back-edge (loop)
    prefetchBlockAt(frame, @intCast(dest_inst_idx));

    // 5. JUMPI logic: Pop condition and jump if true
    const condition = frame.stack.pop_unsafe();

    if (condition == 0) {
        @branchHint(.unlikely); // Loop exit uncommon
        frame.ip += 4; // Skip 4 more since next() will add 1
        return next(frame);
    }

    if (comptime SAFE) {
        if (dest_inst_idx >= frame.analysis.inst_count) {
            return Error.InvalidJump;
        }
        const dest_pc = frame.analysis.getPc(@intCast(dest_inst_idx));
        if (dest_pc >= frame.analysis.bytecode.len or frame.analysis.bytecode[dest_pc] != 0x5B) {
            return Error.InvalidJump;
        }
    }

    frame.ip = dest_inst_idx;
    return next(frame);
}
