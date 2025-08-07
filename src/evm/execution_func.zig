/// Execution function type for EVM opcodes.
/// 
/// This file exists to break circular dependencies between instruction.zig,
/// operation.zig, frame.zig, and evm.zig.

// Import only the error types we need
const ExecutionError = @import("execution/execution_error.zig");
const ExecutionResult = @import("execution/execution_result.zig");

/// Forward declare the types to avoid circular dependencies
const Evm = @import("evm.zig");
const Frame = @import("frame/frame.zig");

/// Function signature for EVM opcode execution.
///
/// @param pc Current program counter position
/// @param interpreter VM interpreter context  
/// @param state Execution state and environment
/// @return Execution result indicating success/failure and gas consumption
pub const ExecutionFunc = *const fn (pc: usize, interpreter: *Evm, state: *Frame) ExecutionError.Error!ExecutionResult;