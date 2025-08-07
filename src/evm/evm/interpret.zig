const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../execution_context.zig").Frame;
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
const InterpretResult = @import("interpret_result.zig").InterpretResult;
const AccessList = @import("../access_list.zig").AccessList;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const Memory = @import("../memory/memory.zig");
const ReturnData = @import("return_data.zig").ReturnData;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const primitives = @import("primitives");
const execution = @import("../execution/package.zig");
const Instruction = @import("../instruction.zig").Instruction;
const CodeAnalysis = @import("../frame/code_analysis.zig");
const instruction_limits = @import("../constants/instruction_limits.zig");
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;

// THE EVM has no actual limit on calldata. Only indirect practical limits like gas cost exist.
// 128 KB is about the limit most rpc providers limit call data to so we use it as the default
pub const MAX_INPUT_SIZE: u18 = 128 * 1024; // 128 kb

/// Execute contract bytecode using block-based execution.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Allocates instruction buffer upfront, may allocate for return data.
///
/// is_static must be known at comptime. Explicitly an switch statement with both options if you need it to be dynamic
/// Making it comptime helps with stack and cache pressure helping performance by removing a boolean and also makes this
/// API very explicit.
pub inline fn interpret(self: *Evm, contract: *Contract, input: []const u8, comptime is_static: bool) ExecutionError.Error!InterpretResult {
    // Input and environment validation
    {
        self.require_one_thread();
        if (contract.input.len > MAX_INPUT_SIZE) return ExecutionError.Error.InputSizeExceeded;
        if (contract.code_size > MAX_CODE_SIZE) return ExecutionError.Error.MaxCodeSizeExceeded;
        if (contract.code_size != contract.code.len) return ExecutionError.Error.CodeSizeMismatch;
        if (contract.gas == 0) return ExecutionError.Error.OutOfGas;
        if (contract.code_size > 0 and contract.code.len == 0) return ExecutionError.Error.CodeSizeMismatch;
    }

    const initial_gas = contract.gas;

    // Initialize state tracking components using GPA allocator
    var access_list = AccessList.init(self.allocator);
    // TODO: Determine if SelfDestruct should be available based on hardfork
    var self_destruct = SelfDestruct.init(self.allocator);

    // Analyze bytecode and get optimized instruction stream in one call
    var analysis = try CodeAnalysis.from_code(self.allocator, contract.code[0..contract.code_size], &self.table);
    defer analysis.deinit();
    var current_instruction = analysis.instructions;

    // Initialize the new execution context Frame  
    const ChainRules = @import("../execution_context.zig").ChainRules;
    const chain_rules = ChainRules{}; // Use default values
    var frame = try Frame.init(
        self.arena_allocator(),
        contract.gas,
        is_static,
        @as(u32, @intCast(self.depth)),
        contract.address,
        &analysis,
        &access_list,
        self.state,
        chain_rules,
        &self_destruct,
    );
    defer frame.deinit();

    var loop_iterations: usize = 0;
    const MAX_ITERATIONS = if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) 10_000_000 else std.math.maxInt(usize);
    var last_pc: usize = 0;
    var same_pc_count: usize = 0;

    while (current_instruction[0]) |nextInstruction| {
        @branchHint(.likely);

        // Debug infinite loops
        loop_iterations += 1;
        if (loop_iterations > MAX_ITERATIONS) {
            Log.err("interpret: Infinite loop detected after {} iterations at pc={}, depth={}, gas={}", .{
                loop_iterations, current_instruction - analysis.instructions, self.depth, frame.gas_remaining
            });
            unreachable;
        }
        
        // Detect stuck at same PC
        const current_pc = current_instruction - analysis.instructions;
        if (current_pc == last_pc) {
            same_pc_count += 1;
            if (same_pc_count > 1000) {
                Log.err("interpret: Stuck at pc={} for {} iterations", .{
                    current_pc, same_pc_count
                });
                unreachable;
            }
        } else {
            last_pc = current_pc;
            same_pc_count = 0;
        }

        // Log every 10000th iteration for visibility
        if (loop_iterations % 10000 == 0) {
            Log.debug("interpret: iteration {}, pc={}, gas={}, stack_size={}", .{
                loop_iterations, current_instruction - analysis.instructions, frame.gas_remaining, frame.stack.size()
            });
        }
        switch (nextInstruction.arg) {
            .jump_target => |target| {
                if (nextInstruction.opcode_fn == execution.control.op_jump) {
                    const dest = frame.stack.pop_unsafe();
                    if (!frame.valid_jumpdest(dest)) {
                        contract.gas = frame.gas_remaining;
                        const run_result = RunResult.init(initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.InvalidJump, null);
                        return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                    }
                    current_instruction = @ptrCast(target);
                } else if (nextInstruction.opcode_fn == execution.control.op_jumpi) {
                    const dest = frame.stack.pop_unsafe();
                    const condition = frame.stack.pop_unsafe();
                    if (condition != 0) {
                        if (!frame.valid_jumpdest(dest)) {
                            contract.gas = frame.gas_remaining;
                            const run_result = RunResult.init(initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.InvalidJump, null);
                            return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                        }
                        current_instruction = @ptrCast(target);
                    } else {
                        current_instruction += 1;
                    }
                } else {
                    // For other opcodes that have jump targets, just use the target
                    current_instruction = @ptrCast(target);
                }
            },
            .push_value => |value| {
                current_instruction += 1;
                try frame.stack.append(value);
            },
            .none => {
                current_instruction += 1;
                nextInstruction.opcode_fn(@ptrCast(&frame)) catch |err| {
                    contract.gas = frame.gas_remaining;

                    var output: ?[]const u8 = null;
                    const return_data = frame.output;
                    if (return_data.len > 0) {
                        output = self.allocator.dupe(u8, return_data) catch {
                            const run_result = RunResult.init(initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null);
                            return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                        };
                    }

                    if (err == ExecutionError.Error.STOP) {
                        @branchHint(.likely);
                        const run_result = RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
                        // Apply destructions before returning
                        // TODO: Apply destructions to state
                        return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                    }

                    return switch (err) {
                        ExecutionError.Error.InvalidOpcode => {
                            frame.gas_remaining = 0;
                            contract.gas = 0;
                            const run_result = RunResult.init(initial_gas, 0, .Invalid, err, output);
                            return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                        },
                        ExecutionError.Error.REVERT => {
                            const run_result = RunResult.init(initial_gas, frame.gas_remaining, .Revert, err, output);
                            return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                        },
                        ExecutionError.Error.OutOfGas => {
                            const run_result = RunResult.init(initial_gas, frame.gas_remaining, .OutOfGas, err, output);
                            return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                        },
                        ExecutionError.Error.InvalidJump,
                        ExecutionError.Error.StackUnderflow,
                        ExecutionError.Error.StackOverflow,
                        ExecutionError.Error.StaticStateChange,
                        ExecutionError.Error.WriteProtection,
                        ExecutionError.Error.DepthLimit,
                        ExecutionError.Error.MaxCodeSizeExceeded,
                        ExecutionError.Error.OutOfMemory,
                        => {
                            const run_result = RunResult.init(initial_gas, frame.gas_remaining, .Invalid, err, output);
                            return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                        },
                        else => return err,
                    };
                };
            },
            .gas_cost => |cost| {
                current_instruction += 1;
                // TODO we need to handle this more completely!
                if (frame.gas_remaining < cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    contract.gas = 0;
                    const run_result = RunResult.init(initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfGas, null);
                    return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
                }
                frame.gas_remaining -= cost;
            },
        }
    }

    contract.gas = frame.gas_remaining;
    const output_data = frame.output;
    const output: ?[]const u8 = if (output_data.len > 0) try self.allocator.dupe(u8, output_data) else null;

    const run_result = RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
    // Apply destructions before returning
    // TODO: Apply destructions to state
    return InterpretResult.init(self.allocator, run_result, access_list, self_destruct);
}
