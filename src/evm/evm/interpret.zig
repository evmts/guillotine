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

    // Always use synchronous analysis - required for threaded execution
    if (contract.analysis == null and contract.code_size > 0) {
        if (Contract.analyze_code(self.allocator, contract.code, contract.code_hash, &self.table)) |analysis| {
            contract.analysis = analysis;
        } else |err| {
            Log.debug("Failed to analyze contract code: {}", .{err});
            // Continue without analysis - will build entries on the fly
        }
    }
    
    // Get pc_to_op_entries from cached analysis if available
    var pc_to_op_entry_table = if (contract.analysis) |analysis| analysis.pc_to_op_entries else null;

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


    // Main execution loop - the heart of the EVM
    while (pc < contract.code_size) {
        @branchHint(.likely);
        
        // Check if analysis was updated by JUMP/JUMPI
        if (contract.analysis != null and pc_to_op_entry_table == null) {
            // Analysis was just applied, update our local variables
            pc_to_op_entry_table = contract.analysis.?.pc_to_op_entries;
            blocks = contract.analysis.?.blocks;
            pc_to_block_map = contract.analysis.?.pc_to_block;
        }
        
        // Use pre-computed entry table if available for maximum performance
        const pc_index: usize = @intCast(pc);
        const entry = if (pc_to_op_entry_table) |table| 
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
        
        const operation = entry.operation;
        const opcode_byte = entry.opcode_byte;
        
        frame.pc = pc;
        
        // Block-level validation and gas consumption
        if (pc_to_block_map) |map| {
            if (pc_index < map.len) {
                const block_idx = map[pc_index];
                if (block_idx != std.math.maxInt(u32)) {
                    // Check if we're entering a new block
                    if (current_block_idx == null or current_block_idx.? != block_idx) {
                        current_block_idx = block_idx;
                        block_validated = false;
                        
                        // Validate and consume gas for the entire block
                        if (blocks) |block_array| {
                            if (block_idx < block_array.len) {
                                const block = block_array[block_idx];
                                Log.debug("Entering block {} at pc={}, gas_cost={}, stack_req={}, stack_max_growth={}, start_pc={}, end_pc={}", .{ block_idx, pc, block.gas_cost, block.stack_req, block.stack_max_growth, block.start_pc, block.end_pc });
                                
                                // Validate stack requirements for the block
                                const stack_size = @as(i32, @intCast(frame.stack.size()));
                                if (stack_size < block.stack_req) {
                                    Log.debug("Block {} stack underflow: size={}, required={}, start_pc={}, end_pc={}", .{ block_idx, stack_size, block.stack_req, block.start_pc, block.end_pc });
                                    contract.gas = frame.gas_remaining;
                                    self.return_data = &[_]u8{};
                                    return RunResult.init(initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.StackUnderflow, null);
                                }
                                
                                const max_stack_after = stack_size + @as(i32, @intCast(block.stack_max_growth));
                                if (max_stack_after > @import("../stack/stack.zig").CAPACITY) {
                                    Log.debug("Block {} would overflow stack: current={}, max_growth={}", .{ block_idx, stack_size, block.stack_max_growth });
                                    contract.gas = frame.gas_remaining;
                                    self.return_data = &[_]u8{};
                                    return RunResult.init(initial_gas, frame.gas_remaining, .Invalid, ExecutionError.Error.StackOverflow, null);
                                }
                                
                                // Consume gas for the entire block
                                frame.consume_gas(block.gas_cost) catch {
                                    Log.debug("Block {} out of gas: cost={}, remaining={}", .{ block_idx, block.gas_cost, frame.gas_remaining });
                                    contract.gas = frame.gas_remaining;
                                    self.return_data = &[_]u8{};
                                    return RunResult.init(initial_gas, frame.gas_remaining, .OutOfGas, ExecutionError.Error.OutOfGas, null);
                                };
                                
                                block_validated = true;
                                Log.debug("Block {} validated successfully", .{block_idx});
                            }
                        }
                    }
                }
            }
        }
        
        // INLINE: self.table.execute(...)
        // Execute the operation directly
        const exec_result = exec_blk: {
            Log.debug("Executing opcode 0x{x:0>2} at pc={}, gas={}, stack_size={}", .{ opcode_byte, pc, frame.gas_remaining, frame.stack.size() });
            
            // Check if opcode is undefined (cold path) - use pre-computed flag
            if (entry.undefined) {
                @branchHint(.cold);
                Log.debug("Invalid opcode 0x{x:0>2}", .{opcode_byte});
                frame.gas_remaining = 0;
                break :exec_blk ExecutionError.Error.InvalidOpcode;
            }
            
            // Skip per-instruction validation if block is validated
            if (!block_validated) {
                // Validate stack requirements using pre-computed values
                if (comptime builtin.mode == .ReleaseFast) {
                    // Fast path for release builds - use pre-computed min/max
                    const stack_height_changes = @import("../opcodes/stack_height_changes.zig");
                    stack_height_changes.validate_stack_requirements_fast(
                        @intCast(frame.stack.size()),
                        opcode_byte,
                        entry.min_stack,
                        entry.max_stack,
                    ) catch |err| break :exec_blk err;
                } else {
                    // Full validation for debug builds
                    const stack_validation = @import("../stack/stack_validation.zig");
                    stack_validation.validate_stack_requirements(&frame.stack, operation) catch |err| break :exec_blk err;
                }
                
                // Consume gas (likely path) - use pre-computed constant_gas
                if (entry.constant_gas > 0) {
                    @branchHint(.likely);
                    Log.debug("Consuming {} gas for opcode 0x{x:0>2}", .{ entry.constant_gas, opcode_byte });
                    frame.consume_gas(entry.constant_gas) catch |err| break :exec_blk err;
                }
            }
            
            // Execute the operation
            const res = operation.execute(pc, interpreter, state) catch |err| break :exec_blk err;
            Log.debug("Opcode 0x{x:0>2} completed, gas_remaining={}", .{ opcode_byte, frame.gas_remaining });
            break :exec_blk res;
        };
        
        // Handle execution result
        if (exec_result) |result| {
            // Success case - update program counter
            if (frame.pc != pc) {
                Log.debug("PC changed by opcode - old_pc={}, frame.pc={}, jumping to frame.pc", .{ pc, frame.pc });
                pc = frame.pc;
            } else {
                Log.debug("PC unchanged by opcode - pc={}, frame.pc={}, advancing by {} bytes", .{ pc, frame.pc, result.bytes_consumed });
                pc += result.bytes_consumed;
            }
        } else |err| {
            // Error case - handle various error conditions
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