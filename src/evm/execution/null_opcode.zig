const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;

/// Invalid opcode handler - shared static function for all invalid/unimplemented opcodes
/// This handles any opcode that shouldn't be reached and provides a single memory location
/// for the jump table to reference rather than creating multiple invalid handlers.
pub fn op_invalid(frame: *Frame) ExecutionError.Error!void {
    _ = frame;
    
    // INVALID opcode consumes all remaining gas and returns InvalidOpcode error
    // This is the standard EVM behavior for invalid opcodes
    return ExecutionError.Error.InvalidOpcode;
}