const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const TailcallExecutionFunc = @import("../tailcall_execution_func.zig").TailcallExecutionFunc;
const Frame = @import("../frame.zig").Frame;
const execution = @import("../execution/package.zig");
const builtin = @import("builtin");
const primitives = @import("primitives");
const instruction = @import("../instruction.zig");
const JumpPcInstruction = instruction.JumpPcInstruction;
const ConditionalJumpPcInstruction = instruction.ConditionalJumpPcInstruction;

const Error = ExecutionError.Error;

// Helper functions

/// Advance to next instruction with tailcall
inline fn next(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    frame.tailcall_index += 1;
    const next_fn = frame.tailcall_ops[frame.tailcall_index];
    return @call(.always_tail, next_fn, .{frame_ptr});
}

/// Get current instruction index
inline fn getInstIdx(frame: *Frame) usize {
    return frame.tailcall_index;
}

/// Convert bytecode slice to u256
fn bytesToU256(bytes: []const u8) u256 {
    std.debug.assert(bytes.len <= 32);

    if (bytes.len == 0) return 0;

    if (bytes.len == 32) {
        return std.mem.readInt(u256, bytes[0..32], .big);
    }

    var padded: [32]u8 = [_]u8{0} ** 32;
    @memcpy(padded[32 - bytes.len ..], bytes);
    return std.mem.readInt(u256, &padded, .big);
}

// Synthetic control flow wrappers

pub fn block_info_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const inst_idx = getInstIdx(frame);
    const inst_id = frame.analysis.instructions[inst_idx].id;
    const params = frame.analysis.getInstructionParams(.block_info, inst_id);

    // Gas check
    if (frame.gas_remaining < params.gas_cost) {
        frame.gas_remaining = 0;
        return error.OutOfGas;
    }
    frame.gas_remaining -= params.gas_cost;

    // Stack validation
    const stack_size: u16 = @intCast(frame.stack.size());
    if (stack_size < params.stack_req) {
        return error.StackUnderflow;
    }
    if (stack_size + params.stack_max_growth > 1024) {
        return error.StackOverflow;
    }

    return next(frame_ptr);
}

pub fn noop_wrap(frame_ptr: *anyopaque) Error!void {
    return next(frame_ptr);
}

pub fn word_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const inst_idx = getInstIdx(frame);
    const inst_id = frame.analysis.instructions[inst_idx].id;
    const params = frame.analysis.getInstructionParams(.word, inst_id);

    const value = bytesToU256(params.word_bytes);
    frame.stack.append_unsafe(value);

    return next(frame_ptr);
}

pub fn pc_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const inst_idx = getInstIdx(frame);
    const inst_id = frame.analysis.instructions[inst_idx].id;
    const params = frame.analysis.getInstructionParams(.pc, inst_id);

    frame.stack.append_unsafe(params.pc_value);

    return next(frame_ptr);
}

pub fn jump_pc_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const inst_idx = getInstIdx(frame);
    const inst_id = frame.analysis.instructions[inst_idx].id;
    const params = frame.analysis.getInstructionParams(.jump_pc, inst_id);

    // Update instruction index to jump target
    frame.tailcall_index = params.jump_idx;
    const next_fn = frame.tailcall_ops[frame.tailcall_index];
    return @call(.always_tail, next_fn, .{frame_ptr});
}

pub fn jump_unresolved_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const dest = frame.stack.pop_unsafe();

    if (!frame.valid_jumpdest(dest)) {
        return error.InvalidJump;
    }

    const dest_usize: usize = @intCast(dest);
    const idx = frame.analysis.pc_to_block_start[dest_usize];
    if (idx == std.math.maxInt(u16) or idx >= frame.analysis.instructions.len) {
        return error.InvalidJump;
    }

    frame.tailcall_index = idx;
    const next_fn = frame.tailcall_ops[frame.tailcall_index];
    return @call(.always_tail, next_fn, .{frame_ptr});
}

pub fn conditional_jump_pc_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const inst_idx = getInstIdx(frame);
    const inst_id = frame.analysis.instructions[inst_idx].id;
    const params = frame.analysis.getInstructionParams(.conditional_jump_pc, inst_id);

    const condition = frame.stack.pop_unsafe();
    if (condition != 0) {
        frame.tailcall_index = params.jump_idx;
    } else {
        frame.tailcall_index += 1;
    }
    const next_fn = frame.tailcall_ops[frame.tailcall_index];
    return @call(.always_tail, next_fn, .{frame_ptr});
}

