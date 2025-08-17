const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const frame_mod = @import("../frame.zig");
const Frame = frame_mod.Frame;
const execution = @import("../execution/package.zig");

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - use the same type as Frame
const TailcallFunc = frame_mod.TailcallFunc;

// Helper to advance to next instruction
pub inline fn next(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    ip.* += 1;
    return @call(.always_tail, ops[ip.*], .{ frame, ops, ip });
}

// Opcode implementations

pub fn op_stop(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.STOP;
}

pub fn op_add(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_add(frame);
    return next(frame, ops, ip);
}

pub fn op_mul(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_mul(frame);
    return next(frame, ops, ip);
}

pub fn op_sub(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_sub(frame);
    return next(frame, ops, ip);
}

pub fn op_div(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_div(frame);
    return next(frame, ops, ip);
}

pub fn op_sdiv(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_sdiv(frame);
    return next(frame, ops, ip);
}

pub fn op_mod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_mod(frame);
    return next(frame, ops, ip);
}

pub fn op_smod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_smod(frame);
    return next(frame, ops, ip);
}

pub fn op_addmod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_addmod(frame);
    return next(frame, ops, ip);
}

pub fn op_mulmod(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_mulmod(frame);
    return next(frame, ops, ip);
}

pub fn op_exp(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_exp(frame);
    return next(frame, ops, ip);
}

pub fn op_signextend(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_signextend(frame);
    return next(frame, ops, ip);
}

pub fn op_lt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_lt(frame);
    return next(frame, ops, ip);
}

pub fn op_gt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_gt(frame);
    return next(frame, ops, ip);
}

pub fn op_slt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_slt(frame);
    return next(frame, ops, ip);
}

pub fn op_sgt(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_sgt(frame);
    return next(frame, ops, ip);
}

pub fn op_eq(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_eq(frame);
    return next(frame, ops, ip);
}

pub fn op_iszero(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.arithmetic.op_iszero(frame);
    return next(frame, ops, ip);
}

pub fn op_and(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_and(frame);
    return next(frame, ops, ip);
}

pub fn op_or(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_or(frame);
    return next(frame, ops, ip);
}

pub fn op_xor(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_xor(frame);
    return next(frame, ops, ip);
}

pub fn op_not(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_not(frame);
    return next(frame, ops, ip);
}

pub fn op_byte(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_byte(frame);
    return next(frame, ops, ip);
}

pub fn op_shl(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_shl(frame);
    return next(frame, ops, ip);
}

pub fn op_shr(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_shr(frame);
    return next(frame, ops, ip);
}

pub fn op_sar(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.bitwise.op_sar(frame);
    return next(frame, ops, ip);
}

pub fn op_keccak256(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.crypto.op_keccak256(frame);
    return next(frame, ops, ip);
}

// Continue with more opcodes...
pub fn op_address(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_address(frame);
    return next(frame, ops, ip);
}

pub fn op_balance(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_balance(frame);
    return next(frame, ops, ip);
}

pub fn op_origin(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_origin(frame);
    return next(frame, ops, ip);
}

pub fn op_caller(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_caller(frame);
    return next(frame, ops, ip);
}

pub fn op_callvalue(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_callvalue(frame);
    return next(frame, ops, ip);
}

pub fn op_calldataload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_calldataload(frame);
    return next(frame, ops, ip);
}

pub fn op_calldatasize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_calldatasize(frame);
    return next(frame, ops, ip);
}

pub fn op_calldatacopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_calldatacopy(frame);
    return next(frame, ops, ip);
}

pub fn op_codesize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_codesize(frame);
    return next(frame, ops, ip);
}

pub fn op_codecopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_codecopy(frame);
    return next(frame, ops, ip);
}

pub fn op_gasprice(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_gasprice(frame);
    return next(frame, ops, ip);
}

pub fn op_extcodesize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_extcodesize(frame);
    return next(frame, ops, ip);
}

pub fn op_extcodecopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_extcodecopy(frame);
    return next(frame, ops, ip);
}

pub fn op_returndatasize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_returndatasize(frame);
    return next(frame, ops, ip);
}

pub fn op_returndatacopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_returndatacopy(frame);
    return next(frame, ops, ip);
}

pub fn op_extcodehash(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.environment.op_extcodehash(frame);
    return next(frame, ops, ip);
}

// Block info opcodes
pub fn op_blockhash(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_blockhash(frame);
    return next(frame, ops, ip);
}

pub fn op_coinbase(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_coinbase(frame);
    return next(frame, ops, ip);
}

pub fn op_timestamp(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_timestamp(frame);
    return next(frame, ops, ip);
}

pub fn op_number(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_number(frame);
    return next(frame, ops, ip);
}

pub fn op_difficulty(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_difficulty(frame);
    return next(frame, ops, ip);
}

pub fn op_gaslimit(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_gaslimit(frame);
    return next(frame, ops, ip);
}

