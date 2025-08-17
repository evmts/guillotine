const ExecutionError = @import("execution/execution_error.zig");

/// Function signature for tailcall-based EVM opcode execution.
/// 
/// Each handler executes its operation and then tailcalls the next instruction,
/// creating an efficient dispatch chain without returning to a central loop.
///
/// Parameters:
/// - frame: The execution frame containing stack, memory, gas, state, and now also:
///          - ops: Base pointer to the ops array (for calculating jump targets)
///          - ip: Current instruction pointer (handlers can modify for control flow)
///
/// The handler should:
/// 1. Execute its operation using the frame
/// 2. Update frame.ip if needed (jumps) or increment it (sequential)
/// 3. Tailcall the next instruction via @call(.always_tail, frame.ip[0], ...)
///
/// Halting instructions (STOP, RETURN, REVERT) return instead of tailcalling.
pub const TailcallExecutionFunc = *const fn (
    frame: *anyopaque,
) ExecutionError.Error!void;