pub fn conditional_jump_unresolved_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const dest = frame.stack.pop_unsafe();
    const condition = frame.stack.pop_unsafe();

    if (condition != 0) {
        if (!frame.valid_jumpdest(dest)) {
            return error.InvalidJump;
        }

        const dest_usize: usize = @intCast(dest);
        const idx = frame.analysis.pc_to_block_start[dest_usize];
        if (idx == std.math.maxInt(u16) or idx >= frame.analysis.instructions.len) {
            return error.InvalidJump;
        }

        frame.tailcall_index = idx;
    } else {
        frame.tailcall_index += 1;
    }

    const next_fn = frame.tailcall_ops[frame.tailcall_index];
    return @call(.always_tail, next_fn, .{frame_ptr});
}

pub fn conditional_jump_invalid_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    const condition = frame.stack.pop_unsafe();
    if (condition != 0) {
        return error.InvalidJump;
    }
    return next(frame_ptr);
}

// Halting opcodes

pub fn op_stop_wrap(frame_ptr: *anyopaque) Error!void {
    _ = frame_ptr;
    return error.STOP;
}

pub fn op_return_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.control.op_return(frame);
    return error.RETURN;
}

pub fn op_revert_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.control.op_revert(frame);
    return error.REVERT;
}

pub fn op_invalid_wrap(frame_ptr: *anyopaque) Error!void {
    _ = frame_ptr;
    return error.INVALID;
}

// Arithmetic operations

pub fn op_add_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_add(frame);
    return next(frame_ptr);
}

pub fn op_mul_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_mul(frame);
    return next(frame_ptr);
}

pub fn op_sub_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_sub(frame);
    return next(frame_ptr);
}

pub fn op_div_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_div(frame);
    return next(frame_ptr);
}

pub fn op_sdiv_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_sdiv(frame);
    return next(frame_ptr);
}

pub fn op_mod_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_mod(frame);
    return next(frame_ptr);
}

pub fn op_smod_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_smod(frame);
    return next(frame_ptr);
}

pub fn op_addmod_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_addmod(frame);
    return next(frame_ptr);
}

pub fn op_mulmod_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_mulmod(frame);
    return next(frame_ptr);
}

pub fn op_exp_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_exp(frame);
    return next(frame_ptr);
}

pub fn op_signextend_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.arithmetic.op_signextend(frame);
    return next(frame_ptr);
}

// Comparison operations

pub fn op_lt_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.comparison.op_lt(frame);
    return next(frame_ptr);
}

pub fn op_gt_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.comparison.op_gt(frame);
    return next(frame_ptr);
}

pub fn op_slt_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.comparison.op_slt(frame);
    return next(frame_ptr);
}

pub fn op_sgt_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.comparison.op_sgt(frame);
    return next(frame_ptr);
}

pub fn op_eq_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.comparison.op_eq(frame);
    return next(frame_ptr);
}

pub fn op_iszero_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.comparison.op_iszero(frame);
    return next(frame_ptr);
}

// Bitwise operations

pub fn op_and_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_and(frame);
    return next(frame_ptr);
}

pub fn op_or_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_or(frame);
    return next(frame_ptr);
}

pub fn op_xor_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_xor(frame);
    return next(frame_ptr);
}

pub fn op_not_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_not(frame);
    return next(frame_ptr);
}

pub fn op_byte_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_byte(frame);
    return next(frame_ptr);
}

pub fn op_shl_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_shl(frame);
    return next(frame_ptr);
}

pub fn op_shr_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_shr(frame);
    return next(frame_ptr);
}

pub fn op_sar_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.bitwise.op_sar(frame);
    return next(frame_ptr);
}

// Stack operations

pub fn op_pop_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_pop(frame);
    return next(frame_ptr);
}

pub fn op_push0_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    // PUSH0 pushes 0 onto the stack
    try frame.stack.push(0);
    return next(frame_ptr);
}

// DUP operations
pub fn op_dup1_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup1(frame);
    return next(frame_ptr);
}

pub fn op_dup2_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup2(frame);
    return next(frame_ptr);
}

pub fn op_dup3_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup3(frame);
    return next(frame_ptr);
}

pub fn op_dup4_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup4(frame);
    return next(frame_ptr);
}

pub fn op_dup5_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup5(frame);
    return next(frame_ptr);
}

pub fn op_dup6_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup6(frame);
    return next(frame_ptr);
}

pub fn op_dup7_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup7(frame);
    return next(frame_ptr);
}

pub fn op_dup8_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup8(frame);
    return next(frame_ptr);
}

pub fn op_dup9_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup9(frame);
    return next(frame_ptr);
}

pub fn op_dup10_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup10(frame);
    return next(frame_ptr);
}

