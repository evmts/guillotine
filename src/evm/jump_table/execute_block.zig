const std = @import("std");
const builtin = @import("builtin");
const operation_module = @import("../opcodes/operation.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame/frame.zig");
const Log = @import("../log.zig");

/// Execute an opcode in block mode without per-instruction validation.
///
/// This function is used when executing within a pre-validated block.
/// It skips stack validation and gas consumption since these have been
/// checked at the block level.
///
/// SAFETY: This function assumes the block has been validated with
/// validate_block() and must only be called for instructions within
/// that validated block.
pub inline fn execute_block_unsafe(
    operation: *const operation_module.Operation,
    pc: usize,
    interpreter: operation_module.Interpreter,
    frame: operation_module.State,
) ExecutionError.Error!operation_module.ExecutionResult {
    @branchHint(.likely);
    
    Log.debug("execute_block_unsafe: Executing opcode at pc={} in block mode", .{pc});
    
    // Skip all validation - block already validated
    // Skip gas consumption - block gas already consumed
    
    // Execute operation directly
    return operation.execute(pc, interpreter, frame);
}

/// Execute an opcode with conditional validation based on block mode.
///
/// When frame.block_mode is true, skips per-instruction validation.
/// Otherwise, performs normal validation.
pub inline fn execute_conditional(
    table: *const @import("jump_table.zig").JumpTable,
    pc: usize,
    interpreter: operation_module.Interpreter,
    frame: operation_module.State,
    opcode: u8,
) ExecutionError.Error!operation_module.ExecutionResult {
    @branchHint(.likely);
    
    const operation = table.get_operation(opcode);
    
    // Check if we're in block mode
    if (frame.block_mode) {
        @branchHint(.likely);
        
        // In block mode, skip validation
        if (operation.undefined) {
            @branchHint(.cold);
            Log.debug("execute_conditional: Invalid opcode 0x{x:0>2} in block mode", .{opcode});
            frame.gas_remaining = 0;
            return ExecutionError.Error.InvalidOpcode;
        }
        
        // Execute without validation
        return execute_block_unsafe(operation, pc, interpreter, frame);
    } else {
        // Normal mode - use regular execution with validation
        return table.execute(pc, interpreter, frame, opcode);
    }
}