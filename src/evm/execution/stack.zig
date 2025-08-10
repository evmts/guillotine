//! Stack manipulation operations for the Ethereum Virtual Machine
//!
//! This module implements stack-related opcodes including POP, DUP1-DUP16,
//! SWAP1-SWAP16, and PUSH0-PUSH32.
//!
//! ## Stack Model
//! - Stack holds 256-bit words (u256)
//! - Maximum depth: 1024 elements
//! - LIFO (Last In, First Out) operation
//! - Stack underflow/overflow causes execution failure
//!
//! ## Gas Costs
//! - POP: 2 gas
//! - DUP operations: 3 gas
//! - SWAP operations: 3 gas
//! - PUSH operations: 3 gas

const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const Frame = @import("../frame.zig").Frame;
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Vm = @import("../evm.zig");

const StackValidation = @import("../stack/stack_validation.zig");
const Address = @import("primitives").Address;

/// POP opcode (0x50) - Remove top stack item
///
/// Removes and discards the top item from the stack.
/// Stack: [a] → []
pub fn op_pop(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    _ = try frame.stack.pop();
}

/// Factory function for creating DUP operations
///
/// Creates a DUP function for duplicating the nth stack item (1-indexed).
/// The created function duplicates the nth item and pushes it to the top.
pub fn make_dup_ec(comptime n: u8) fn (*Frame) ExecutionError.Error!void {
    return struct {
        pub fn dup_ec(context: *Frame) ExecutionError.Error!void {
            return dup_impl_context(n, context);
        }
    }.dup_ec;
}

/// Helper function for DUP operations
///
/// Duplicates the nth item from the top of the stack (1-indexed).
/// DUP1 duplicates the top item, DUP2 the second from top, etc.
fn dup_impl_context(n: u8, context: *Frame) ExecutionError.Error!void {
    // Compile-time validation: DUP operations pop 0 items, push 1
    // At compile time, this validates that DUP has valid EVM stack effects
    // At runtime, this ensures sufficient stack depth for DUPn operations
    try StackValidation.validateStackRequirements(0, 1, context.stack.size());

    // Additional runtime check for DUP depth (n must be available on stack)
    if (context.stack.size() < n) {
        @branchHint(.cold);
        return ExecutionError.Error.StackUnderflow;
    }

    context.stack.dup_unsafe(n);
}

/// DUP1 opcode (0x80) - Duplicate 1st stack item
///
/// Duplicates the top stack item.
/// Stack: [a] → [a, a]
pub fn op_dup1(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(1, frame);
}

/// DUP2 opcode (0x81) - Duplicate 2nd stack item
///
/// Duplicates the second item from the top.
/// Stack: [a, b] → [a, b, a]
pub fn op_dup2(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(2, frame);
}

pub fn op_dup3(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(3, frame);
}

pub fn op_dup4(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(4, frame);
}

pub fn op_dup5(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(5, frame);
}

pub fn op_dup6(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(6, frame);
}

pub fn op_dup7(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(7, frame);
}

pub fn op_dup8(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(8, frame);
}

pub fn op_dup9(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(9, frame);
}

pub fn op_dup10(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(10, frame);
}

pub fn op_dup11(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(11, frame);
}

pub fn op_dup12(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(12, frame);
}

pub fn op_dup13(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(13, frame);
}

pub fn op_dup14(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(14, frame);
}

pub fn op_dup15(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(15, frame);
}

pub fn op_dup16(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return dup_impl_context(16, frame);
}

// DUP operations are now generated directly in jump_table.zig using make_dup()

/// Factory function for creating SWAP operations
///
/// Creates a SWAP function for exchanging the top stack item with the nth item.
/// SWAP1 exchanges top with 2nd, SWAP2 exchanges top with 3rd, etc.
pub fn make_swap_ec(comptime n: u8) fn (*Frame) ExecutionError.Error!void {
    return struct {
        pub fn swap_ec(context: *Frame) ExecutionError.Error!void {
            return swap_impl_context(n, context);
        }
    }.swap_ec;
}

/// Helper function for SWAP operations
///
/// Swaps the top stack item with the item at position n+1 (1-indexed).
fn swap_impl_context(n: u8, context: *Frame) ExecutionError.Error!void {
    // Stack underflow check - SWAP needs n+1 items
    if (context.stack.size() < n + 1) {
        return ExecutionError.Error.StackUnderflow;
    }

    context.stack.swap_unsafe(n);
}

/// SWAP1 opcode (0x90) - Exchange 1st and 2nd stack items
///
/// Swaps the top two stack items.
/// Stack: [a, b] → [b, a]
pub fn op_swap1(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(1, frame);
}

/// SWAP2 opcode (0x91) - Exchange 1st and 3rd stack items
///
/// Swaps the top item with the third item.
/// Stack: [a, b, c] → [c, b, a]
pub fn op_swap2(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(2, frame);
}

pub fn op_swap3(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(3, frame);
}

pub fn op_swap4(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(4, frame);
}

pub fn op_swap5(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(5, frame);
}

pub fn op_swap6(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(6, frame);
}

pub fn op_swap7(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(7, frame);
}

pub fn op_swap8(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(8, frame);
}

pub fn op_swap9(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(9, frame);
}

pub fn op_swap10(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(10, frame);
}

pub fn op_swap11(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(11, frame);
}

pub fn op_swap12(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(12, frame);
}

pub fn op_swap13(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(13, frame);
}

pub fn op_swap14(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(14, frame);
}

pub fn op_swap15(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(15, frame);
}

pub fn op_swap16(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return swap_impl_context(16, frame);
}

// SWAP operations are now generated directly in jump_table.zig using make_swap()

// FIXME: All tests commented out during ExecutionContext migration - they use old Contract/Frame pattern
