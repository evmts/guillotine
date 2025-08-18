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
const Frame = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");
const U256 = primitives.Uint(256, 4);

// NOTE: The following fusion functions are assigned by analysis.zig but never called.
// The interpreter handles these cases inline. These are kept to avoid breaking the analysis phase.

/// PUSH + ADD fusion - NOT USED (handled inline by interpreter)
pub fn op_push_add_fusion(frame: *Frame) ExecutionError.Error!void {
    _ = context;
    unreachable; // Should never be called
}

/// PUSH + SUB fusion - NOT USED (handled inline by interpreter)
pub fn op_push_sub_fusion(frame: *Frame) ExecutionError.Error!void {
    _ = context;
    unreachable; // Should never be called
}

/// PUSH + MUL fusion - NOT USED (handled inline by interpreter)
pub fn op_push_mul_fusion(frame: *Frame) ExecutionError.Error!void {
    _ = context;
    unreachable; // Should never be called
}

/// PUSH + DIV fusion - NOT USED (handled inline by interpreter)
pub fn op_push_div_fusion(frame: *Frame) ExecutionError.Error!void {
    _ = context;
    unreachable; // Should never be called
}

/// Inline version of ISZERO for hot path optimization
/// Stack: [a] => [(a == 0)]
/// This is one of the most frequently used operations
pub fn op_iszero_inline(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 1);

    const value = frame.stack.peek_unsafe();
    const result: u256 = @intFromBool(value == 0);
    frame.stack.set_top_unsafe(result);
}

/// Inline version of EQ for hot path optimization
/// Stack: [a, b] => [(a == b)]
/// This is one of the most frequently used operations
pub fn op_eq_inline(frame: *Frame) ExecutionError.Error!void {
    std.debug.assert(frame.stack.size() >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe();
    const result: u256 = @intFromBool(a == b);
    frame.stack.set_top_unsafe(result);
}