pub fn op_chainid(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_chainid(frame);
    return next(frame, ops, ip);
}

pub fn op_selfbalance(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_selfbalance(frame);
    return next(frame, ops, ip);
}

pub fn op_basefee(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_basefee(frame);
    return next(frame, ops, ip);
}

pub fn op_blobhash(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_blobhash(frame);
    return next(frame, ops, ip);
}

pub fn op_blobbasefee(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.block.op_blobbasefee(frame);
    return next(frame, ops, ip);
}

// Stack operations
pub fn op_pop(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_pop(frame);
    return next(frame, ops, ip);
}

pub fn op_push0(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_push0(frame);
    return next(frame, ops, ip);
}

// Handle PUSH operations with data bytes
pub fn op_push(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    // Get the bytecode from the frame analysis
    const code = frame.analysis.code;

    // Calculate actual PC from instruction index
    var pc: usize = 0;
    var inst_idx: usize = 0;
    while (inst_idx < ip.*) : (inst_idx += 1) {
        const byte = code[pc];
        if (byte >= 0x60 and byte <= 0x7F) {
            pc += 1 + (byte - 0x5F);
        } else if (byte == 0x5F) {
            pc += 1;
        } else {
            pc += 1;
        }
    }

    // Now pc points to the PUSH opcode
    const push_opcode = code[pc];
    const push_size = push_opcode - 0x5F;
    pc += 1; // Move to data bytes

    // Read the push value
    var value: u256 = 0;
    var i: usize = 0;
    while (i < push_size and pc + i < code.len) : (i += 1) {
        value = (value << 8) | code[pc + i];
    }

    try frame.stack.push(value);

    // Skip over the data bytes in instruction stream
    ip.* += push_size;
    return next(frame, ops, ip);
}

// DUP operations
pub fn op_dup1(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup1(frame);
    return next(frame, ops, ip);
}

pub fn op_dup2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup2(frame);
    return next(frame, ops, ip);
}

pub fn op_dup3(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup3(frame);
    return next(frame, ops, ip);
}

pub fn op_dup4(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup4(frame);
    return next(frame, ops, ip);
}

pub fn op_dup5(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup5(frame);
    return next(frame, ops, ip);
}

pub fn op_dup6(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup6(frame);
    return next(frame, ops, ip);
}

pub fn op_dup7(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup7(frame);
    return next(frame, ops, ip);
}

pub fn op_dup8(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup8(frame);
    return next(frame, ops, ip);
}

pub fn op_dup9(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup9(frame);
    return next(frame, ops, ip);
}

pub fn op_dup10(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup10(frame);
    return next(frame, ops, ip);
}

pub fn op_dup11(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup11(frame);
    return next(frame, ops, ip);
}

pub fn op_dup12(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup12(frame);
    return next(frame, ops, ip);
}

pub fn op_dup13(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup13(frame);
    return next(frame, ops, ip);
}

pub fn op_dup14(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup14(frame);
    return next(frame, ops, ip);
}

pub fn op_dup15(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup15(frame);
    return next(frame, ops, ip);
}

pub fn op_dup16(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_dup16(frame);
    return next(frame, ops, ip);
}

// SWAP operations
pub fn op_swap1(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap1(frame);
    return next(frame, ops, ip);
}

pub fn op_swap2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap2(frame);
    return next(frame, ops, ip);
}

pub fn op_swap3(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap3(frame);
    return next(frame, ops, ip);
}

pub fn op_swap4(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap4(frame);
    return next(frame, ops, ip);
}

pub fn op_swap5(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap5(frame);
    return next(frame, ops, ip);
}

pub fn op_swap6(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap6(frame);
    return next(frame, ops, ip);
}

pub fn op_swap7(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap7(frame);
    return next(frame, ops, ip);
}

pub fn op_swap8(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap8(frame);
    return next(frame, ops, ip);
}

pub fn op_swap9(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap9(frame);
    return next(frame, ops, ip);
}

pub fn op_swap10(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap10(frame);
    return next(frame, ops, ip);
}

pub fn op_swap11(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap11(frame);
    return next(frame, ops, ip);
}

pub fn op_swap12(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap12(frame);
    return next(frame, ops, ip);
}

pub fn op_swap13(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap13(frame);
    return next(frame, ops, ip);
}

pub fn op_swap14(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap14(frame);
    return next(frame, ops, ip);
}

pub fn op_swap15(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap15(frame);
    return next(frame, ops, ip);
}

pub fn op_swap16(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_swap16(frame);
    return next(frame, ops, ip);
}

// Memory operations
pub fn op_mload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.memory.op_mload(frame);
    return next(frame, ops, ip);
}

pub fn op_mstore(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.memory.op_mstore(frame);
    return next(frame, ops, ip);
}

