const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../frame/frame.zig");
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
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

/// Execute contract bytecode in read-only mode (for STATICCALL and static contexts).
pub fn interpret_block_readonly(self: *Evm, contract: *Contract, input: []const u8) ExecutionError.Error!RunResult {
    return interpret_block(self, contract, input, true);
}
/// Execute contract bytecode with write permissions (for CALL, DELEGATECALL, etc).
pub fn interpret_block_write(self: *Evm, contract: *Contract, input: []const u8) ExecutionError.Error!RunResult {
    return interpret_block(self, contract, input, false);
}

/// Execute contract bytecode using block-based execution.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Allocates instruction buffer upfront, may allocate for return data.
pub inline fn interpret_block(self: *Evm, contract: *Contract, input: []const u8, comptime is_static: bool) ExecutionError.Error!RunResult {
    Log.debug("VM.interpret_block: Starting block execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

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

    // The EVM does inner calls by recursively calling into this interpret_block method
    // Tracking depth globally like this only works because of self.require_one_thread()
    self.depth += 1;
    defer self.depth -= 1;

    // Tracking readonly globally like this only works because of self.require_one_thread()
    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;
    self.read_only = self.read_only or is_static;

    var analysis: CodeAnalysis = undefined;
    try CodeAnalysis.from_code(&analysis, contract.code[0..contract.code_size]);

    const current_instruction = try analysis.to_instructions(self.allocator, contract.code[0..contract.code_size], &self.table);

    // Allocate single frame on stack
    var frame = Frame{
        .gas_remaining = contract.gas,
        .pc = 0,
        .contract = contract,
        .allocator = self.allocator,
        .stop = false,
        .is_static = self.read_only,
        .depth = @as(u32, @intCast(self.depth)),
        .cost = 0,
        .err = null,
        .input = input,
        .output = &[_]u8{},
        .op = &.{},
        // Use arena allocation with up front allocation that should require minimal reallication for most contracts
        .memory = try Memory.init_default(self.arena_allocator()),
        .stack = .{},
        // Allocate with the normal allocator because we will be passing ownership of this when we return this
        .return_data = ReturnData.init(self.arena_allocator()),
        .vm = self,
    };
    defer frame.deinit();

    while (current_instruction[0]) |nextInstruction| {
        switch (nextInstruction.arg) {
            .jump_target => |target| {
                if (nextInstruction.opcode_fn == execution.control.op_jump) {
                    current_instruction = frame.stack.pop_unsafe();
                    if (!frame.contract.valid_jumpdest(frame.allocator, current_instruction)) {
                        return ExecutionError.Error.InvalidJump;
                    }
                }
                if (nextInstruction.opcode_fn == execution.control.op_jumpi) {
                    const dest = frame.stack.pop_unsafe();
                    const condition = frame.stack.pop_unsafe();
                    if (condition != 0) {
                        if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
                            return ExecutionError.Error.InvalidJump;
                        }
                        current_instruction = @ptrCast(target);
                    }
                }
                current_instruction = @ptrCast(target);
            },
            .push_value => |value| {
                current_instruction += 1;
                try frame.stack.append(value);
            },
            .none => {
                current_instruction += 1;
                try nextInstruction.opcode_fn(frame.pc, frame.vm, frame);
            },
            .gas_cost => |cost| {
                current_instruction += 1;
                // TODO we need to handle this more completely!
                if (frame.gas_remaining < cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= cost;
            },
        }
    }

    contract.gas = frame.gas_remaining;
    const output_data = frame.output;
    Log.debug("VM.interpret_block: Normal completion, output_size={}", .{output_data.len});
    const output: ?[]const u8 = if (output_data.len > 0) try self.allocator.dupe(u8, output_data) else null;

    Log.debug("VM.interpret_block: Execution completed, gas_used={}, output_size={}, output_ptr={any}", .{
        initial_gas - frame.gas_remaining,
        if (output) |o| o.len else 0,
        output,
    });

    return RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
}
