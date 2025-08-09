const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Evm = @import("../evm.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;
const execute = @import("execute.zig").execute;

/// Refactored call function that delegates to the unified execute function.
/// 
/// This is the new streamlined implementation that replaces the workaround
/// in the original call.zig. It simply forwards the call to the unified
/// execute function which handles both root and nested calls uniformly.
///
/// @param self The EVM instance
/// @param params Call parameters
/// @return CallResult with execution results
pub inline fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Simply delegate to the unified execute function
    return execute(self, params);
}