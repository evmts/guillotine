const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const frame_mod = @import("../frame.zig");
const Frame = frame_mod.Frame;
const execution = @import("../execution/package.zig");
const builtin = @import("builtin");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - interpret2 uses a different signature
const TailcallFunc = *const fn (frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn;

// Helper to advance to next instruction
pub inline fn next(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    if (comptime SAFE) {
        const f = @as(*Frame, @ptrCast(@alignCast(frame)));
        f.tailcall_iterations += 1;
        if (f.tailcall_iterations > f.tailcall_max_iterations) {
            return Error.OutOfGas;
        }
    }

    ip.* += 1;

    const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
    return @call(.always_tail, func_ptr, .{ frame, ops, ip });
}

// Opcode implementations

pub fn op_stop(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.STOP;
}

pub fn op_add(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_add(f);
    return next(frame, ops, ip);
}

pub fn op_mul(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_mul(f);
    return next(frame, ops, ip);
}

pub fn op_sub(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_sub(f);
    return next(frame, ops, ip);
}

pub fn op_div(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_div(f);
    return next(frame, ops, ip);
}

pub fn op_sdiv(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_sdiv(f);
    return next(frame, ops, ip);
}

pub fn op_mod(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_mod(f);
    return next(frame, ops, ip);
}

pub fn op_smod(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_smod(f);
    return next(frame, ops, ip);
}

pub fn op_addmod(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_addmod(f);
    return next(frame, ops, ip);
}

pub fn op_mulmod(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_mulmod(f);
    return next(frame, ops, ip);
}

pub fn op_exp(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_exp(f);
    return next(frame, ops, ip);
}

pub fn op_signextend(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.arithmetic.op_signextend(f);
    return next(frame, ops, ip);
}

pub fn op_lt(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_lt(f);
    return next(frame, ops, ip);
}

pub fn op_gt(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_gt(f);
    return next(frame, ops, ip);
}

pub fn op_slt(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_slt(f);
    return next(frame, ops, ip);
}

pub fn op_sgt(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_sgt(f);
    return next(frame, ops, ip);
}

pub fn op_eq(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_eq(f);
    return next(frame, ops, ip);
}

pub fn op_iszero(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.comparison.op_iszero(f);
    return next(frame, ops, ip);
}

pub fn op_and(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_and(f);
    return next(frame, ops, ip);
}

pub fn op_or(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_or(f);
    return next(frame, ops, ip);
}

pub fn op_xor(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_xor(f);
    return next(frame, ops, ip);
}

pub fn op_not(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_not(f);
    return next(frame, ops, ip);
}

pub fn op_byte(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_byte(f);
    return next(frame, ops, ip);
}

pub fn op_shl(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_shl(f);
    return next(frame, ops, ip);
}

pub fn op_shr(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_shr(f);
    return next(frame, ops, ip);
}

pub fn op_sar(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.bitwise.op_sar(f);
    return next(frame, ops, ip);
}

pub fn op_keccak256(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.crypto.op_keccak256(f);
    return next(frame, ops, ip);
}

// Continue with more opcodes...
pub fn op_address(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_address(f);
    return next(frame, ops, ip);
}

pub fn op_balance(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_balance(f);
    return next(frame, ops, ip);
}

pub fn op_origin(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_origin(f);
    return next(frame, ops, ip);
}

pub fn op_caller(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_caller(f);
    return next(frame, ops, ip);
}

pub fn op_callvalue(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_callvalue(f);
    return next(frame, ops, ip);
}

pub fn op_calldataload(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_calldataload(f);
    return next(frame, ops, ip);
}

pub fn op_calldatasize(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_calldatasize(f);
    return next(frame, ops, ip);
}

pub fn op_calldatacopy(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_calldatacopy(f);
    return next(frame, ops, ip);
}

pub fn op_codesize(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_codesize(f);
    return next(frame, ops, ip);
}

pub fn op_codecopy(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_codecopy(f);
    return next(frame, ops, ip);
}

pub fn op_gasprice(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_gasprice(f);
    return next(frame, ops, ip);
}

pub fn op_extcodesize(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_extcodesize(f);
    return next(frame, ops, ip);
}

pub fn op_extcodecopy(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_extcodecopy(f);
    return next(frame, ops, ip);
}

pub fn op_returndatasize(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_returndatasize(f);
    return next(frame, ops, ip);
}

pub fn op_returndatacopy(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_returndatacopy(f);
    return next(frame, ops, ip);
}

pub fn op_extcodehash(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_extcodehash(f);
    return next(frame, ops, ip);
}

// Block info opcodes
pub fn op_blockhash(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_blockhash(f);
    return next(frame, ops, ip);
}

pub fn op_coinbase(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_coinbase(f);
    return next(frame, ops, ip);
}

pub fn op_timestamp(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_timestamp(f);
    return next(frame, ops, ip);
}

pub fn op_number(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_number(f);
    return next(frame, ops, ip);
}

pub fn op_difficulty(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_difficulty(f);
    return next(frame, ops, ip);
}

pub fn op_gaslimit(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_gaslimit(f);
    return next(frame, ops, ip);
}

pub fn op_chainid(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_chainid(f);
    return next(frame, ops, ip);
}

pub fn op_selfbalance(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.environment.op_selfbalance(f);
    return next(frame, ops, ip);
}

pub fn op_basefee(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_basefee(f);
    return next(frame, ops, ip);
}

pub fn op_blobhash(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_blobhash(f);
    return next(frame, ops, ip);
}

pub fn op_blobbasefee(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.block.op_blobbasefee(f);
    return next(frame, ops, ip);
}

// Stack operations
pub fn op_pop(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_pop(f);
    return next(frame, ops, ip);
}

pub fn op_push0(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try f.stack.append(0);
    return next(frame, ops, ip);
}

// Handle PUSH operations with data bytes
pub fn op_push(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));

    // Use cached analysis for O(1) lookup
    const analysis = f.tailcall_analysis;
    const pc = analysis.getPc(ip.*);
    if (pc != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        const bytecode = analysis.bytecode;
        if (pc < bytecode.len) {
            const opcode = bytecode[pc];
            
            // Handle PUSH0
            if (opcode == 0x5F) {
                try f.stack.append(0);
                return next(frame, ops, ip);
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
                return next(frame, ops, ip);
            }
        }
    }

    // If we get here, something is wrong with the analysis
    return Error.InvalidOpcode;
}

