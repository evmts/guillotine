const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
const InterpretResult = @import("interpret_result.zig").InterpretResult;
const AccessList = @import("../access_list.zig").AccessList;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const ChainRules = @import("../frame.zig").ChainRules;
const Memory = @import("../memory/memory.zig");
const ReturnData = @import("return_data.zig").ReturnData;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const Contract = Evm.Contract;
const primitives = @import("primitives");
const execution = @import("../execution/package.zig");
const Instruction = @import("../instruction.zig").Instruction;
const CodeAnalysis = @import("../analysis.zig");
const instruction_limits = @import("../constants/instruction_limits.zig");
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;
const builtin = @import("builtin");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const MAX_ITERATIONS = 10_000_000; // TODO set this to a real problem

// Threshold for stack vs heap allocation optimization
const STACK_ALLOCATION_THRESHOLD = 12800; // bytes of bytecode
// Maximum stack buffer size for contracts up to 12,800 bytes
// Calculated for worst case: 12,800 bytes of PUSH32 instructions = ~400 instructions
// Instructions: 400 * 32 bytes = ~12.8KB
// Bitmaps: 2 * (12,800/8) = 3.2KB
// PC mapping: 12,800 * 2 = 25.6KB
// Total with padding: ~42KB
const MAX_STACK_BUFFER_SIZE = 43008; // 42KB with alignment padding

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
    {
        self.require_one_thread();
        if (contract.input.len > MAX_INPUT_SIZE) return ExecutionError.Error.InputSizeExceeded;
        if (contract.code_size > MAX_CODE_SIZE) return ExecutionError.Error.MaxCodeSizeExceeded;
        if (contract.code_size != contract.code.len) return ExecutionError.Error.CodeSizeMismatch;
        if (contract.gas == 0) return ExecutionError.Error.OutOfGas;
        if (contract.code_size > 0 and contract.code.len == 0) return ExecutionError.Error.CodeSizeMismatch;
    }

    const initial_gas = contract.gas;

    // Do analysis on stack if contract is small
    var stack_buffer: [MAX_STACK_BUFFER_SIZE]u8 = undefined;
    const analysis_allocator = if (contract.code_size <= STACK_ALLOCATION_THRESHOLD)
        std.heap.FixedBufferAllocator.init(&stack_buffer)
    else
        self.allocator;
    var analysis = try CodeAnalysis.from_code(analysis_allocator, contract.code[0..contract.code_size], &self.table);
    defer analysis.deinit();

    var current_instruction = analysis.instructions;

    // Use normal passed in allocator since we will be returning allocated data back to caller
    var access_list = AccessList.init(self.allocator);
    var self_destruct = SelfDestruct.init(self.allocator);

    var frame = try Frame.init(
        self.arena_allocator(),
        contract.gas,
        is_static,
        @as(u32, @intCast(self.depth)),
        contract.address,
        &analysis,
        &access_list,
        self.state,
        ChainRules{},
        &self_destruct,
        input,
    );
    defer frame.deinit();

    var loop_iterations: usize = 0;

    while (current_instruction[0]) |nextInstruction| {
        @branchHint(.likely);

        // In safe mode we make sure we don't loop too much. If this happens
        if (comptime SAFE) {
            loop_iterations += 1;
            if (loop_iterations > MAX_ITERATIONS) {
                Log.err("interpret: Infinite loop detected after {} iterations at pc={}, depth={}, gas={}. This should never happen and indicates either the limit was set too low or a high severity bug has been found in EVM", .{ loop_iterations, current_instruction - analysis.instructions, self.depth, frame.gas_remaining });
                unreachable;
            }
        }

        // Handle instruction
        switch (nextInstruction.arg) {
            // BEGINBLOCK instructions - validate entire basic block upfront
            // This eliminates per-instruction gas and stack validation for the entire block
            .block_info => {
                current_instruction += 1;
                nextInstruction.opcode_fn(@ptrCast(&frame)) catch |err| {
                    contract.gas = frame.gas_remaining;
                    return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .Invalid, err, null, access_list, self_destruct);
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
                        if (!frame.valid_jumpdest(dest)) return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.InvalidJump, null, access_list, self_destruct);
                        current_instruction = @ptrCast(jump_target.instruction);
                    },
                    .jumpi => {
                        const pops = frame.stack.pop2_unsafe();
                        const dest = pops.a;
                        const condition = pops.b;
                        if (condition != 0) {
                            if (!frame.valid_jumpdest(dest)) {
                                contract.gas = frame.gas_remaining;
                                return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.InvalidJump, null, access_list, self_destruct);
                            }
                            current_instruction = @ptrCast(jump_target.instruction);
                        } else {
                            current_instruction += 1;
                        }
                    },
                    .other => {
                        current_instruction = @ptrCast(jump_target.instruction);
                    },
                }
            },
            .push_value => |value| {
                current_instruction += 1;
                try frame.stack.append(value);
            },
            .none => {
                @branchHint(.likely);
                // Most opcodes now have .none - no individual gas/stack validation needed
                // Gas and stack validation is handled by BEGINBLOCK instructions
                current_instruction += 1;
                nextInstruction.opcode_fn(@ptrCast(&frame)) catch |err| {
                    contract.gas = frame.gas_remaining;

                    var output: ?[]const u8 = null;
                    const return_data = frame.output;
                    if (return_data.len > 0) {
                        output = self.allocator.dupe(u8, return_data) catch {
                            return InterpretResult.init(self.allocator, initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null, access_list, self_destruct);
                        };
                    }

                    if (err == ExecutionError.Error.STOP) {
                        @branchHint(.likely);
                        // Apply destructions before returning
                        // TODO: Apply destructions to state
                        return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .Success, null, output, access_list, self_destruct);
                    }

                    return switch (err) {
                        ExecutionError.Error.InvalidOpcode => {
                            frame.gas_remaining = 0;
                            contract.gas = 0;
                            return InterpretResult.init(self.allocator, initial_gas, 0, .Invalid, err, output, access_list, self_destruct);
                        },
                        ExecutionError.Error.REVERT => {
                            return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .Revert, err, output, access_list, self_destruct);
                        },
                        ExecutionError.Error.OutOfGas => {
                            return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .OutOfGas, err, output, access_list, self_destruct);
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
                            return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .Invalid, err, output, access_list, self_destruct);
                        },
                        else => return err,
                    };
                };
            },
            .gas_cost => |cost| {
                // Keep for special opcodes that need individual gas tracking (GAS, CALL, etc.)
                current_instruction += 1;
                if (frame.gas_remaining < cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    contract.gas = 0;
                    return InterpretResult.init(self.allocator, initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfGas, null, access_list, self_destruct);
                }
                frame.gas_remaining -= cost;
            },
        }
    }

    contract.gas = frame.gas_remaining;
    const output_data = frame.output;
    const output: ?[]const u8 = if (output_data.len > 0) try self.allocator.dupe(u8, output_data) else null;

    // Apply destructions before returning
    // TODO: Apply destructions to state
    return InterpretResult.init(self.allocator, initial_gas, frame.gas_remaining, .Success, null, output, access_list, self_destruct);
}
