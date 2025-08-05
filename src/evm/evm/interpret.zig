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

    // Try to acquire a frame from the pool
    const pooled_frame = self.acquire_frame();
    var heap_frame_storage: Frame = undefined;
    var heap_allocated = false;
    
    var frame: *Frame = if (pooled_frame) |pf| pf else blk: {
        // Pool exhausted, allocate on heap
        heap_allocated = true;
        heap_frame_storage = Frame{
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
            .memory = undefined,
            .stack = .{},
            .return_data = ReturnData.init(self.allocator),
        };
        heap_frame_storage.memory = try Memory.init_default(self.allocator);
        break :blk &heap_frame_storage;
    };
    
    // Configure the frame
    frame.gas_remaining = contract.gas;
    frame.pc = 0;
    frame.contract = contract;
    frame.is_static = self.read_only;
    frame.depth = @as(u32, @intCast(self.depth));
    frame.input = input;
    
    defer {
        if (pooled_frame != null) {
            self.release_frame(frame);
        } else if (heap_allocated) {
            heap_frame_storage.deinit();
        }
    }

    const interpreter: Operation.Interpreter = self;
    const state: Operation.State = frame;

    while (frame.pc < contract.code_size) {
        @branchHint(.likely);
        const opcode = contract.get_op(frame.pc);

        const inline_hot_ops = @import("../jump_table/jump_table.zig").execute_with_inline_hot_ops;
        const result = inline_hot_ops(&self.table, frame.pc, interpreter, state, opcode) catch |err| {
            contract.gas = frame.gas_remaining;

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

            // Check most common case first with likely hint
            if (err == ExecutionError.Error.STOP) {
                @branchHint(.likely);
                // Handle normal termination inline
                // No need to reinit memory since frame is about to be destroyed
                Log.debug("VM.interpret_with_context: STOP opcode, output_size={}, creating RunResult", .{if (output) |o| o.len else 0});
                const result = RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
                Log.debug("VM.interpret_with_context: RunResult created, output={any}", .{result.output});
                return result;
            }

            // Then handle rare errors
            return switch (err) {
                ExecutionError.Error.InvalidOpcode => {
                    // INVALID opcode consumes all remaining gas
                    frame.gas_remaining = 0;
                    contract.gas = 0;
                    return RunResult.init(initial_gas, 0, .Invalid, err, output);
                },
                ExecutionError.Error.REVERT => {
                    // No need to reinit memory since frame is about to be destroyed
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
                else => return err, // Unexpected error
            };
        };

        // Optimize for common case where PC advances normally
        // Only JUMP/JUMPI/CALL family opcodes modify PC directly
        const old_pc = frame.pc;
        if (frame.pc == old_pc) {
            @branchHint(.likely);
            // Normal case - PC unchanged by opcode, advance by bytes consumed
            frame.pc += result.bytes_consumed;
            Log.debug("interpret: PC advanced by {} bytes to {}", .{ result.bytes_consumed, frame.pc });
        } else {
            @branchHint(.cold);
            // PC was modified by a jump instruction
            Log.debug("interpret: PC jumped from {} to {}", .{ old_pc, frame.pc });
        }
    }

    contract.gas = frame.gas_remaining;
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