// DUP operations
pub fn op_dup1(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup1(f);
    return next(frame, ops, ip);
}

pub fn op_dup2(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup2(f);
    return next(frame, ops, ip);
}

pub fn op_dup3(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup3(f);
    return next(frame, ops, ip);
}

pub fn op_dup4(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup4(f);
    return next(frame, ops, ip);
}

pub fn op_dup5(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup5(f);
    return next(frame, ops, ip);
}

pub fn op_dup6(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup6(f);
    return next(frame, ops, ip);
}

pub fn op_dup7(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup7(f);
    return next(frame, ops, ip);
}

pub fn op_dup8(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup8(f);
    return next(frame, ops, ip);
}

pub fn op_dup9(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup9(f);
    return next(frame, ops, ip);
}

pub fn op_dup10(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup10(f);
    return next(frame, ops, ip);
}

pub fn op_dup11(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup11(f);
    return next(frame, ops, ip);
}

pub fn op_dup12(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup12(f);
    return next(frame, ops, ip);
}

pub fn op_dup13(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup13(f);
    return next(frame, ops, ip);
}

pub fn op_dup14(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup14(f);
    return next(frame, ops, ip);
}

pub fn op_dup15(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup15(f);
    return next(frame, ops, ip);
}

pub fn op_dup16(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_dup16(f);
    return next(frame, ops, ip);
}

// SWAP operations
pub fn op_swap1(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap1(f);
    return next(frame, ops, ip);
}

pub fn op_swap2(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap2(f);
    return next(frame, ops, ip);
}

pub fn op_swap3(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap3(f);
    return next(frame, ops, ip);
}

pub fn op_swap4(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap4(f);
    return next(frame, ops, ip);
}

pub fn op_swap5(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap5(f);
    return next(frame, ops, ip);
}

pub fn op_swap6(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap6(f);
    return next(frame, ops, ip);
}

pub fn op_swap7(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap7(f);
    return next(frame, ops, ip);
}

pub fn op_swap8(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap8(f);
    return next(frame, ops, ip);
}

pub fn op_swap9(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap9(f);
    return next(frame, ops, ip);
}

pub fn op_swap10(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap10(f);
    return next(frame, ops, ip);
}

pub fn op_swap11(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap11(f);
    return next(frame, ops, ip);
}

pub fn op_swap12(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap12(f);
    return next(frame, ops, ip);
}

pub fn op_swap13(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap13(f);
    return next(frame, ops, ip);
}

pub fn op_swap14(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap14(f);
    return next(frame, ops, ip);
}

pub fn op_swap15(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap15(f);
    return next(frame, ops, ip);
}

