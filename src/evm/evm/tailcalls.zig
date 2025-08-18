const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const StackFrame = @import("../stack_frame.zig").StackFrame;
const execution = @import("../execution/package.zig");
const builtin = @import("builtin");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - only takes StackFrame
const TailcallFunc = *const fn (frame: *StackFrame) Error!noreturn;

// Helper to advance to next instruction
pub inline fn next(frame: *StackFrame) Error!noreturn {
    if (comptime SAFE) {
        try frame.check_iteration_limit();
    }

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

    try frame.stack.append(0);
    return next(frame);
}

// Handle PUSH operations with data bytes
pub fn op_push(frame: *StackFrame) Error!noreturn {
    // Use cached analysis for O(1) lookup
    const pc = frame.analysis.getPc(frame.ip);
    if (pc != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        const bytecode = frame.analysis.bytecode;
        if (pc < bytecode.len) {
            const opcode = bytecode[pc];
            
            // Handle PUSH0
            if (opcode == 0x5F) {
                try frame.stack.append(0);
                return next(frame);
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
                
                try frame.stack.append(value);
                return next(frame);
            }
        }
    }

    // If we get here, something is wrong with the analysis
    return Error.InvalidOpcode;
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
    const dest = try frame.stack.pop();

    // Use cached analysis for O(1) lookup
    const inst_idx = frame.analysis.getInstIdx(@intCast(dest));
    if (inst_idx != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        // Verify it's a valid JUMPDEST
        const code = frame.analysis.bytecode;
        if (dest < code.len and code[@intCast(dest)] == 0x5B) {
            frame.ip = inst_idx;
            return next(frame);
        }
    }
    return Error.InvalidJump;
}

pub fn op_jumpi(frame: *StackFrame) Error!noreturn {
    const dest = try frame.stack.pop();
    const condition = try frame.stack.pop();

    if (condition != 0) {
        // Use cached analysis for O(1) lookup
        const inst_idx = frame.analysis.getInstIdx(@intCast(dest));
        if (inst_idx != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
            // Verify it's a valid JUMPDEST
            const code = frame.analysis.bytecode;
            if (dest < code.len and code[@intCast(dest)] == 0x5B) {
                frame.ip = inst_idx;
                return next(frame);
            }
        }
        return Error.InvalidJump;
    } else {
        // Condition is false, continue to next instruction
        return next(frame);
    }
}

pub fn op_pc(frame: *StackFrame) Error!noreturn {
    // Use cached analysis for O(1) lookup
    const pc = frame.analysis.getPc(frame.ip);
    if (pc != @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        try frame.stack.append(pc);
        return next(frame);
    }

    // If we get here, something is wrong with the analysis
    return Error.InvalidOpcode;
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
    // Get the PC for this instruction to read the push value
    const pc = frame.analysis.getPc(frame.ip);
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    const bytecode = frame.analysis.bytecode;
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
    const dest_inst_idx = frame.analysis.getInstIdx(dest);
    if (dest_inst_idx == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    // In Debug/ReleaseSafe, validate it's a JUMPDEST
    if (comptime SAFE) {
        if (dest >= frame.analysis.bytecode.len or frame.analysis.bytecode[dest] != 0x5B) {
            return Error.InvalidJump;
        }
    }
    
    // Jump directly to the destination
    frame.ip = dest_inst_idx;
    return next(frame);
}

// Fused PUSH+JUMPI operation
pub fn op_push_then_jumpi(frame: *StackFrame) Error!noreturn {
    // Get the PC for this instruction to read the push value
    const pc = frame.analysis.getPc(frame.ip);
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    const bytecode = frame.analysis.bytecode;
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
    const condition = frame.stack.pop_unsafe();
    
    // If condition is non-zero, take the jump
    if (condition != 0) {
        // Convert PC destination to instruction index
        const dest_inst_idx = frame.analysis.getInstIdx(dest);
        if (dest_inst_idx == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
            return Error.InvalidJump;
        }
        
        // In Debug/ReleaseSafe, validate it's a JUMPDEST
        if (comptime SAFE) {
            if (dest >= frame.analysis.bytecode.len or frame.analysis.bytecode[dest] != 0x5B) {
                return Error.InvalidJump;
            }
        }
        
        // Jump to the destination
        frame.ip = dest_inst_idx;
        return next(frame);
    } else {
        // Condition is zero, continue to next instruction
        return next(frame);
    }
}

// Helper function to read push value from bytecode
inline fn readPushValue(frame: *StackFrame) !u256 {
    const pc = frame.analysis.getPc(frame.ip);
    if (pc == @import("analysis2.zig").SimpleAnalysis.MAX_USIZE) {
        return Error.InvalidJump;
    }
    
    const bytecode = frame.analysis.bytecode;
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
pub fn op_push_then_mload(frame: *StackFrame) Error!noreturn {

    const offset = try readPushValue(frame);
    
    // Push offset to stack then call mload
    frame.stack.append_unsafe(offset);
    try execution.memory.op_mload(frame);
    return next(frame);
}

pub fn op_push_then_mstore(frame: *StackFrame) Error!noreturn {

    const offset = try readPushValue(frame);
    const value = frame.stack.pop_unsafe();
    
    // Push value and offset to stack then call mstore
    frame.stack.append_unsafe(value);
    frame.stack.append_unsafe(offset);
    try execution.memory.op_mstore(frame);
    return next(frame);
}

// Comparison operation fusions
pub fn op_push_then_eq(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    const result: u256 = if (other == push_val) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_lt(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    // Note: In EVM, LT pops a then b, and checks if a < b
    // PUSH pushes the value that becomes 'a', so we check push_val < other
    const result: u256 = if (push_val < other) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_gt(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    // Note: In EVM, GT pops a then b, and checks if a > b
    // PUSH pushes the value that becomes 'a', so we check push_val > other
    const result: u256 = if (push_val > other) 1 else 0;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Bitwise operation fusions
pub fn op_push_then_and(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    const result = other & push_val;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Arithmetic operation fusions
pub fn op_push_then_add(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    const result = other +% push_val; // Wrapping add
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_sub(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    // Note: In EVM, SUB pops a then b, and computes a - b
    // PUSH pushes the value that becomes 'a', so we compute push_val - other
    const result = push_val -% other; // Wrapping sub
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_mul(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    const result = other *% push_val; // Wrapping mul
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

pub fn op_push_then_div(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const other = try frame.stack.peek_unsafe();
    
    // Note: In EVM, DIV pops a then b, and computes a / b
    // PUSH pushes the value that becomes 'a', so we compute push_val / other
    const result = if (other == 0) 0 else push_val / other;
    frame.stack.set_top_unsafe(result);
    return next(frame);
}

// Storage operation fusions
pub fn op_push_then_sload(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const key = try readPushValue(frame);
    
    // Push key to stack then call sload
    frame.stack.append_unsafe(key);
    try execution.storage.op_sload(frame);
    return next(frame);
}

// Stack operation fusions
pub fn op_push_then_dup1(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const value = try readPushValue(frame);
    
    // Push the value twice (PUSH then DUP1 effect)
    frame.stack.append_unsafe(value);
    frame.stack.append_unsafe(value);
    return next(frame);
}

pub fn op_push_then_swap1(frame: *StackFrame) Error!noreturn {

    // Use frame.analysis directly instead of casting
    const push_val = try readPushValue(frame);
    const top = frame.stack.pop_unsafe();
    
    // Push in swapped order
    frame.stack.append_unsafe(push_val);
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
