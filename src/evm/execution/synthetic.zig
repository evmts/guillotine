/// Synthetic operations for optimized EVM execution
///
/// This module implements synthetic opcodes that represent fused or optimized
/// instruction sequences. These are generated during the analysis phase when
/// certain patterns are detected that can be executed more efficiently as a
/// single operation.
///
/// ## Design Philosophy
///
/// Synthetic opcodes eliminate redundant stack operations and dispatch overhead
/// by combining multiple operations into one. All synthetic operations are
/// marked as inline to ensure they are as fast as possible.
///
/// ## Pattern Recognition
///
/// The analysis phase identifies patterns like:
/// - PUSH + PUSH + arithmetic operation
/// - PUSH 0 + ADD (identity elimination)
/// - PUSH 1 + MUL (identity elimination)
/// - Other algebraic simplifications
///
/// ## Safety
///
/// All synthetic operations maintain the same safety guarantees as their
/// non-fused counterparts. Stack bounds are still checked by the jump table.

const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const primitives = @import("primitives");
const U256 = primitives.Uint(256, 4);

/// Generic ADD operation used as a baseline for synthetic operations.
/// This is the same as the regular ADD but marked inline for maximum performance
/// when used in synthetic contexts.
pub fn op_add_generic(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;
    
    const result = a +% b;
    frame.stack.set_top_unsafe(result);
}

/// PUSH + ADD fusion - combines PUSH immediate value with ADD operation
/// Stack: [a] => [a + immediate]
/// This eliminates one stack push and dispatch overhead
pub fn op_push_add_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    // This function is now called directly from the interpreter
    // which has already extracted the immediate value
    const immediate: u256 = 0; // TODO: pass immediate as parameter
    
    const a = frame.stack.peek_unsafe().*;
    const result = a +% immediate;
    frame.stack.set_top_unsafe(result);
}

/// PUSH + SUB fusion - combines PUSH immediate value with SUB operation
/// Stack: [a] => [a - immediate]
/// This eliminates one stack push and dispatch overhead
pub fn op_push_sub_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    // This function is now called directly from the interpreter
    // which has already extracted the immediate value
    const immediate: u256 = 0; // TODO: pass immediate as parameter
    
    const a = frame.stack.peek_unsafe().*;
    const result = a -% immediate;
    frame.stack.set_top_unsafe(result);
}

/// PUSH + MUL fusion - combines PUSH immediate value with MUL operation
/// Stack: [a] => [a * immediate]
/// This eliminates one stack push and dispatch overhead
pub fn op_push_mul_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    // This function is now called directly from the interpreter
    // which has already extracted the immediate value
    const immediate: u256 = 0; // TODO: pass immediate as parameter
    
    const a = frame.stack.peek_unsafe().*;
    
    // Use U256 for proper wrapping multiplication
    const a_u256 = U256.from_u256_unsafe(a);
    const b_u256 = U256.from_u256_unsafe(immediate);
    const product_u256 = a_u256.wrapping_mul(b_u256);
    const result = product_u256.to_u256_unsafe();
    
    frame.stack.set_top_unsafe(result);
}

/// PUSH + DIV fusion - combines PUSH immediate value with DIV operation
/// Stack: [a] => [a / immediate]
/// This eliminates one stack push and dispatch overhead
pub fn op_push_div_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    // This function is now called directly from the interpreter
    // which has already extracted the immediate value
    const immediate: u256 = 0; // TODO: pass immediate as parameter
    
    const a = frame.stack.peek_unsafe().*;
    
    // Division by zero returns 0 in EVM
    const result = if (immediate == 0) 0 else a / immediate;
    
    frame.stack.set_top_unsafe(result);
}

/// Identity elimination: PUSH 0 + ADD = NOP
/// Stack: [a] => [a]
/// This completely eliminates the operation since adding 0 is identity
pub fn op_add_zero_nop(context: *anyopaque) ExecutionError.Error!void {
    // No-op: adding zero doesn't change the stack
    _ = context;
}

/// Identity elimination: PUSH 1 + MUL = NOP
/// Stack: [a] => [a]
/// This completely eliminates the operation since multiplying by 1 is identity
pub fn op_mul_one_nop(context: *anyopaque) ExecutionError.Error!void {
    // No-op: multiplying by one doesn't change the stack
    _ = context;
}

/// PUSH + PUSH + ADD fusion - precomputes addition of two constants
/// Stack: [] => [immediate1 + immediate2]
/// This replaces 3 operations with a single push
pub fn op_push_push_add_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // This function is now called directly from the interpreter
    // which has already extracted the result value
    const result: u256 = 0; // TODO: pass result as parameter
    
    try frame.stack.push_unsafe(result);
}

/// PUSH + PUSH + MUL fusion - precomputes multiplication of two constants
/// Stack: [] => [immediate1 * immediate2]
/// This replaces 3 operations with a single push
pub fn op_push_push_mul_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // This function is now called directly from the interpreter
    // which has already extracted the result value
    const result: u256 = 0; // TODO: pass result as parameter
    
    try frame.stack.push_unsafe(result);
}

/// PUSH + PUSH + SUB fusion - precomputes subtraction of two constants
/// Stack: [] => [immediate1 - immediate2]
/// This replaces 3 operations with a single push
pub fn op_push_push_sub_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // This function is now called directly from the interpreter
    // which has already extracted the result value
    const result: u256 = 0; // TODO: pass result as parameter
    
    try frame.stack.push_unsafe(result);
}

