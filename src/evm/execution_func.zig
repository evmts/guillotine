/// Execution function type for EVM opcodes.
/// 
/// This file exists to break circular dependencies between instruction.zig,
/// operation.zig, frame.zig, and evm.zig.

// Import only the error types we need
const ExecutionError = @import("execution/execution_error.zig");
const ExecutionResult = @import("execution/execution_result.zig");

/// Function signature for EVM opcode execution using opaque pointers to break dependencies.
///
/// @param pc Current program counter position
/// @param interpreter VM interpreter context (opaque pointer)
/// @param state Execution state and environment (opaque pointer) 
/// @return Execution result indicating success/failure and gas consumption
pub const ExecutionFunc = *const fn (pc: usize, interpreter: *anyopaque, state: *anyopaque) ExecutionError.Error!ExecutionResult;