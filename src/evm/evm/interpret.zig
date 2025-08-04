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
const tracy = @import("../tracy_support.zig");

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

    const zone = tracy.zone(@src(), "evm.handler.run");
    defer zone.end();
    Log.debug("VM.interpret: Starting execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

    self.depth += 1;
    defer self.depth -= 1;

    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;

    self.read_only = self.read_only or is_static;

    const initial_gas = contract.gas;

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
    };
    defer frame.deinit();

    const interpreter: Operation.Interpreter = self;
    const state: Operation.State = &frame;

    var instruction_count: u64 = 0;

    while (frame.pc < contract.code_size) {
        @branchHint(.likely);

        const opcode = contract.get_op(frame.pc);

        // Capture the current PC value before it can be modified
        const current_pc = frame.pc;

        // Create a zone with dynamic name matching REVM's format
        // REVM's span attributes become part of the zone name: "evm.exec{pc=XXXXX opcode=YY}"
        var zone_name_buf: [64]u8 = undefined;
        const zone_name = std.fmt.bufPrintZ(&zone_name_buf, "evm.exec{{opcode={d}}}", .{opcode}) catch "evm.exec{opcode=?}\x00";
        const opcode_zone = tracy.zoneRuntime(@src(), zone_name);
        defer opcode_zone.end();

        // Add PC and opcode as zone values (attributes in REVM terms)
        // This matches REVM's span attributes: pc = pc, opcode = opcode
        opcode_zone.Value(@as(u64, current_pc) << 32 | @as(u64, opcode));

        // Set zone text to show PC and opcode values for visual inspection
        var buf: [64]u8 = undefined;
        const zone_text = std.fmt.bufPrint(&buf, "pc={x:0>4} opcode={x:0>2}", .{ current_pc, opcode }) catch "pc=???? opcode=??";
        opcode_zone.setText(zone_text);

        // Add sampling to reduce overhead - emit trace event every 100 instructions
        instruction_count += 1;
        if (instruction_count % 100 == 0) {
            // Log message every 100 instructions like REVM
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "pc:{x:0>4} op:{x:0>2}", .{ current_pc, opcode }) catch "";
            tracy.message(msg);
        }

        // Log stack state before operation
        if (frame.stack.size > 0) {
            Log.debug("Stack before pc={}: size={}, top 5 values:", .{ frame.pc, frame.stack.size });
            var i: usize = 0;
            while (i < @min(5, frame.stack.size)) : (i += 1) {
                Log.debug("  [{}] = {}", .{ frame.stack.size - 1 - i, frame.stack.data[frame.stack.size - 1 - i] });
            }
        }

        // Trace execution if tracer is available
        if (self.tracer) |writer| {
            var tracer = @import("../tracer.zig").Tracer.init(writer);
            // Get stack slice
            const stack_slice = frame.stack.data[0..frame.stack.size];
            // Calculate gas cost for this operation
            const op_meta = self.table.get_operation(opcode);
            const gas_cost = op_meta.constant_gas;
            tracer.trace(frame.pc, opcode, stack_slice, frame.gas_remaining, gas_cost, frame.memory.size(), @intCast(self.depth)) catch |trace_err| {
                Log.debug("Failed to write trace: {}", .{trace_err});
            };
        }

        const result = self.table.execute(frame.pc, interpreter, state, opcode) catch |err| {
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

        const old_pc = frame.pc;
        if (frame.pc == old_pc) {
            Log.debug("interpret: PC unchanged by opcode - pc={}, frame.pc={}, advancing by {} bytes", .{ old_pc, frame.pc, result.bytes_consumed });
            frame.pc += result.bytes_consumed;
        } else {
            Log.debug("interpret: PC changed by opcode - old_pc={}, frame.pc={}, jumping to frame.pc", .{ old_pc, frame.pc });
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
