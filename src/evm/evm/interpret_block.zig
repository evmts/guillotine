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
const batch_validation = @import("../jump_table/batch_validation.zig");
const fast_block = @import("../jump_table/fast_block.zig");

/// Execute contract bytecode using block-based optimization.
///
/// This optimized interpreter validates and consumes gas for entire basic blocks
/// at once, reducing overhead compared to per-instruction validation.
///
/// The optimization works by:
/// 1. Pre-validating gas and stack requirements for the entire block
/// 2. Executing all instructions in the block without per-instruction checks
/// 3. Handling block transitions (jumps, returns, etc.)
///
/// This matches EVMOne's approach of batch validation for performance gains.
pub fn interpret_block(self: *Vm, contract: *Contract, input: []const u8, is_static: bool) ExecutionError.Error!RunResult {
    @branchHint(.likely);

    const zone = tracy.zone(@src(), "evm.handler.run_block");
    defer zone.end();
    Log.debug("VM.interpret_block: Starting block-based execution, depth={}, gas={}, static={}, code_size={}, input_size={}", .{ self.depth, contract.gas, is_static, contract.code_size, input.len });

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
        .block_mode = true, // Enable block-based execution
    };
    defer frame.deinit();

    const interpreter: Operation.Interpreter = self;
    const state: Operation.State = &frame;

    // Get code analysis with block metadata
    const analysis = contract.analysis orelse {
        // Fall back to regular interpreter if no block analysis available
        Log.debug("VM.interpret_block: No block analysis available, falling back to regular interpreter", .{});
        return @import("interpret.zig").interpret(self, contract, input, is_static);
    };

    // Check if we have block metadata
    if (analysis.block_metadata.len == 0) {
        // Fall back to regular interpreter if no block metadata
        Log.debug("VM.interpret_block: No block metadata available, falling back to regular interpreter", .{});
        return @import("interpret.zig").interpret(self, contract, input, is_static);
    }

    var current_block: u16 = 0;
    var instruction_count: u64 = 0;

    while (frame.pc < contract.code_size) {
        @branchHint(.likely);

        // Get current block index from PC
        if (frame.pc < analysis.pc_to_block.len) {
            const new_block = analysis.pc_to_block[frame.pc];
            if (new_block != current_block) {
                current_block = new_block;
                Log.debug("VM.interpret_block: Entering block {}, pc={}", .{ current_block, frame.pc });
            }
        }

        // Validate block requirements once at block entry
        if (current_block < analysis.block_metadata.len) {
            const block = &analysis.block_metadata[current_block];
            
            // Check if this is a block boundary (first instruction of block)
            if (frame.pc == 0 or (frame.pc > 0 and frame.pc < analysis.block_starts.size and analysis.block_starts.isSetUnchecked(frame.pc))) {
                // Batch validation for the entire block
                batch_validation.validate_block(&frame, block) catch |err| {
                    Log.debug("VM.interpret_block: Block validation failed: {}", .{err});
                    contract.gas = frame.gas_remaining;
                    return RunResult.init(initial_gas, frame.gas_remaining, .Invalid, err, null);
                };
                
                // Consume gas for entire block upfront
                batch_validation.consume_block_gas(&frame, block);
                Log.debug("VM.interpret_block: Block {} validated and gas consumed: {} gas", .{ current_block, block.gas_cost });
                
                // Check if this block can use fast path
                var block_end = frame.contract.code_size;
                if (current_block + 1 < analysis.block_metadata.len) {
                    // Find start of next block
                    var pc_scan = frame.pc + 1;
                    while (pc_scan < analysis.pc_to_block.len) : (pc_scan += 1) {
                        if (analysis.pc_to_block[pc_scan] != current_block) {
                            block_end = pc_scan;
                            break;
                        }
                    }
                }
                
                if (fast_block.can_use_fast_path(frame.contract.code, frame.pc, block_end)) {
                    Log.debug("VM.interpret_block: Using fast path for block {} (pc {} to {})", .{ current_block, frame.pc, block_end });
                    try fast_block.execute_fast_block(&frame, interpreter, &self.table, block_end);
                    continue; // Skip to next iteration
                }
            }
        }

        const opcode = contract.get_op(frame.pc);
        const current_pc = frame.pc;

        // Execute the opcode WITHOUT per-instruction validation
        // This is safe because block validation already checked requirements
        const operation_ptr = self.table.get_operation(opcode);
        
        if (operation_ptr.undefined) {
            @branchHint(.cold);
            Log.debug("VM.interpret_block: Invalid opcode 0x{x:0>2}", .{opcode});
            frame.gas_remaining = 0;
            contract.gas = 0;
            return RunResult.init(initial_gas, 0, .Invalid, ExecutionError.Error.InvalidOpcode, null);
        }

        // Execute operation directly without validation or gas consumption
        // (already done at block level)
        const result = operation_ptr.execute(current_pc, interpreter, state) catch |err| {
            contract.gas = frame.gas_remaining;

            var output: ?[]const u8 = null;
            const return_data = frame.output;
            Log.debug("VM.interpret_block: Error occurred: {}, output_size={}", .{ err, return_data.len });
            if (return_data.len > 0) {
                output = self.allocator.dupe(u8, return_data) catch {
                    return RunResult.init(initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null);
                };
            }

            return switch (err) {
                ExecutionError.Error.InvalidOpcode => {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    contract.gas = 0;
                    return RunResult.init(initial_gas, 0, .Invalid, err, output);
                },
                ExecutionError.Error.STOP => {
                    const res = RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
                    return res;
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
                else => return err,
            };
        };

        const old_pc = frame.pc;
        if (frame.pc == old_pc) {
            frame.pc += result.bytes_consumed;
        }

        instruction_count += 1;
    }

    contract.gas = frame.gas_remaining;
    const output_data = frame.output;
    const output: ?[]const u8 = if (output_data.len > 0) try self.allocator.dupe(u8, output_data) else null;

    Log.debug("VM.interpret_block: Execution completed, gas_used={}, output_size={}", .{
        initial_gas - frame.gas_remaining,
        if (output) |o| o.len else 0,
    });

    return RunResult.init(
        initial_gas,
        frame.gas_remaining,
        .Success,
        null,
        output,
    );
}