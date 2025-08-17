const ExecutionError = @import("execution/execution_error.zig");

/// Function signature for tailcall-based EVM opcode execution.
/// 
/// Each handler executes its operation and then tailcalls the next instruction,
/// creating an efficient dispatch chain without returning to a central loop.
///
/// Parameters:
/// - context: The execution frame (*Frame) cast to *anyopaque
///
/// The handler should:
/// 1. Cast context back to *Frame
/// 2. Execute its operation using the frame
/// 3. Update frame.tailcall_index if needed (jumps) or increment it (sequential)
/// 4. Tailcall the next instruction via @call(.always_tail, frame.tailcall_ops[frame.tailcall_index], .{context})
///
/// Halting instructions (STOP, RETURN, REVERT) return instead of tailcalling.
pub const TailcallExecutionFunc = fn (context: *anyopaque) ExecutionError.Error!void;