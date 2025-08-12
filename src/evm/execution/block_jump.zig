const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const ExecutionResult = @import("execution_result.zig");
const Instruction = @import("../instruction.zig").Instruction;

/// JUMP implementation for block-based execution.
/// Uses pre-resolved jump targets instead of PC manipulation.
pub fn block_jump(
    pc: usize,
    interpreter: Operation.Interpreter,
    state: Operation.State,
    target: *const Instruction,
) ExecutionError.Error!?[*]const Instruction {
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Pop the destination from stack (still needed for validation)
    const dest = try frame.stack.pop();

    // Validate that the jump destination matches what we expect
    // This ensures the jump target hasn't been manipulated
    if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
        return ExecutionError.Error.InvalidJump;
    }

    // Return the pre-resolved target instruction pointer
    return @ptrCast(target);
}

/// JUMPI implementation for block-based execution.
/// Conditionally jumps based on stack value.
pub fn block_jumpi(
    pc: usize,
    interpreter: Operation.Interpreter,
    state: Operation.State,
    target: *const Instruction,
    next: [*]const Instruction,
) ExecutionError.Error!?[*]const Instruction {
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Pop destination and condition
    const dest = try frame.stack.pop();
    const condition = try frame.stack.pop();

    // If condition is false, continue to next instruction
    if (condition == 0) {
        return next;
    }

    // Validate jump destination
    if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
        return ExecutionError.Error.InvalidJump;
    }

    // Jump to target
    return @ptrCast(target);
}
