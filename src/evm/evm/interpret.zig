const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../frame/frame.zig");
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");

/// Execute contract bytecode and return the result.
///
/// This is the main execution entry point. The contract must be properly initialized
/// with bytecode, gas limit, and input data. The VM executes opcodes sequentially
/// until completion, error, or gas exhaustion.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: May allocate for return data if contract returns output.
///
/// Example:
/// ```zig
/// var contract = Contract.init_at_address(caller, addr, 0, 100000, code, input, false);
/// defer contract.deinit(vm.allocator, null);
/// try vm.state.set_code(addr, code);
/// const result = try vm.interpret(&contract, input, false);
/// defer if (result.output) |output| vm.allocator.free(output);
/// ```
pub fn interpret(self: *Vm, contract: *Contract, input: []const u8, is_static: bool) ExecutionError.Error!RunResult {
    @branchHint(.likely);
    Log.debug("VM.interpret: Starting execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

    self.depth += 1;
    defer self.depth -= 1;

    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;

    self.read_only = self.read_only or is_static;

    const initial_gas = contract.gas;
    var pc: usize = 0;

    var builder = Frame.builder(self.allocator); // We should consider making all items mandatory and removing frame builder
    var frame = builder
        .withVm(self)
        .withContract(contract)
        .withGas(contract.gas)
        .withCaller(.{})
        .withInput(input)
        .isStatic(self.read_only)
        .withDepth(@as(u32, @intCast(self.depth)))
        .build() catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
        error.MissingVm => unreachable, // We pass a VM. TODO zig better here.
        error.MissingContract => unreachable, // We pass a contract. TODO zig better here.
    };
    defer frame.deinit();

    const interpreter: Operation.Interpreter = self;
    const state: Operation.State = &frame;

    while (pc < contract.code_size) {
        @branchHint(.likely);
        const opcode = contract.get_op(pc);
        frame.pc = pc;

        const result = self.table.execute(pc, interpreter, state, opcode) catch |err| {
            contract.gas = frame.gas_remaining;
            // Don't store frame's return data in EVM - it will be freed when frame deinits
            self.return_data = &[_]u8{};

            var output: ?[]const u8 = null;
            // Use frame.output for RETURN/REVERT data
            const return_data = frame.output;
            Log.debug("VM.interpret_with_context: Error occurred: {}, output_size={}", .{ err, return_data.len });
            if (return_data.len > 0) {
                output = self.allocator.dupe(u8, return_data) catch {
                    // We are out of memory, which is a critical failure. The safest way to
                    // handle this is to treat it as an OutOfGas error, which consumes
                    // all gas and stops execution.
                    return RunResult.init(initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null);
                };
                Log.debug("VM.interpret_with_context: Duplicated output, size={}", .{output.?.len});
            }

            return switch (err) {
                ExecutionError.Error.InvalidOpcode => {
                    @branchHint(.cold);
                    // INVALID opcode consumes all remaining gas
                    frame.gas_remaining = 0;
                    contract.gas = 0;
                    return RunResult.init(initial_gas, 0, .Invalid, err, output);
                },
                ExecutionError.Error.STOP => {
                    Log.debug("VM.interpret_with_context: STOP opcode, output_size={}, creating RunResult", .{if (output) |o| o.len else 0});
                    const result = RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
                    Log.debug("VM.interpret_with_context: RunResult created, output={any}", .{result.output});
                    return result;
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
                    @branchHint(.cold);
                    return RunResult.init(initial_gas, frame.gas_remaining, .Invalid, err, output);
                },
                else => return err, // Unexpected error
            };
        };

        if (frame.pc != pc) {
            pc = frame.pc;
        } else {
            pc += result.bytes_consumed;
        }
    }

    contract.gas = frame.gas_remaining;
    // Don't store frame's return data in EVM - it will be freed when frame deinits
    self.return_data = &[_]u8{};

    // Use frame.output for normal completion (no RETURN/REVERT was called)
    const output_data = frame.output;
    Log.debug("VM.interpret_with_context: Normal completion, output_size={}", .{output_data.len});
    const output: ?[]const u8 = if (output_data.len > 0) try self.allocator.dupe(u8, output_data) else null;

    Log.debug("VM.interpret_with_context: Execution completed, gas_used={}, output_size={}, output_ptr={any}", .{
        initial_gas - frame.gas_remaining,
        if (output) |o| o.len else 0,
        output,
    });

    return RunResult.init(
        initial_gas,
        frame.gas_remaining,
        .Success,
        null,
        output,
    );
}