pub fn op_mstore8(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.memory.op_mstore8(frame);
    return next(frame, ops, ip);
}

pub fn op_msize(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.memory.op_msize(frame);
    return next(frame, ops, ip);
}

pub fn op_mcopy(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.memory.op_mcopy(frame);
    return next(frame, ops, ip);
}

// Storage operations
pub fn op_sload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.storage.op_sload(frame);
    return next(frame, ops, ip);
}

pub fn op_sstore(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.storage.op_sstore(frame);
    return next(frame, ops, ip);
}

pub fn op_tload(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.storage.op_tload(frame);
    return next(frame, ops, ip);
}

pub fn op_tstore(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.storage.op_tstore(frame);
    return next(frame, ops, ip);
}

// Control flow - TODO: Implement jump logic
pub fn op_jump(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    const dest = try frame.stack.pop();

    // Find the instruction index for this PC
    const code = frame.analysis.code;
    var pc: usize = 0;
    var inst_idx: usize = 0;

    while (pc < dest and pc < code.len) {
        const byte = code[pc];
        if (byte >= 0x60 and byte <= 0x7F) {
            pc += 1 + (byte - 0x5F);
            inst_idx += 1 + (byte - 0x5F); // Account for data bytes in ops array
        } else if (byte == 0x5F) {
            pc += 1;
            inst_idx += 1;
        } else {
            pc += 1;
            inst_idx += 1;
        }
    }

    // Verify it's a valid JUMPDEST
    if (pc != dest or pc >= code.len or code[pc] != 0x5B) {
        return Error.InvalidJump;
    }

    // Jump to the destination
    ip.* = inst_idx;
    return @call(.always_tail, ops[ip.*], .{ frame, ops, ip });
}

pub fn op_jumpi(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    const dest = try frame.stack.pop();
    const condition = try frame.stack.pop();

    if (condition != 0) {
        // Find the instruction index for this PC
        const code = frame.analysis.code;
        var pc: usize = 0;
        var inst_idx: usize = 0;

        while (pc < dest and pc < code.len) {
            const byte = code[pc];
            if (byte >= 0x60 and byte <= 0x7F) {
                pc += 1 + (byte - 0x5F);
                inst_idx += 1 + (byte - 0x5F); // Account for data bytes in ops array
            } else if (byte == 0x5F) {
                pc += 1;
                inst_idx += 1;
            } else {
                pc += 1;
                inst_idx += 1;
            }
        }

        // Verify it's a valid JUMPDEST
        if (pc != dest or pc >= code.len or code[pc] != 0x5B) {
            return Error.InvalidJump;
        }

        // Jump to the destination
        ip.* = inst_idx;
        return @call(.always_tail, ops[ip.*], .{ frame, ops, ip });
    } else {
        // Condition is false, continue to next instruction
        return next(frame, ops, ip);
    }
}

pub fn op_pc(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_pc(frame);
    return next(frame, ops, ip);
}

pub fn op_gas(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.stack.op_gas(frame);
    return next(frame, ops, ip);
}

pub fn op_jumpdest(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    // JUMPDEST is a no-op, just continue
    return next(frame, ops, ip);
}

// Log operations
pub fn op_log0(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.log.op_log0(frame);
    return next(frame, ops, ip);
}

pub fn op_log1(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.log.op_log1(frame);
    return next(frame, ops, ip);
}

pub fn op_log2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.log.op_log2(frame);
    return next(frame, ops, ip);
}

pub fn op_log3(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.log.op_log3(frame);
    return next(frame, ops, ip);
}

pub fn op_log4(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.log.op_log4(frame);
    return next(frame, ops, ip);
}

// System operations
pub fn op_create(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.system.op_create(frame);
    return next(frame, ops, ip);
}

pub fn op_call(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.system.op_call(frame);
    return next(frame, ops, ip);
}

pub fn op_callcode(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.system.op_callcode(frame);
    return next(frame, ops, ip);
}

pub fn op_return(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    _ = ops;
    _ = ip;
    try execution.system.op_return(frame);
    return Error.RETURN;
}

pub fn op_delegatecall(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.system.op_delegatecall(frame);
    return next(frame, ops, ip);
}

pub fn op_create2(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.system.op_create2(frame);
    return next(frame, ops, ip);
}

pub fn op_staticcall(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    try execution.system.op_staticcall(frame);
    return next(frame, ops, ip);
}

pub fn op_revert(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    _ = ops;
    _ = ip;
    try execution.system.op_revert(frame);
    return Error.REVERT;
}

pub fn op_invalid(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    _ = frame;
    _ = ops;
    _ = ip;
    return Error.INVALID;
}

pub fn op_selfdestruct(frame: *Frame, ops: [*]const TailcallFunc, ip: *usize) Error!noreturn {
    _ = ops;
    _ = ip;
    try execution.system.op_selfdestruct(frame);
    return Error.STOP;
}