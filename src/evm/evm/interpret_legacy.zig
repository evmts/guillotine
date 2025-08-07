const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
const Memory = @import("../memory/memory.zig");
const ReturnData = @import("return_data.zig").ReturnData;
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");
const ExecutionContext = @import("../execution_context.zig").ExecutionContext;
const CodeAnalysis = @import("../analysis/analysis.zig");

/// Legacy interpret function - placeholder implementation
///
/// This function previously executed contract bytecode using the old Contract/Frame system.
/// It has been converted to work with ExecutionContext but actual execution is not yet implemented.
///
/// TODO: Implement proper execution using ExecutionContext when the execution system is ready.
///
/// @param context ExecutionContext containing all execution state
/// @param code The bytecode to execute
/// @param input Input data for the execution
/// @param is_static Whether this is a static call
/// @return RunResult with execution status
pub fn interpret(self: *Vm, context: *ExecutionContext, code: []const u8, input: []const u8, is_static: bool) ExecutionError.Error!RunResult {
    Log.debug("VM.interpret: Starting execution (placeholder), depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, context.gas_remaining, is_static, code.len, input.len });

    self.require_one_thread();

    self.depth += 1;
    defer self.depth -= 1;

    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;

    self.read_only = self.read_only or is_static;

    const initial_gas = context.gas_remaining;

    // TODO: Implement actual bytecode execution using ExecutionContext
    // The old frame-based execution loop has been removed
    // This needs to be replaced with ExecutionContext-based execution

    // For now, return a placeholder result indicating execution is not implemented
    Log.debug("VM.interpret: Execution not yet implemented with ExecutionContext, returning placeholder result", .{});
    
    // Update the context gas to show it was "consumed"
    context.gas_remaining = 0;
    
    // Return a simple failure result
    return RunResult.init(
        initial_gas,
        0, // no gas left
        .Invalid, // status
        ExecutionError.Error.INVALID, // error - using INVALID to indicate not implemented
        null, // no output
    );
}
