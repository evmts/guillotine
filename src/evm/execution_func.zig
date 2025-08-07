/// Execution function type for EVM opcodes.
///
/// This file exists to break circular dependencies between instruction.zig,
/// operation.zig, execution_context.zig, and evm.zig.

// Import only the error types we need. Avoid importing ExecutionContext here to prevent cycles.
const ExecutionError = @import("execution/execution_error.zig");

/// Function signature for EVM opcode execution using an opaque pointer to the execution context.
///
/// @param context Opaque pointer (cast to the appropriate type by the opcode implementation)
/// @return Execution error (void return means success)
pub const ExecutionFunc = *const fn (context: *anyopaque) ExecutionError.Error!void;
