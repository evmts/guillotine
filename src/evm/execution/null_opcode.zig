const ExecutionError = @import("execution_error.zig");

/// Invalid opcode handler - shared static function for all invalid/unimplemented opcodes
/// This handles any opcode that shouldn't be reached and provides a single memory location
/// for the jump table to reference rather than creating multiple invalid handlers.
pub fn op_invalid(comptime config: anytype, context: *anyopaque) ExecutionError.Error!void {
    _ = config; // Config parameter available for future use
    _ = context;
    
    // INVALID opcode consumes all remaining gas and returns InvalidOpcode error
    // This is the standard EVM behavior for invalid opcodes
    return ExecutionError.Error.InvalidOpcode;
}