pub fn op_dup11_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup11(frame);
    return next(frame_ptr);
}

pub fn op_dup12_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup12(frame);
    return next(frame_ptr);
}

pub fn op_dup13_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup13(frame);
    return next(frame_ptr);
}

pub fn op_dup14_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup14(frame);
    return next(frame_ptr);
}

pub fn op_dup15_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup15(frame);
    return next(frame_ptr);
}

pub fn op_dup16_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_dup16(frame);
    return next(frame_ptr);
}

// SWAP operations
pub fn op_swap1_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap1(frame);
    return next(frame_ptr);
}

pub fn op_swap2_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap2(frame);
    return next(frame_ptr);
}

pub fn op_swap3_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap3(frame);
    return next(frame_ptr);
}

pub fn op_swap4_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap4(frame);
    return next(frame_ptr);
}

pub fn op_swap5_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap5(frame);
    return next(frame_ptr);
}

pub fn op_swap6_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap6(frame);
    return next(frame_ptr);
}

pub fn op_swap7_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap7(frame);
    return next(frame_ptr);
}

pub fn op_swap8_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap8(frame);
    return next(frame_ptr);
}

pub fn op_swap9_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap9(frame);
    return next(frame_ptr);
}

pub fn op_swap10_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap10(frame);
    return next(frame_ptr);
}

pub fn op_swap11_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap11(frame);
    return next(frame_ptr);
}

pub fn op_swap12_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap12(frame);
    return next(frame_ptr);
}

pub fn op_swap13_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap13(frame);
    return next(frame_ptr);
}

pub fn op_swap14_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap14(frame);
    return next(frame_ptr);
}

pub fn op_swap15_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap15(frame);
    return next(frame_ptr);
}

pub fn op_swap16_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.stack.op_swap16(frame);
    return next(frame_ptr);
}

// Memory operations

pub fn op_mload_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.memory.op_mload(frame);
    return next(frame_ptr);
}

pub fn op_mstore_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.memory.op_mstore(frame);
    return next(frame_ptr);
}

pub fn op_mstore8_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.memory.op_mstore8(frame);
    return next(frame_ptr);
}

pub fn op_msize_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.memory.op_msize(frame);
    return next(frame_ptr);
}

pub fn op_mcopy_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.memory.op_mcopy(frame);
    return next(frame_ptr);
}

// Control flow

pub fn op_jump_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));

    const dest = try frame.stack.pop();
    if (!frame.valid_jumpdest(dest)) {
        return error.InvalidJump;
    }

    const dest_usize: usize = @intCast(dest);
    const idx = frame.analysis.pc_to_block_start[dest_usize];
    if (idx == std.math.maxInt(u16) or idx >= frame.analysis.instructions.len) {
        return error.InvalidJump;
    }

    frame.tailcall_index = idx;
    const next_fn = frame.tailcall_ops[frame.tailcall_index];
    return @call(.always_tail, next_fn, .{frame_ptr});
}

pub fn op_jumpi_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));

    const dest = try frame.stack.pop();
    const condition = try frame.stack.pop();

    if (condition != 0) {
        if (!frame.valid_jumpdest(dest)) {
            return error.InvalidJump;
        }

        const dest_usize: usize = @intCast(dest);
        const idx = frame.analysis.pc_to_block_start[dest_usize];
        if (idx == std.math.maxInt(u16) or idx >= frame.analysis.instructions.len) {
            return error.InvalidJump;
        }

        frame.tailcall_index = idx;
    } else {
        frame.tailcall_index += 1;
    }

    const next_fn = frame.tailcall_ops[frame.tailcall_index];
    return @call(.always_tail, next_fn, .{frame_ptr});
}

pub fn op_pc_wrap(frame_ptr: *anyopaque) Error!void {
    // PC is handled by pc_wrap for the synthetic instruction
    return pc_wrap(frame_ptr);
}

pub fn op_jumpdest_wrap(frame_ptr: *anyopaque) Error!void {
    // JUMPDEST is a no-op, just continue
    return next(frame_ptr);
}

pub fn op_gas_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    // GAS pushes remaining gas onto stack
    try frame.stack.push(frame.gas_remaining);
    return next(frame_ptr);
}

// Environment opcodes

pub fn op_address_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_address(frame);
    return next(frame_ptr);
}

pub fn op_balance_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_balance(frame);
    return next(frame_ptr);
}

pub fn op_origin_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_origin(frame);
    return next(frame_ptr);
}

pub fn op_caller_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_caller(frame);
    return next(frame_ptr);
}

pub fn op_callvalue_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_callvalue(frame);
    return next(frame_ptr);
}

