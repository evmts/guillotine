const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Operation = @import("../opcodes/operation.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const ExtendedPcToOpEntry = CodeAnalysis.ExtendedPcToOpEntry;
const Stack = @import("../stack/stack.zig");
const Log = @import("../log.zig");

/// PUSH operation using pre-extracted small value (PUSH1-PUSH8)
pub fn push_preextracted_small(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;
    const frame = state;
    
    // Get extended entry - guaranteed to exist in fast path
    const entry = frame.contract.analysis.?.extended_entries.?[pc];
    
    // Stack check already done by block validation in optimized execution
    const value: u256 = entry.arg.small_push;
    try frame.stack.push(value);
    
    Log.debug("push_preextracted_small at pc={}: value=0x{x}, size={}", .{ pc, value, entry.size });
    
    return Operation.ExecutionResult{ .bytes_consumed = entry.size };
}

/// PUSH operation using pre-extracted large value (PUSH9-PUSH32)
pub fn push_preextracted_large(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;
    const frame = state;
    
    const entry = frame.contract.analysis.?.extended_entries.?[pc];
    const value = frame.contract.analysis.?.large_push_values.?[entry.arg.large_push_idx];
    
    try frame.stack.push(value);
    
    Log.debug("push_preextracted_large at pc={}: idx={}, value=0x{x}, size={}", .{ pc, entry.arg.large_push_idx, value, entry.size });
    
    return Operation.ExecutionResult{ .bytes_consumed = entry.size };
}

/// Runtime dispatch for PUSH operations
pub fn push_with_preextract_check(comptime n: u8) Operation.ExecutionFunc {
    return struct {
        fn exec(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            const frame = state;
            
            // Check if we have pre-extracted entries
            if (frame.contract.analysis) |analysis| {
                if (analysis.extended_entries) |entries| {
                    const entry = entries[pc];
                    switch (entry.arg) {
                        .small_push => return push_preextracted_small(pc, interpreter, state),
                        .large_push_idx => return push_preextracted_large(pc, interpreter, state),
                        else => {},
                    }
                }
            }
            
            // Fallback to original implementation
            if (n == 1) {
                return @import("stack.zig").op_push1(pc, interpreter, state);
            } else if (n <= 8) {
                return @import("stack.zig").make_push_small(n)(pc, interpreter, state);
            } else {
                return @import("stack.zig").make_push(n)(pc, interpreter, state);
            }
        }
    }.exec;
}

/// Create runtime dispatch wrapper for a specific PUSH size
pub fn makePushWithPreextractCheck(comptime n: u8) Operation.Operation {
    const gas = @import("../constants/gas_constants.zig");
    
    return Operation.Operation{
        .execute = push_with_preextract_check(n),
        .constant_gas = gas.GasFastestStep,
        .min_stack = 0,
        .max_stack = Stack.CAPACITY - 1,
    };
}