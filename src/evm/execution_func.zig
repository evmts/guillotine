/// Execution function type for EVM opcodes.
///
/// This file exists to break circular dependencies between instruction.zig,
/// operation.zig, execution_context.zig, and evm.zig.

// Import only the error types we need
const ExecutionError = @import("execution/execution_error.zig");
const ExecutionResult = @import("execution/execution_result.zig");
/// Function signature for EVM opcode execution using ExecutionContext only.
///
/// Uses opaque pointer to avoid circular dependency with execution_context.zig
/// @param context Pointer to ExecutionContext containing all execution state
/// @return Execution error (void return means success)
pub const ExecutionFunc = *const fn (context: *anyopaque) ExecutionError.Error!void;
