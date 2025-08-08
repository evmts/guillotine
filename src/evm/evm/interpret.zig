const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const MAX_ITERATIONS = 10_000_000; // TODO set this to a real problem


/// Execute contract bytecode using block-based execution.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Uses provided Frame, no internal allocations.
///
/// The caller is responsible for creating and managing the Frame and its components.
pub inline fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    self.require_one_thread();

    // Frame is provided by caller, get the analysis from it
    const instructions = frame.analysis.instructions;
    var current_index: usize = 0;
    var loop_iterations: usize = 0;

    while (current_index < instructions.len) {
        @branchHint(.likely);
        const nextInstruction = instructions[current_index];

        // In safe mode we make sure we don't loop too much. If this happens
        if (comptime SAFE) {
            loop_iterations += 1;
            if (loop_iterations > MAX_ITERATIONS) {
                Log.err("interpret: Infinite loop detected after {} iterations at pc={}, depth={}, gas={}. This should never happen and indicates either the limit was set too low or a high severity bug has been found in EVM", .{ loop_iterations, current_index, self.depth, frame.gas_remaining });
                unreachable;
            }
        }

        // Handle instruction
        switch (nextInstruction.arg) {
            // BEGINBLOCK instructions - validate entire basic block upfront
            // This eliminates per-instruction gas and stack validation for the entire block
            .block_info => {
                current_index += 1;
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    return err;
                };
            },
            // For jumps we handle them inline as they are preprocessed by analysis
            // 1. Handle dynamic jumps validating it is a valid jumpdest
            // 2. Handle optional jump
            // 3. Handle normal jump
            .jump_target => |jump_target| {
                switch (jump_target.jump_type) {
                    .jump => {
                        const dest = frame.stack.pop_unsafe();
                        if (!frame.valid_jumpdest(dest)) {
                            return ExecutionError.Error.InvalidJump;
                        }
                        current_index = @intFromPtr(jump_target.instruction) - @intFromPtr(instructions.ptr);
                    },
                    .jumpi => {
                        const pops = frame.stack.pop2_unsafe();
                        const dest = pops.a;
                        const condition = pops.b;
                        if (condition != 0) {
                            if (!frame.valid_jumpdest(dest)) {
                                return ExecutionError.Error.InvalidJump;
                            }
                            current_index = @intFromPtr(jump_target.instruction) - @intFromPtr(instructions.ptr);
                        } else {
                            current_index += 1;
                        }
                    },
                    .other => {
                        current_index = @intFromPtr(jump_target.instruction) - @intFromPtr(instructions.ptr);
                    },
                }
            },
            .push_value => |value| {
                current_index += 1;
                try frame.stack.append(value);
            },
            .none => {
                @branchHint(.likely);
                // Most opcodes now have .none - no individual gas/stack validation needed
                // Gas and stack validation is handled by BEGINBLOCK instructions
                current_index += 1;
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    // Frame already manages its own output, no need to copy

                    // Handle gas exhaustion for InvalidOpcode specifically
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }

                    return err;
                };
            },
            .gas_cost => |cost| {
                // Legacy path - kept for compatibility
                current_index += 1;
                if (frame.gas_remaining < cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= cost;
                
                // Execute the opcode after charging gas
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    return err;
                };
            },
            .dynamic_gas => |dyn_gas| {
                // New path for opcodes with dynamic gas
                current_index += 1;
                
                // Charge static gas first
                if (frame.gas_remaining < dyn_gas.static_cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= dyn_gas.static_cost;
                
                // Calculate and charge dynamic gas if function exists
                if (dyn_gas.gas_fn) |gas_fn| {
                    const additional_gas = gas_fn(frame) catch |err| {
                        // If dynamic gas calculation fails, it's usually OutOfOffset
                        if (err == ExecutionError.Error.OutOfOffset) {
                            return err;
                        }
                        // For other errors, treat as out of gas
                        frame.gas_remaining = 0;
                        return ExecutionError.Error.OutOfGas;
                    };
                    
                    if (frame.gas_remaining < additional_gas) {
                        @branchHint(.cold);
                        frame.gas_remaining = 0;
                        return ExecutionError.Error.OutOfGas;
                    }
                    frame.gas_remaining -= additional_gas;
                }
                
                // Execute the opcode after all gas is charged
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    return err;
                };
            },
        }
    }
}
