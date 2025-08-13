const ExecutionError = @import("execution/execution_error.zig");

/// Function signature for EVM opcode execution using an opaque pointer to the execution context.
pub const ExecutionFunc = *const fn (context: *anyopaque) ExecutionError.Error!void;
