const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const frame_mod = @import("../frame.zig");
const Frame = frame_mod.Frame;
const execution = @import("../execution/package.zig");
const builtin = @import("builtin");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - interpret2 uses a different signature
const TailcallFunc = *const fn (frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn;

// Helper to advance to next instruction
pub inline fn next(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    if (comptime SAFE) {
        const f = @as(*Frame, @ptrCast(@alignCast(frame)));
        f.tailcall_iterations += 1;
        if (f.tailcall_iterations > f.tailcall_max_iterations) {
            return Error.OutOfGas;
        }
    }

    ip.* += 1;

    const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
    return @call(.always_tail, func_ptr, .{ frame, analysis, ops, ip });
}

// Opcode implementations

pub fn op_stop(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = frame;
    _ = analysis;
    _ = ops;
    _ = ip;
    return Error.STOP;
}

pub fn op_add(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_add(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_mul(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_mul(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_sub(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_sub(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_div(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_div(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_sdiv(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_sdiv(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_mod(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_mod(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_smod(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_smod(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_addmod(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_addmod(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_mulmod(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_mulmod(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_exp(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_exp(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_signextend(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_signextend(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_lt(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_lt(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_gt(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_gt(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_slt(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_slt(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_sgt(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_sgt(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_eq(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_eq(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_iszero(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_iszero(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_and(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_and(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_or(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_or(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_xor(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_xor(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_not(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_not(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_byte(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_byte(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_shl(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_shl(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_shr(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_shr(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_sar(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_sar(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_keccak256(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.crypto.op_keccak256(f);
    return next(frame, analysis, ops, ip);
}

// Continue with more opcodes...
pub fn op_address(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_address(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_balance(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_balance(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_origin(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_origin(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_caller(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_caller(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_callvalue(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_callvalue(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_calldataload(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_calldataload(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_calldatasize(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_calldatasize(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_calldatacopy(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_calldatacopy(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_codesize(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_codesize(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_codecopy(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_codecopy(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_gasprice(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_gasprice(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_extcodesize(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_extcodesize(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_extcodecopy(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_extcodecopy(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_returndatasize(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_returndatasize(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_returndatacopy(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_returndatacopy(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_extcodehash(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_extcodehash(f);
    return next(frame, analysis, ops, ip);
}

// Block info opcodes
pub fn op_blockhash(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_blockhash(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_coinbase(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_coinbase(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_timestamp(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_timestamp(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_number(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_number(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_difficulty(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_difficulty(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_gaslimit(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_gaslimit(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_chainid(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_chainid(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_selfbalance(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_selfbalance(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_basefee(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_basefee(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_blobhash(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_blobhash(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_blobbasefee(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_blobbasefee(f);
    return next(frame, analysis, ops, ip);
}

// Stack operations
pub fn op_pop(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_pop(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_push0(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try f.stack.append(0);
    return next(frame, analysis, ops, ip);
}

// Handle PUSH operations with data bytes
pub fn op_push(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));

    // Use cached analysis for O(1) lookup
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const pc = simple_analysis.getPc(ip.*);
    if (pc != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        const bytecode = simple_analysis.bytecode;
        if (pc < bytecode.len) {
            const opcode = bytecode[pc];
            
            // Handle PUSH0
            if (opcode == 0x5F) {
                try f.stack.append(0);
                return next(frame, analysis, ops, ip);
            }
            
            // Handle PUSH1-PUSH32
            if (opcode >= 0x60 and opcode <= 0x7F) {
                const push_size = opcode - 0x5F;
                const value_start = pc + 1;
                
                // Read push value directly from bytecode
                var value: u256 = 0;
                var i: usize = 0;
                while (i < push_size and value_start + i < bytecode.len) : (i += 1) {
                    value = (value << 8) | bytecode[value_start + i];
                }
                
                try f.stack.append(value);
                return next(frame, analysis, ops, ip);
            }
        }
    }

    // If we get here, something is wrong with the analysis
    return Error.InvalidOpcode;
}

// DUP operations
pub fn op_dup1(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup1(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup2(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup2(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup3(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup3(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup4(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup4(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup5(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup5(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup6(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup6(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup7(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup7(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup8(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup8(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup9(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup9(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup10(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup10(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup11(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup11(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup12(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup12(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup13(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup13(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup14(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup14(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup15(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup15(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_dup16(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup16(f);
    return next(frame, analysis, ops, ip);
}

// SWAP operations
pub fn op_swap1(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap1(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap2(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap2(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap3(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap3(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap4(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap4(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap5(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap5(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap6(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap6(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap7(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap7(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap8(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap8(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap9(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap9(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap10(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap10(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap11(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap11(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap12(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap12(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap13(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap13(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap14(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap14(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap15(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap15(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_swap16(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap16(f);
    return next(frame, analysis, ops, ip);
}

// Memory operations
pub fn op_mload(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mload(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_mstore(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mstore(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_mstore8(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mstore8(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_msize(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_msize(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_mcopy(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mcopy(f);
    return next(frame, analysis, ops, ip);
}

// Storage operations
pub fn op_sload(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_sload(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_sstore(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_sstore(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_tload(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_tload(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_tstore(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_tstore(f);
    return next(frame, analysis, ops, ip);
}

// Control flow - TODO: Implement jump logic
pub fn op_jump(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const dest = try f.stack.pop();

    // Use cached analysis for O(1) lookup
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const inst_idx = simple_analysis.getInstIdx(@intCast(dest));
    if (inst_idx != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        // Verify it's a valid JUMPDEST
        const code = f.analysis.code;
        if (dest < code.len and code[@intCast(dest)] == 0x5B) {
            ip.* = inst_idx;
            const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
            return @call(.always_tail, func_ptr, .{ frame, analysis, ops, ip });
        }
    }
    return Error.InvalidJump;
}

pub fn op_jumpi(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const dest = try f.stack.pop();
    const condition = try f.stack.pop();

    if (condition != 0) {
        // Use cached analysis for O(1) lookup
        const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
        const inst_idx = simple_analysis.getInstIdx(@intCast(dest));
        if (inst_idx != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
            // Verify it's a valid JUMPDEST
            const code = f.analysis.code;
            if (dest < code.len and code[@intCast(dest)] == 0x5B) {
                ip.* = inst_idx;
                const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
                return @call(.always_tail, func_ptr, .{ frame, analysis, ops, ip });
            }
        }
        return Error.InvalidJump;
    } else {
        // Condition is false, continue to next instruction
        return next(frame, analysis, ops, ip);
    }
}

pub fn op_pc(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));

    // Use cached analysis for O(1) lookup
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const pc = simple_analysis.getPc(ip.*);
    if (pc != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        try f.stack.append(pc);
        return next(frame, analysis, ops, ip);
    }

    // If we get here, something is wrong with the analysis
    return Error.InvalidOpcode;
}

pub fn op_gas(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.control.op_gas(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_jumpdest(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    // JUMPDEST is a no-op, just continue
    return next(frame, analysis, ops, ip);
}

pub fn op_nop(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    // No-op for replaced instructions in fusion patterns
    return next(frame, analysis, ops, ip);
}

// Fused PUSH+JUMP operation
pub fn op_push_then_jump(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    
    // Get the PC for this instruction to read the push value
    const pc = simple_analysis.getPc(ip.*);
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    const bytecode = simple_analysis.bytecode;
    if (pc >= bytecode.len) {
        return Error.InvalidJump;
    }
    
    const opcode = bytecode[pc];
    if (opcode < 0x60 or opcode > 0x7F) {
        return Error.InvalidJump;
    }
    
    const push_size = opcode - 0x5F;
    const value_start = pc + 1;
    
    // Read the push value (the jump destination)
    var dest: usize = 0;
    var i: usize = 0;
    while (i < push_size and value_start + i < bytecode.len) : (i += 1) {
        dest = (dest << 8) | bytecode[value_start + i];
    }
    
    // Convert PC destination to instruction index
    const dest_inst_idx = simple_analysis.getInstIdx(dest);
    if (dest_inst_idx == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    // In Debug/ReleaseSafe, validate it's a JUMPDEST
    if (comptime SAFE) {
        if (dest >= f.analysis.code.len or f.analysis.code[dest] != 0x5B) {
            return Error.InvalidJump;
        }
    }
    
    // Jump directly to the destination
    ip.* = dest_inst_idx;
    const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
    return @call(.always_tail, func_ptr, .{ frame, analysis, ops, ip });
}

// Fused PUSH+JUMPI operation
pub fn op_push_then_jumpi(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    
    // Get the PC for this instruction to read the push value
    const pc = simple_analysis.getPc(ip.*);
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    const bytecode = simple_analysis.bytecode;
    if (pc >= bytecode.len) {
        return Error.InvalidJump;
    }
    
    const opcode = bytecode[pc];
    if (opcode < 0x60 or opcode > 0x7F) {
        return Error.InvalidJump;
    }
    
    const push_size = opcode - 0x5F;
    const value_start = pc + 1;
    
    // Read the push value (the jump destination)
    var dest: usize = 0;
    var i: usize = 0;
    while (i < push_size and value_start + i < bytecode.len) : (i += 1) {
        dest = (dest << 8) | bytecode[value_start + i];
    }
    
    // Pop the condition value
    const condition = f.stack.pop_unsafe();
    
    // If condition is non-zero, take the jump
    if (condition != 0) {
        // Convert PC destination to instruction index
        const dest_inst_idx = simple_analysis.getInstIdx(dest);
        if (dest_inst_idx == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
            return Error.InvalidJump;
        }
        
        // In Debug/ReleaseSafe, validate it's a JUMPDEST
        if (comptime SAFE) {
            if (dest >= f.analysis.code.len or f.analysis.code[dest] != 0x5B) {
                return Error.InvalidJump;
            }
        }
        
        // Jump to the destination
        ip.* = dest_inst_idx;
        const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
        return @call(.always_tail, func_ptr, .{ frame, analysis, ops, ip });
    } else {
        // Condition is zero, continue to next instruction
        return next(frame, analysis, ops, ip);
    }
}

// Helper function to read push value from bytecode
inline fn readPushValue(analysis: *const @import("analysis2.zig").SimpleAnalysis, ip_val: usize) !u256 {
    const pc = analysis.getPc(ip_val);
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    const bytecode = analysis.bytecode;
    if (pc >= bytecode.len) {
        return Error.InvalidJump;
    }
    
    const opcode = bytecode[pc];
    if (opcode < 0x60 or opcode > 0x7F) {
        return Error.InvalidJump;
    }
    
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
pub fn op_push_then_mload(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const offset = try readPushValue(simple_analysis, ip.*);
    
    // Push offset to stack then call mload
    f.stack.append_unsafe(offset);
    try execution.memory.op_mload(frame);
    return next(frame, analysis, ops, ip);
}

pub fn op_push_then_mstore(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const offset = try readPushValue(simple_analysis, ip.*);
    const value = f.stack.pop_unsafe();
    
    // Push value and offset to stack then call mstore
    f.stack.append_unsafe(value);
    f.stack.append_unsafe(offset);
    try execution.memory.op_mstore(frame);
    return next(frame, analysis, ops, ip);
}

// Comparison operation fusions
pub fn op_push_then_eq(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    const result: u256 = if (other == push_val) 1 else 0;
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

pub fn op_push_then_lt(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    // Note: In EVM, LT pops a then b, and checks if a < b
    // PUSH pushes the value that becomes 'a', so we check push_val < other
    const result: u256 = if (push_val < other) 1 else 0;
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

pub fn op_push_then_gt(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    // Note: In EVM, GT pops a then b, and checks if a > b
    // PUSH pushes the value that becomes 'a', so we check push_val > other
    const result: u256 = if (push_val > other) 1 else 0;
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

// Bitwise operation fusions
pub fn op_push_then_and(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    const result = other & push_val;
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

// Arithmetic operation fusions
pub fn op_push_then_add(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    const result = other +% push_val; // Wrapping add
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

pub fn op_push_then_sub(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    // Note: In EVM, SUB pops a then b, and computes a - b
    // PUSH pushes the value that becomes 'a', so we compute push_val - other
    const result = push_val -% other; // Wrapping sub
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

pub fn op_push_then_mul(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    const result = other *% push_val; // Wrapping mul
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

pub fn op_push_then_div(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const other = try f.stack.peek_unsafe();
    
    // Note: In EVM, DIV pops a then b, and computes a / b
    // PUSH pushes the value that becomes 'a', so we compute push_val / other
    const result = if (other == 0) 0 else push_val / other;
    f.stack.set_top_unsafe(result);
    return next(frame, analysis, ops, ip);
}

// Storage operation fusions
pub fn op_push_then_sload(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const key = try readPushValue(simple_analysis, ip.*);
    
    // Push key to stack then call sload
    f.stack.append_unsafe(key);
    try execution.storage.op_sload(frame);
    return next(frame, analysis, ops, ip);
}

// Stack operation fusions
pub fn op_push_then_dup1(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const value = try readPushValue(simple_analysis, ip.*);
    
    // Push the value twice (PUSH then DUP1 effect)
    f.stack.append_unsafe(value);
    f.stack.append_unsafe(value);
    return next(frame, analysis, ops, ip);
}

pub fn op_push_then_swap1(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const simple_analysis = @as(*const @import("analysis2.zig").SimpleAnalysis, @ptrCast(@alignCast(analysis)));
    const push_val = try readPushValue(simple_analysis, ip.*);
    const top = f.stack.pop_unsafe();
    
    // Push in swapped order
    f.stack.append_unsafe(push_val);
    f.stack.append_unsafe(top);
    return next(frame, analysis, ops, ip);
}

// Log operations
pub fn op_log0(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_0(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_log1(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_1(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_log2(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_2(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_log3(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_3(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_log4(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_4(f);
    return next(frame, analysis, ops, ip);
}

// System operations
pub fn op_create(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_create(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_call(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_call(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_callcode(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_callcode(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_return(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = analysis;
    _ = ops;
    _ = ip;
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.control.op_return(f);
    return Error.RETURN;
}

pub fn op_delegatecall(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_delegatecall(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_create2(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_create2(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_staticcall(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_staticcall(f);
    return next(frame, analysis, ops, ip);
}

pub fn op_revert(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = analysis;
    _ = ops;
    _ = ip;
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.control.op_revert(f);
    return Error.REVERT;
}

pub fn op_invalid(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = frame;
    _ = analysis;
    _ = ops;
    _ = ip;
    return Error.INVALID;
}

pub fn op_selfdestruct(frame: *anyopaque, analysis: *const anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = analysis;
    _ = ops;
    _ = ip;
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_selfdestruct(f);
    return Error.STOP;
}