/// PUSH + PUSH + DIV fusion - precomputes division of two constants
/// Stack: [] => [immediate1 / immediate2]
/// This replaces 3 operations with a single push
pub fn op_push_push_div_fusion(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // This function is now called directly from the interpreter
    // which has already extracted the result value
    const result: u256 = 0; // TODO: pass result as parameter
    
    try frame.stack.push_unsafe(result);
}

/// PUSH 0 + MUL elimination - results in PUSH 0
/// Stack: [a] => [0]
/// Multiplying by zero always gives zero
pub fn op_mul_zero_to_push_zero(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    // Replace top of stack with 0
    frame.stack.set_top_unsafe(0);
}

/// PUSH 1 + DIV elimination = NOP
/// Stack: [a] => [a]
/// Dividing by 1 is identity
pub fn op_div_one_nop(context: *anyopaque) ExecutionError.Error!void {
    // No-op: dividing by one doesn't change the stack
    _ = context;
}

/// DUP1 + PUSH 0 + EQ fusion = ISZERO
/// Stack: [a] => [a, (a == 0)]
/// Common pattern for checking if value is zero
pub fn op_dup_push0_eq_to_iszero(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    const value = frame.stack.peek_unsafe().*;
    const is_zero: @import("../../u256.zig").u256 = if (value == 0) 1 else 0;
    
    try frame.stack.push_unsafe(is_zero);
}

/// PUSH + POP elimination
/// Stack: unchanged
/// Pushing then immediately popping is a no-op
pub fn op_push_pop_nop(context: *anyopaque) ExecutionError.Error!void {
    // No-op: push followed by pop cancels out
    _ = context;
}

/// DUP + DROP elimination
/// Stack: unchanged
/// Duplicating then dropping is a no-op
pub fn op_dup_drop_nop(context: *anyopaque) ExecutionError.Error!void {
    // No-op: dup followed by drop cancels out
    _ = context;
}

/// Inline version of ISZERO for hot path optimization
/// Stack: [a] => [(a == 0)]
/// This is one of the most frequently used operations
pub fn op_iszero_inline(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    const value = frame.stack.peek_unsafe().*;
    const result: u256 = @intFromBool(value == 0);
    frame.stack.set_top_unsafe(result);
}

/// Inline version of EQ for hot path optimization
/// Stack: [a, b] => [(a == b)]
/// This is one of the most frequently used operations
pub fn op_eq_inline(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);
    
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;
    const result: u256 = @intFromBool(a == b);
    frame.stack.set_top_unsafe(result);
}

/// KECCAK256 with precomputed word count for gas calculation
/// Stack: [offset, size] => [hash]
/// This version has the word count precomputed during analysis
pub fn op_keccak256_precomputed(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);
    
    // This function is now called directly from the interpreter
    // which has already extracted the parameters
    const word_count = @as(u64, 0); // TODO: pass as parameter
    const gas_cost = @as(u64, 0); // TODO: pass as parameter
    
    // Consume precomputed gas cost
    try frame.consume_gas(gas_cost);
    
    const size = frame.stack.pop_unsafe();
    const offset = frame.stack.pop_unsafe();
    
    // Bounds checking
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    
    const offset_usize = @as(usize, @intCast(offset));
    const size_usize = @as(usize, @intCast(size));
    
    if (size == 0) {
        @branchHint(.unlikely);
        // Hash of empty data = keccak256("")
        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        frame.stack.append_unsafe(empty_hash);
        return;
    }
    
    // Memory expansion already handled, just get the data
    _ = word_count; // Word count was used for gas calculation
    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);
    const data = try frame.memory.get_slice(offset_usize, size_usize);
    
    // Hash using Keccak256
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
    
    const result = std.mem.readInt(u256, &hash, .big);
    frame.stack.append_unsafe(result);
}

/// KECCAK256 with immediate size - optimized for known sizes
/// Stack: [offset] => [hash]
/// Size is known at analysis time, allowing better optimization
pub fn op_keccak256_immediate_size(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);
    
    // This function is now called directly from the interpreter
    // which has already extracted the parameters
    const size = @as(u64, 0); // TODO: pass as parameter
    const word_count = @as(u64, 0); // TODO: pass as parameter
    const gas_cost = @as(u64, 0); // TODO: pass as parameter
    
    // Consume precomputed gas cost
    try frame.consume_gas(gas_cost);
    
    const offset = frame.stack.pop_unsafe();
    
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    
    const offset_usize = @as(usize, @intCast(offset));
    const size_usize = @as(usize, @intCast(size));
    
    if (size == 0) {
        @branchHint(.unlikely);
        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        frame.stack.append_unsafe(empty_hash);
        return;
    }
    
    _ = word_count; // Used for gas calculation
    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);
    const data = try frame.memory.get_slice(offset_usize, size_usize);
    
    // For small known sizes, we could use stack buffers
    var hash: [32]u8 = undefined;
    if (size <= 64) {
        @branchHint(.likely);
        var buffer: [64]u8 = undefined;
        @memcpy(buffer[0..size_usize], data);
        std.crypto.hash.sha3.Keccak256.hash(buffer[0..size_usize], &hash, .{});
    } else {
        std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
    }
    
    const result = std.mem.readInt(u256, &hash, .big);
    frame.stack.append_unsafe(result);
}