pub fn op_swap16(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.stack.op_swap16(f);
    return next(frame, ops, ip);
}

// Memory operations
pub fn op_mload(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mload(f);
    return next(frame, ops, ip);
}

pub fn op_mstore(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mstore(f);
    return next(frame, ops, ip);
}

pub fn op_mstore8(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mstore8(f);
    return next(frame, ops, ip);
}

pub fn op_msize(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_msize(f);
    return next(frame, ops, ip);
}

pub fn op_mcopy(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.memory.op_mcopy(f);
    return next(frame, ops, ip);
}

// Storage operations
pub fn op_sload(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_sload(f);
    return next(frame, ops, ip);
}

pub fn op_sstore(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_sstore(f);
    return next(frame, ops, ip);
}

pub fn op_tload(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_tload(f);
    return next(frame, ops, ip);
}

pub fn op_tstore(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.storage.op_tstore(f);
    return next(frame, ops, ip);
}

// Control flow - TODO: Implement jump logic
pub fn op_jump(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const dest = try f.stack.pop();

    // Use cached analysis for O(1) lookup
    const analysis = f.tailcall_analysis;
    const inst_idx = analysis.getInstIdx(@intCast(dest));
    if (inst_idx != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        // Verify it's a valid JUMPDEST
        const code = f.analysis.code;
        if (dest < code.len and code[@intCast(dest)] == 0x5B) {
            ip.* = inst_idx;
            const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
            return @call(.always_tail, func_ptr, .{ frame, ops, ip });
        }
    }
    return Error.InvalidJump;
}

pub fn op_jumpi(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    const dest = try f.stack.pop();
    const condition = try f.stack.pop();

    if (condition != 0) {
        // Use cached analysis for O(1) lookup
        const analysis = f.tailcall_analysis;
        const inst_idx = analysis.getInstIdx(@intCast(dest));
        if (inst_idx != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
            // Verify it's a valid JUMPDEST
            const code = f.analysis.code;
            if (dest < code.len and code[@intCast(dest)] == 0x5B) {
                ip.* = inst_idx;
                const func_ptr = @as(TailcallFunc, @ptrCast(@alignCast(ops[ip.*])));
                return @call(.always_tail, func_ptr, .{ frame, ops, ip });
            }
        }
        return Error.InvalidJump;
    } else {
        // Condition is false, continue to next instruction
        return next(frame, ops, ip);
    }
}

pub fn op_pc(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));

    // Use cached analysis for O(1) lookup
    const analysis = f.tailcall_analysis;
    const pc = analysis.getPc(ip.*);
    if (pc != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        try f.stack.append(pc);
        return next(frame, ops, ip);
    }

    // If we get here, something is wrong with the analysis
    return Error.InvalidOpcode;
}

pub fn op_gas(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.control.op_gas(f);
    return next(frame, ops, ip);
}

pub fn op_jumpdest(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    // JUMPDEST is a no-op, just continue
    return next(frame, ops, ip);
}

// Log operations
pub fn op_log0(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_0(f);
    return next(frame, ops, ip);
}

pub fn op_log1(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_1(f);
    return next(frame, ops, ip);
}

pub fn op_log2(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_2(f);
    return next(frame, ops, ip);
}

pub fn op_log3(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_3(f);
    return next(frame, ops, ip);
}

pub fn op_log4(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.log.log_4(f);
    return next(frame, ops, ip);
}

// System operations
pub fn op_create(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_create(f);
    return next(frame, ops, ip);
}

pub fn op_call(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_call(f);
    return next(frame, ops, ip);
}

pub fn op_callcode(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_callcode(f);
    return next(frame, ops, ip);
}

pub fn op_return(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = ops;
    _ = ip;
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.control.op_return(f);
    return Error.RETURN;
}

pub fn op_delegatecall(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_delegatecall(f);
    return next(frame, ops, ip);
}

pub fn op_create2(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_create2(f);
    return next(frame, ops, ip);
}

pub fn op_staticcall(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_staticcall(f);
    return next(frame, ops, ip);
}

pub fn op_revert(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = ops;
    _ = ip;
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.control.op_revert(f);
    return Error.REVERT;
}

pub fn op_invalid(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.INVALID;
}

pub fn op_selfdestruct(frame: *anyopaque, ops: [*]const *const anyopaque, ip: *usize) Error!noreturn {
    _ = ops;
    _ = ip;
    const f = @as(*Frame, @ptrCast(@alignCast(frame)));
    try execution.system.op_selfdestruct(f);
    return Error.STOP;
}
