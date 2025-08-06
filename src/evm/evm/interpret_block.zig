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

/// Execute contract bytecode using block-based execution.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality. Falls back to regular
/// interpretation for edge cases.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Allocates instruction buffer upfront, may allocate for return data.
pub fn interpret_block(self: *Vm, contract: *Contract, input: []const u8, is_static: bool) ExecutionError.Error!RunResult {
    Log.debug("VM.interpret_block: Starting block execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

    self.require_one_thread();

    // For very small contracts, fall back to regular interpretation
    // TODO we need to benchmark and tune this
    if (contract.code_size < 32) {
        Log.debug("VM.interpret_block: Contract too small for block execution, falling back to regular", .{});
        // TODO we need to rename this
        return self.interpret(contract, input, is_static);
    }

    // We track depth simply on the instance because the EVM can be expected to be syncronous
    self.depth += 1;
    defer self.depth -= 1;
    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;
    self.read_only = self.read_only or is_static;
    const initial_gas = contract.gas;

    // Analyze the bytecode
    Log.debug("VM.interpret_block: Analyzing bytecode", .{});
    var analysis = CodeAnalysis.analyze_bytecode_blocks(self.allocator, contract.code[0..contract.code_size]) catch |err| {
        Log.debug("VM.interpret_block: Code analysis failed with {}, falling back to regular", .{err});
        return self.interpret(contract, input, is_static);
    };
    defer analysis.deinit(self.allocator);
    Log.debug("VM.interpret_block: Code analysis complete", .{});

    const max_instructions = contract.code_size * 2; // Conservative estimate
    const instructions = self.allocator.alloc(Instruction, max_instructions + 1) catch {
        Log.debug("VM.interpret_block: Instruction allocation failed, falling back to regular", .{});
        return self.interpret(contract, input, is_static);
    };
    defer self.allocator.free(instructions);

    // Translate bytecode to instructions
    Log.debug("VM.interpret_block: Translating bytecode to instructions", .{});
    var translator = InstructionTranslator.init(
        self.allocator,
        contract.code[0..contract.code_size],
        &analysis,
        instructions[0..max_instructions],
        &self.table,
    );

    const instruction_count = translator.translate_bytecode() catch |err| {
        Log.debug("VM.interpret_block: Translation failed with {}, falling back to regular", .{err});
        return self.interpret(contract, input, is_static);
    };
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
    const inst_ptr: [*]const Instruction = instructions.ptr;
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