pub fn op_calldataload_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_calldataload(frame);
    return next(frame_ptr);
}

pub fn op_calldatasize_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_calldatasize(frame);
    return next(frame_ptr);
}

pub fn op_calldatacopy_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_calldatacopy(frame);
    return next(frame_ptr);
}

pub fn op_codesize_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_codesize(frame);
    return next(frame_ptr);
}

pub fn op_codecopy_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_codecopy(frame);
    return next(frame_ptr);
}

pub fn op_gasprice_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_gasprice(frame);
    return next(frame_ptr);
}

pub fn op_extcodesize_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_extcodesize(frame);
    return next(frame_ptr);
}

pub fn op_extcodecopy_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_extcodecopy(frame);
    return next(frame_ptr);
}

pub fn op_returndatasize_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_returndatasize(frame);
    return next(frame_ptr);
}

pub fn op_returndatacopy_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_returndatacopy(frame);
    return next(frame_ptr);
}

pub fn op_extcodehash_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_extcodehash(frame);
    return next(frame_ptr);
}

// Block info opcodes

pub fn op_blockhash_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_blockhash(frame);
    return next(frame_ptr);
}

pub fn op_coinbase_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_coinbase(frame);
    return next(frame_ptr);
}

pub fn op_timestamp_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_timestamp(frame);
    return next(frame_ptr);
}

pub fn op_number_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_number(frame);
    return next(frame_ptr);
}

pub fn op_difficulty_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_difficulty(frame);
    return next(frame_ptr);
}

pub fn op_gaslimit_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_gaslimit(frame);
    return next(frame_ptr);
}

pub fn op_chainid_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_chainid(frame);
    return next(frame_ptr);
}

pub fn op_selfbalance_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.environment.op_selfbalance(frame);
    return next(frame_ptr);
}

pub fn op_basefee_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_basefee(frame);
    return next(frame_ptr);
}

pub fn op_blobhash_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_blobhash(frame);
    return next(frame_ptr);
}

pub fn op_blobbasefee_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.block.op_blobbasefee(frame);
    return next(frame_ptr);
}

// Storage opcodes

pub fn op_sload_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.storage.op_sload(frame);
    return next(frame_ptr);
}

pub fn op_sstore_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.storage.op_sstore(frame);
    return next(frame_ptr);
}

pub fn op_tload_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.storage.op_tload(frame);
    return next(frame_ptr);
}

pub fn op_tstore_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.storage.op_tstore(frame);
    return next(frame_ptr);
}

// Crypto opcodes

pub fn op_keccak256_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.crypto.op_keccak256(frame);
    return next(frame_ptr);
}

// Log opcodes

pub fn op_log0_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.log.log_0(frame);
    return next(frame_ptr);
}

pub fn op_log1_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.log.log_1(frame);
    return next(frame_ptr);
}

pub fn op_log2_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.log.log_2(frame);
    return next(frame_ptr);
}

pub fn op_log3_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.log.log_3(frame);
    return next(frame_ptr);
}

pub fn op_log4_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.log.log_4(frame);
    return next(frame_ptr);
}

// System operations

pub fn op_create_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.system.op_create(frame);
    return next(frame_ptr);
}

pub fn op_call_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.system.op_call(frame);
    return next(frame_ptr);
}

pub fn op_callcode_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.system.op_callcode(frame);
    return next(frame_ptr);
}

pub fn op_delegatecall_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.system.op_delegatecall(frame);
    return next(frame_ptr);
}

pub fn op_create2_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.system.op_create2(frame);
    return next(frame_ptr);
}

pub fn op_staticcall_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.system.op_staticcall(frame);
    return next(frame_ptr);
}

pub fn op_selfdestruct_wrap(frame_ptr: *anyopaque) Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(frame_ptr)));
    try execution.system.op_selfdestruct(frame);
    return error.STOP;
}

// Placeholder for unimplemented opcodes
pub fn unimplemented_wrap(frame_ptr: *anyopaque) Error!void {
    _ = frame_ptr;
    return error.OpcodeNotImplemented;
}

// PUSH operations (handled by word_wrap, but need entries for completeness)
pub fn op_push1_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push2_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push3_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push4_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push5_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push6_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push7_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push8_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push9_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push10_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push11_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push12_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push13_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push14_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push15_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push16_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push17_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push18_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push19_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push20_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push21_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push22_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push23_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push24_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push25_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push26_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push27_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push28_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push29_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push30_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push31_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
pub fn op_push32_wrap(frame_ptr: *anyopaque) Error!void {
    return word_wrap(frame_ptr);
}
