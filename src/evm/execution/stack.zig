const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Vm = @import("../evm.zig");

const StackValidation = @import("../stack/stack_validation.zig");
const Address = @import("primitives").Address;

pub fn op_pop(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = try frame.stack.pop();
}






// ExecutionContext-based factory function for DUP operations
pub fn make_dup_ec(comptime n: u8) fn (*ExecutionContext) ExecutionError.Error!void {
    return struct {
        pub fn dup_ec(context: *ExecutionContext) ExecutionError.Error!void {
            return dup_impl_context(n, context);
        }
    }.dup_ec;
}

// Runtime dispatch versions for DUP operations (used in ReleaseSmall mode)
// Each DUP operation gets its own function to avoid opcode detection issues

// Helper function for DUP operations - using ExecutionContext
fn dup_impl_context(n: u8, context: *ExecutionContext) ExecutionError.Error!void {
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


// ExecutionContext versions of DUP operations (new pattern)
pub fn op_dup1(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(1, frame);
}

pub fn op_dup2(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(2, frame);
}

pub fn op_dup3(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(3, frame);
}

pub fn op_dup4(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(4, frame);
}

pub fn op_dup5(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(5, frame);
}

pub fn op_dup6(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(6, frame);
}

pub fn op_dup7(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(7, frame);
}

pub fn op_dup8(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(8, frame);
}

pub fn op_dup9(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(9, frame);
}

pub fn op_dup10(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(10, frame);
}

pub fn op_dup11(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(11, frame);
}

pub fn op_dup12(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(12, frame);
}

pub fn op_dup13(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(13, frame);
}

pub fn op_dup14(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(14, frame);
}

pub fn op_dup15(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(15, frame);
}

pub fn op_dup16(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return dup_impl_context(16, frame);
}

// DUP operations are now generated directly in jump_table.zig using make_dup()


// ExecutionContext-based factory function for SWAP operations  
pub fn make_swap_ec(comptime n: u8) fn (*ExecutionContext) ExecutionError.Error!void {
    return struct {
        pub fn swap_ec(context: *ExecutionContext) ExecutionError.Error!void {
            return swap_impl_context(n, context);
        }
    }.swap_ec;
}

// Helper function for SWAP operations - using ExecutionContext
fn swap_impl_context(n: u8, context: *ExecutionContext) ExecutionError.Error!void {
    // Stack underflow check - SWAP needs n+1 items
    if (context.stack.size() < n + 1) {
        return ExecutionError.Error.StackUnderflow;
    }

    context.stack.swap_unsafe(n);
}

// ExecutionContext versions of SWAP operations (new pattern)
pub fn op_swap1(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(1, frame);
}

pub fn op_swap2(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(2, frame);
}

pub fn op_swap3(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(3, frame);
}

pub fn op_swap4(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(4, frame);
}

pub fn op_swap5(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(5, frame);
}

pub fn op_swap6(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(6, frame);
}

pub fn op_swap7(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(7, frame);
}

pub fn op_swap8(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(8, frame);
}

pub fn op_swap9(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(9, frame);
}

pub fn op_swap10(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(10, frame);
}

pub fn op_swap11(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(11, frame);
}

pub fn op_swap12(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(12, frame);
}

pub fn op_swap13(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(13, frame);
}

pub fn op_swap14(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(14, frame);
}

pub fn op_swap15(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(15, frame);
}

pub fn op_swap16(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return swap_impl_context(16, frame);
}

// SWAP operations are now generated directly in jump_table.zig using make_swap()

// FIXME: All tests commented out during ExecutionContext migration - they use old Contract/Frame pattern
