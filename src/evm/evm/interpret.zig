const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../frame/frame.zig");
const Operation = @import("../opcodes/operation.zig");
const RunResult = @import("run_result.zig").RunResult;
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");
const opcode = @import("../opcodes/opcode.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const tracy = @import("../root.zig").tracy_support;

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

    const zone = tracy.zone(@src(), "VM.interpret\x00");
    defer zone.end();

    const setup_zone = tracy.zone(@src(), "vm_setup\x00");
    Log.debug("VM.interpret: Starting execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

    self.depth += 1;
    defer self.depth -= 1;

    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;

    self.read_only = self.read_only or is_static;
    setup_zone.end();

    const initial_gas = contract.gas;
    var pc: usize = 0;

    // Always use synchronous analysis - required for threaded execution
    if (contract.analysis == null and contract.code_size > 0) {
        const analysis_zone = tracy.zone(@src(), "code_analysis\x00");
        const analysis_check_zone = tracy.zone(@src(), "analysis_check\x00");
        analysis_check_zone.end();

        const analysis_exec_zone = tracy.zone(@src(), "analysis_execution\x00");
        if (Contract.analyze_code(self.allocator, contract.code, contract.code_hash, &self.table)) |analysis| {
            contract.analysis = analysis;
        } else |err| {
            // TODO we should likely panic here
            Log.debug("Failed to analyze contract code: {}", .{err});
            // Continue without analysis - will build entries on the fly
        }
        analysis_exec_zone.end();
        analysis_zone.end();
    }

    // Get pc_to_op_entries from cached analysis if available
    var pc_to_op_entry_table = if (contract.analysis) |analysis| analysis.pc_to_op_entries else null;

    const frame_zone = tracy.zone(@src(), "frame_creation\x00");
    var builder = Frame.builder(self.allocator); // We should consider making all items mandatory and removing frame builder
    var frame = builder
        .withVm(self)
        .withContract(contract)
        .withGas(contract.gas)
        .withCaller(contract.caller)
        .withInput(input)
        .isStatic(self.read_only)
        .withDepth(@as(u32, @intCast(self.depth)))
        .build() catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
        error.MissingVm => unreachable, // We pass a VM. TODO zig better here.
        error.MissingContract => unreachable, // We pass a contract. TODO zig better here.
    };
    frame_zone.end();
    defer frame.deinit();

    // Initialize the stack's top pointer if not already initialized.
    // This is required for the pointer-based stack implementation to work correctly.
    // We do this once at the start to avoid overhead in the hot path.
    frame.stack.ensureInitialized();

    const interpreter: Operation.Interpreter = self;
    const state: Operation.State = &frame;

    // Block-level execution state
    var blocks = if (contract.analysis) |analysis| analysis.blocks else null;
    var pc_to_block_map = if (contract.analysis) |analysis| analysis.pc_to_block else null;
    var current_block_idx: ?u32 = null;
    var block_validated = false;

    // Block analysis complete - blocks available if contract.analysis exists

    // Main execution loop - the heart of the EVM
    const execution_loop_zone = tracy.zone(@src(), "execution_loop\x00");
    defer execution_loop_zone.end();

    while (pc < contract.code_size) {
        @branchHint(.likely);

        const opcode_zone = tracy.zone(@src(), "execute_opcode\x00");
        defer opcode_zone.end();

        // Check if analysis was updated by JUMP/JUMPI
        if (contract.analysis != null and pc_to_op_entry_table == null) {
            const analysis_update_zone = tracy.zone(@src(), "analysis_update\x00");
            defer analysis_update_zone.end();
            // Analysis was just applied, update our local variables
            pc_to_op_entry_table = contract.analysis.?.pc_to_op_entries;
            blocks = contract.analysis.?.blocks;
            pc_to_block_map = contract.analysis.?.pc_to_block;
        }

        // Use pre-computed entry table if available for maximum performance
        const pc_index: usize = @intCast(pc);

        const entry_lookup_zone = tracy.zone(@src(), "entry_lookup\x00");
        // TODO: Extended entries disabled temporarily due to segfault issues
        // Try extended entries first (best performance)
        const extended_entry: ?*const CodeAnalysis.ExtendedPcToOpEntry = null;

        const entry = if (extended_entry) |ext_entry|
            // Convert extended to basic format - but only if ext_entry is valid
            if (ext_entry.operation.execute != null) CodeAnalysis.PcToOpEntry{
                .operation = ext_entry.operation,
                .opcode_byte = ext_entry.opcode_byte,
                .min_stack = ext_entry.min_stack,
                .max_stack = ext_entry.max_stack,
                .constant_gas = ext_entry.constant_gas,
                .undefined = ext_entry.undefined,
            } else blk: {
                // Fallback if extended entry is invalid
                const opcode_byte = contract.code[pc_index];
                const operation = self.table.table[opcode_byte];
                break :blk CodeAnalysis.PcToOpEntry{
                    .operation = operation,
                    .opcode_byte = opcode_byte,
                    .min_stack = operation.min_stack,
                    .max_stack = operation.max_stack,
                    .constant_gas = operation.constant_gas,
                    .undefined = operation.undefined,
                };
            }
        else if (pc_to_op_entry_table) |table|
            table[pc_index]
        else blk: {
            // Fallback: build entry on the fly
            const opcode_byte = contract.code[pc_index];
            const operation = self.table.table[opcode_byte];
            break :blk CodeAnalysis.PcToOpEntry{
                .operation = operation,
                .opcode_byte = opcode_byte,
                .min_stack = operation.min_stack,
                .max_stack = operation.max_stack,
                .constant_gas = operation.constant_gas,
                .undefined = operation.undefined,
            };
        };
        entry_lookup_zone.end();

        const operation = entry.operation;
        const opcode_byte = entry.opcode_byte;

        frame.pc = pc;

        // Block-level validation and gas consumption
        if (pc_to_block_map) |map| {
            const block_validation_zone = tracy.zone(@src(), "block_validation\x00");
            defer block_validation_zone.end();

            if (pc_index < map.len) {
                const block_check_zone = tracy.zone(@src(), "block_check\x00");
                const block_idx = map[pc_index];
                block_check_zone.end();

                if (block_idx != std.math.maxInt(u32)) {
                    // Check if we're entering a new block
                    if (current_block_idx == null or current_block_idx.? != block_idx) {
                        const new_block_zone = tracy.zone(@src(), "new_block_entry\x00");
                        current_block_idx = block_idx;
                        block_validated = false;

                        // Validate and consume gas for the entire block
                        if (blocks) |block_array| {
                            if (block_idx < block_array.len) {
                                const block = block_array[block_idx];
                                // Block validation: checking stack and gas requirements

                                // Validate stack requirements for the block
                                const stack_validation_zone = tracy.zone(@src(), "block_stack_validation\x00");
                                const stack_size = @as(i32, @intCast(frame.stack.size()));
                                if (stack_size < block.stack_req) {
                                    stack_validation_zone.end();
                                    // Stack underflow detected
                                    contract.gas = frame.gas_remaining;
                                    self.return_data = &[_]u8{};
                                    return RunResult.init(initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.StackUnderflow, null);
                                }

                                const max_stack_after = stack_size + @as(i32, @intCast(block.stack_max_growth));
                                if (max_stack_after > @import("../stack/stack.zig").CAPACITY) {
                                    stack_validation_zone.end();
                                    // Stack overflow would occur
                                    contract.gas = frame.gas_remaining;
                                    self.return_data = &[_]u8{};
                                    return RunResult.init(initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.StackOverflow, null);
                                }
                                stack_validation_zone.end();

                                // Consume gas for the entire block
                                const gas_zone = tracy.zone(@src(), "block_gas_consumption\x00");
                                frame.consume_gas(block.gas_cost) catch {
                                    gas_zone.end();
                                    // Out of gas detected
                                    contract.gas = frame.gas_remaining;
                                    self.return_data = &[_]u8{};
                                    return RunResult.init(initial_gas, frame.gas_remaining, .OutOfGas, ExecutionError.Error.OutOfGas, null);
                                };
                                gas_zone.end();

                                block_validated = true;
                                // Block validation successful
                            }
                        }
                        new_block_zone.end();
                    }
                }
            }
        }

        // FAST PATH: Execute entire validated block without per-instruction checks
        if (block_validated and blocks != null and current_block_idx != null and contract.analysis != null) {
            const fast_path_zone = tracy.zone(@src(), "fast_path_execution\x00");
            defer fast_path_zone.end();

            const block = blocks.?[current_block_idx.?];
            const block_end_pc = block.end_pc;

            // Check if this block is eligible for fast path execution and has extended entries
            const analysis = contract.analysis.?;
            // TODO: Fast path disabled temporarily due to extended_entries segfault
            if (false and block.only_hot_opcodes and !block.has_external_calls and !block.has_dynamic_jumps and analysis.extended_entries != null) {
                // Fast path execution for validated block

                const extended_entries = analysis.extended_entries.?;

                // Fast execution loop with NO runtime checks
                while (pc <= block_end_pc) {
                    @branchHint(.likely);

                    if (pc >= contract.code_size) break;

                    const pc_index_fast: usize = @intCast(pc);

                    // Safety check for extended entries bounds
                    if (pc_index_fast >= extended_entries.len) {
                        // Extended entries bounds exceeded, fallback to slow path
                        break;
                    }

                    const ext_entry = &extended_entries[pc_index_fast];
                    const opcode_byte_fast = ext_entry.opcode_byte;

                    // No gas check - already validated for entire block
                    // No stack validation - already validated for entire block
                    // No analysis updates - blocks are immutable

                    // Execute opcode directly without validation

                    // Direct dispatch with inlined hot opcodes
                    // No fallback - only blocks with ONLY these opcodes use fast path
                    switch (opcode_byte_fast) {
                        0x01 => { // ADD
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(a +% b);
                            pc += 1;
                        },
                        0x03 => { // SUB
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(a -% b);
                            pc += 1;
                        },
                        0x02 => { // MUL
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(a *% b);
                            pc += 1;
                        },
                        0x16 => { // AND
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(a & b);
                            pc += 1;
                        },
                        0x17 => { // OR
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(a | b);
                            pc += 1;
                        },
                        0x18 => { // XOR
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(a ^ b);
                            pc += 1;
                        },
                        0x10 => { // LT
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(if (a < b) 1 else 0);
                            pc += 1;
                        },
                        0x11 => { // GT
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(if (a > b) 1 else 0);
                            pc += 1;
                        },
                        0x14 => { // EQ
                            const b = frame.stack.pop_unsafe();
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(if (a == b) 1 else 0);
                            pc += 1;
                        },
                        0x15 => { // ISZERO
                            const a = frame.stack.peek_unsafe().*;
                            frame.stack.set_top_unsafe(if (a == 0) 1 else 0);
                            pc += 1;
                        },
                        0x60 => { // PUSH1
                            const value: u256 = if (pc + 1 < contract.code.len) contract.code[pc + 1] else 0;
                            frame.stack.append_unsafe(value);
                            pc += 2;
                        },
                        0x61 => { // PUSH2
                            var value: u256 = 0;
                            if (pc + 1 < contract.code.len) value |= @as(u256, contract.code[pc + 1]) << 8;
                            if (pc + 2 < contract.code.len) value |= contract.code[pc + 2];
                            frame.stack.append_unsafe(value);
                            pc += 3;
                        },
                        0x80 => { // DUP1
                            const value = frame.stack.peek_unsafe().*;
                            frame.stack.append_unsafe(value);
                            pc += 1;
                        },
                        0x90 => { // SWAP1
                            const top = frame.stack.data[frame.stack.size() - 1];
                            const second = frame.stack.data[frame.stack.size() - 2];
                            frame.stack.data[frame.stack.size() - 1] = second;
                            frame.stack.data[frame.stack.size() - 2] = top;
                            pc += 1;
                        },
                        0x00 => { // STOP
                            contract.gas = frame.gas_remaining;
                            self.return_data = &[_]u8{};
                            return RunResult.init(initial_gas, frame.gas_remaining, .Success, null, null);
                        },
                        else => unreachable, // Block analysis ensures only compatible opcodes
                    }

                    // Check if we've completed the block
                    if (pc > block_end_pc) {
                        block_validated = false; // Need revalidation after block exit
                        // Fast path block execution completed
                        continue; // Continue to next iteration of main loop
                    }
                }

                // Fast path completed the entire block
                block_validated = false;
                continue; // Skip slow path entirely
            }
        }

        // SLOW PATH: Original execution with full validation
        // Execute the operation directly
        const exec_result = exec_blk: {
            const execution_zone = tracy.zone(@src(), "opcode_execution\x00");
            defer execution_zone.end();

            Log.debug("Executing opcode 0x{x:0>2} at pc={}, gas={}, stack_size={}", .{ opcode_byte, pc, frame.gas_remaining, frame.stack.size() });

            // Check if opcode is undefined (cold path) - use pre-computed flag
            if (entry.undefined) {
                @branchHint(.cold);
                const invalid_zone = tracy.zone(@src(), "invalid_opcode\x00");
                defer invalid_zone.end();
                Log.debug("Invalid opcode 0x{x:0>2}", .{opcode_byte});
                frame.gas_remaining = 0;
                break :exec_blk ExecutionError.Error.InvalidOpcode;
            }

            // Skip per-instruction validation if block is validated
            if (!block_validated) {
                const validation_zone = tracy.zone(@src(), "per_instruction_validation\x00");
                defer validation_zone.end();

                // Validate stack requirements using pre-computed values
                const stack_check_zone = tracy.zone(@src(), "stack_requirements_check\x00");
                if (comptime builtin.mode == .ReleaseFast) {
                    // Fast path for release builds - use pre-computed min/max
                    const stack_height_changes = @import("../opcodes/stack_height_changes.zig");
                    stack_height_changes.validate_stack_requirements_fast(
                        @intCast(frame.stack.size()),
                        opcode_byte,
                        entry.min_stack,
                        entry.max_stack,
                    ) catch |err| {
                        stack_check_zone.end();
                        break :exec_blk err;
                    };
                } else {
                    // Full validation for debug builds
                    const stack_validation = @import("../stack/stack_validation.zig");
                    stack_validation.validate_stack_requirements(&frame.stack, operation) catch |err| {
                        stack_check_zone.end();
                        break :exec_blk err;
                    };
                }
                stack_check_zone.end();

                // Consume gas (likely path) - use pre-computed constant_gas
                if (entry.constant_gas > 0) {
                    @branchHint(.likely);
                    const gas_zone = tracy.zone(@src(), "consume_gas\x00");
                    const gas_check_zone = tracy.zone(@src(), "gas_check\x00");
                    gas_check_zone.end();
                    Log.debug("Consuming {} gas for opcode 0x{x:0>2}", .{ entry.constant_gas, opcode_byte });
                    frame.consume_gas(entry.constant_gas) catch |err| {
                        gas_zone.end();
                        break :exec_blk err;
                    };
                    gas_zone.end();
                }
            }

            // Execute the operation
            const opcode_exec_zone = tracy.zone(@src(), "opcode_function_call\x00");
            const res = operation.execute(pc, interpreter, state) catch |err| {
                opcode_exec_zone.end();
                break :exec_blk err;
            };
            opcode_exec_zone.end();
            Log.debug("Opcode 0x{x:0>2} completed, gas_remaining={}", .{ opcode_byte, frame.gas_remaining });
            break :exec_blk res;
        };

        // Handle execution result
        const result_handling_zone = tracy.zone(@src(), "result_handling\x00");
        defer result_handling_zone.end();

        if (exec_result) |result| {
            // Success case - update program counter
            const pc_update_zone = tracy.zone(@src(), "pc_update\x00");
            if (frame.pc != pc) {
                Log.debug("PC changed by opcode - old_pc={}, frame.pc={}, jumping to frame.pc", .{ pc, frame.pc });
                pc = frame.pc;
            } else {
                // Use extended entry size if available (more accurate for PUSH)
                const bytes_to_consume = if (extended_entry) |ext_entry| ext_entry.size else result.bytes_consumed;
                Log.debug("PC unchanged by opcode - pc={}, frame.pc={}, advancing by {} bytes", .{ pc, frame.pc, bytes_to_consume });
                pc += bytes_to_consume;
            }
            pc_update_zone.end();
        } else |err| {
            const error_handling_zone = tracy.zone(@src(), "error_handling\x00");
            defer error_handling_zone.end();
            // Error case - handle various error conditions
            contract.gas = frame.gas_remaining;
            // Don't store frame's return data in EVM - it will be freed when frame deinits
            self.return_data = &[_]u8{};

            var output: ?[]const u8 = null;
            // Use frame.output for RETURN/REVERT data
            const return_data = frame.output;
            Log.debug("VM.interpret_with_context: Error occurred: {}, output_size={}", .{ err, return_data.len });
            if (return_data.len > 0) {
                const output_zone = tracy.zone(@src(), "output_duplication\x00");
                output = self.allocator.dupe(u8, return_data) catch {
                    output_zone.end();
                    // We are out of memory, which is a critical failure. The safest way to
                    // handle this is to treat it as an OutOfGas error, which consumes
                    // all gas and stops execution.
                    return RunResult.init(initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null);
                };
                output_zone.end();
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
        }
    }

    const cleanup_zone = tracy.zone(@src(), "vm_cleanup\x00");
    contract.gas = frame.gas_remaining;
    // Don't store frame's return data in EVM - it will be freed when frame deinits
    self.return_data = &[_]u8{};

    // Use frame.output for normal completion (no RETURN/REVERT was called)
    const output_data = frame.output;
    Log.debug("VM.interpret_with_context: Normal completion, output_size={}", .{output_data.len});
    const output: ?[]const u8 = if (output_data.len > 0) try self.allocator.dupe(u8, output_data) else null;
    cleanup_zone.end();

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

/// Execute using threaded code (indirect call threading)
fn interpretThreaded(
    self: *Vm,
    contract: *Contract,
    input: []const u8,
    is_static: bool,
) ExecutionError.Error!RunResult {
    const threaded_analysis = @import("../frame/threaded_analysis.zig");

    // Ensure threaded analysis is available
    if (contract.threaded_analysis == null and contract.code_size > 0) {
        contract.threaded_analysis = try threaded_analysis.analyzeThreaded(
            self.allocator,
            contract.code,
            contract.code_hash,
            &self.table,
        );
    }

    const analysis = contract.threaded_analysis orelse return ExecutionError.Error.InvalidOpcode;

    const initial_gas = contract.gas;
    self.depth += 1;
    defer self.depth -= 1;

    const prev_read_only = self.read_only;
    defer self.read_only = prev_read_only;

    self.read_only = self.read_only or is_static;

    // Create frame with threaded execution context
    var builder = Frame.builder(self.allocator);
    var frame = builder
        .withVm(self)
        .withContract(contract)
        .withGas(contract.gas)
        .withCaller(contract.caller)
        .withInput(input)
        .isStatic(self.read_only)
        .withDepth(@as(u32, @intCast(self.depth)))
        .build() catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
        error.MissingVm => unreachable,
        error.MissingContract => unreachable,
    };
    defer frame.deinit();

    // Set threaded execution fields
    frame.instructions = analysis.instructions;
    frame.push_values = analysis.push_values;
    frame.jumpdest_map = &analysis.jumpdest_map;
    frame.current_block_gas = 0;
    frame.return_reason = .Continue;

    // Initialize stack
    frame.stack.ensureInitialized();

    // CRITICAL: The threaded execution loop - just 3 lines!
    var instr: ?*const @import("../frame/threaded_instruction.zig").ThreadedInstruction = &analysis.instructions[0];
    while (instr) |current| {
        instr = current.exec_fn(current, &frame);
    }

    // Handle results based on return reason
    contract.gas = frame.gas_remaining;
    self.return_data = &[_]u8{};

    const output_data = frame.output;
    const output: ?[]const u8 = if (output_data.len > 0)
        try self.allocator.dupe(u8, output_data)
    else
        null;

    return RunResult.init(
        initial_gas,
        frame.gas_remaining,
        switch (frame.return_reason) {
            .Stop, .Return => .Success,
            .Revert => .Revert,
            .OutOfGas => .OutOfGas,
            else => .Invalid,
        },
        switch (frame.return_reason) {
            .Stop => null,
            .Return => null,
            .Revert => ExecutionError.Error.REVERT,
            .OutOfGas => ExecutionError.Error.OutOfGas,
            else => ExecutionError.Error.InvalidOpcode,
        },
        output,
    );
}

// TODO: Fast path tests removed temporarily - will be re-added when fast path is re-enabled

test "verify blocks are created and analysis works" {
    const allocator = std.testing.allocator;

    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Very simple code: PUSH1 1 PUSH1 2 ADD STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    var contract = try Contract.init(allocator, &code, .{ .address = @import("Address").ZERO });
    defer contract.deinit(allocator, null);

    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);

    // Verify execution completed successfully
    try std.testing.expectEqual(@as(RunResult.Status, .Success), result.status);

    // Verify analysis was created
    try std.testing.expect(contract.analysis != null);
    if (contract.analysis) |analysis| {
        // Verify blocks were created
        try std.testing.expect(analysis.blocks != null);
    }
}
