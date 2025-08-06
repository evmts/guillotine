const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../frame/frame.zig");
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
const Memory = @import("../memory/memory.zig");
const ReturnData = @import("return_data.zig").ReturnData;
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");
const Instruction = @import("../instruction.zig").Instruction;
const InstructionTranslator = @import("../instruction_translator.zig").InstructionTranslator;
const BlockExecutor = @import("../block_executor.zig").BlockExecutor;
const CodeAnalysis = @import("../frame/code_analysis.zig");
const instruction_limits = @import("../constants/instruction_limits.zig");

/// Execute contract bytecode using block-based execution.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Allocates instruction buffer upfront, may allocate for return data.
pub inline fn interpret_block(self: *Vm, contract: *Contract, input: []const u8, comptime is_static: bool) ExecutionError.Error!RunResult {
    Log.debug("VM.interpret_block: Starting block execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

    self.require_one_thread();


    // We track depth simply on the instance because the EVM can be expected to be syncronous
    self.depth += 1;
    defer self.depth -= 1;
    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;
    self.read_only = self.read_only or is_static;
    const initial_gas = contract.gas;

    // Analyze the bytecode (returns by value, no allocation)
    Log.debug("VM.interpret_block: Analyzing bytecode", .{});
    var analysis = try CodeAnalysis.analyze_bytecode_blocks(self.allocator, contract.code[0..contract.code_size]);
    defer analysis.deinit(self.allocator); // Only cleans up BitVec allocations
    Log.debug("VM.interpret_block: Code analysis complete", .{});

    // Use fixed-size array for instructions (no allocation)
    var instructions: [instruction_limits.MAX_INSTRUCTIONS + 1]Instruction = undefined;

    // Translate bytecode to instructions
    Log.debug("VM.interpret_block: Translating bytecode to instructions", .{});
    var translator = InstructionTranslator.init(
        contract.code[0..contract.code_size],
        &analysis,
        instructions[0..instruction_limits.MAX_INSTRUCTIONS],
        &self.table,
    );

    const instruction_count = try translator.translate_bytecode();
    Log.debug("VM.interpret_block: Translation complete, {} instructions", .{instruction_count});

    // Null-terminate the instruction stream
    instructions[instruction_count] = .{
        .opcode_fn = null,
        .arg = .none,
    };

    Log.debug("VM.interpret_block: Translated {} opcodes to {} instructions", .{ contract.code_size, instruction_count });

    // Create frame on stack
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
        .memory = try Memory.init_default(self.allocator),
        .stack = .{},
        .return_data = ReturnData.init(self.allocator),
        .vm = self,
    };
    defer frame.deinit();

    // Execute the instruction stream
    Log.debug("VM.interpret_block: Starting block execution", .{});
    const inst_ptr: [*]const Instruction = &instructions;
    BlockExecutor.execute_block(inst_ptr, &frame) catch |err| {
        contract.gas = frame.gas_remaining;

        var output: ?[]const u8 = null;
        const return_data = frame.output;
        Log.debug("VM.interpret_block: Error occurred: {}, output_size={}", .{ err, return_data.len });
        if (return_data.len > 0) {
            output = self.allocator.dupe(u8, return_data) catch {
                return RunResult.init(initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null);
            };
            Log.debug("VM.interpret_block: Duplicated output, size={}", .{output.?.len});
        }

        // Check most common case first with likely hint
        if (err == ExecutionError.Error.STOP) {
            @branchHint(.likely);
            Log.debug("VM.interpret_block: STOP opcode, output_size={}, creating RunResult", .{if (output) |o| o.len else 0});
            const result = RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
            Log.debug("VM.interpret_block: RunResult created, output={any}", .{result.output});
            return result;
        }

        // Then handle other errors
        return switch (err) {
            ExecutionError.Error.InvalidOpcode => {
                frame.gas_remaining = 0;
                contract.gas = 0;
                return RunResult.init(initial_gas, 0, .Invalid, err, output);
            },
            ExecutionError.Error.REVERT => {
                return RunResult.init(initial_gas, frame.gas_remaining, .Revert, err, output);
            },
            ExecutionError.Error.OutOfGas => {
                return RunResult.init(initial_gas, frame.gas_remaining, .OutOfGas, err, output);
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
                return RunResult.init(initial_gas, frame.gas_remaining, .Invalid, err, output);
            },
            else => return err,
        };
    };

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

/// Execute contract bytecode in read-only mode (for STATICCALL and static contexts).
pub fn interpret_block_readonly(self: *Vm, contract: *Contract, input: []const u8) ExecutionError.Error!RunResult {
    return interpret_block(self, contract, input, true);
}

/// Execute contract bytecode with write permissions (for CALL, DELEGATECALL, etc).
pub fn interpret_block_write(self: *Vm, contract: *Contract, input: []const u8) ExecutionError.Error!RunResult {
    return interpret_block(self, contract, input, false);
}
