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
    Log.debug("VM.interpret: Starting execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

    self.require_one_thread();

    self.depth += 1;
    defer self.depth -= 1;

    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;

    self.read_only = self.read_only or is_static;

    const initial_gas = contract.gas;

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
        .memory = try Memory.init_default(self.arena_allocator()),
        .stack = .{},
        .return_data = ReturnData.init(self.arena_allocator()),
        .vm = self,
    };
    defer frame.deinit();

    const interpreter: Operation.Interpreter = self;
    const state: Operation.State = &frame;

    var loop_iterations: usize = 0;
    const MAX_ITERATIONS = if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) 10_000_000 else std.math.maxInt(usize);
    var last_pc: usize = 0;
    var same_pc_count: usize = 0;
    
    while (frame.pc < contract.code_size) {
        @branchHint(.likely);

        // Debug infinite loops
        loop_iterations += 1;
        if (loop_iterations > MAX_ITERATIONS) {
            Log.err("interpret: Infinite loop detected after {} iterations at pc={}, opcode=0x{x:0>2}, depth={}, gas={}", .{
                loop_iterations, frame.pc, contract.get_op(frame.pc), self.depth, frame.gas_remaining
            });
            unreachable;
        }
        
        // Detect stuck at same PC
        if (frame.pc == last_pc) {
            same_pc_count += 1;
            if (same_pc_count > 1000) {
                Log.err("interpret: Stuck at pc={} for {} iterations, opcode=0x{x:0>2}", .{
                    frame.pc, same_pc_count, contract.get_op(frame.pc)
                });
                unreachable;
            }
        } else {
            last_pc = frame.pc;
            same_pc_count = 0;
        }

        const opcode = contract.get_op(frame.pc);
        
        // Log every 10000th iteration for visibility
        if (loop_iterations % 10000 == 0) {
            Log.debug("interpret: iteration {}, pc={}, opcode=0x{x:0>2}, gas={}, stack_size={}", .{
                loop_iterations, frame.pc, opcode, frame.gas_remaining, frame.stack.size
            });
        }

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
