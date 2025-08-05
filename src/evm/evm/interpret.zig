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
const BlockResult = @import("block_result.zig").BlockResult;
const opcode = @import("../opcodes/opcode.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const Stack = @import("../stack/stack.zig");

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

    var frame = Frame{
        .gas_remaining = contract.gas,
        .pc = 0,
        .contract = contract,
        .allocator = self.allocator,
        .stop = false,
        .is_static = self.read_only,
        .depth = @as(u32, @intCast(self.depth)),
        .cost = 0,
        .current_block_cost = 0,
        .err = null,
        .input = input,
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(self.allocator),
        .stack = Stack.init(),
        .return_data = ReturnData.init(self.allocator),
    };
    defer frame.deinit();

    const interpreter: Operation.Interpreter = self;
    const state: Operation.State = &frame;

    // Check if block-based execution is available and beneficial
    const use_block_execution = if (contract.analysis) |analysis| 
        analysis.block_count > 0 and 
        !analysis.has_dynamic_jumps and
        contract.code_size > 100 // Only for non-trivial contracts
    else 
        false;

    if (use_block_execution) {
        // Block-based execution path
        Log.debug("VM.interpret: Using block-based execution, block_count={}", .{contract.analysis.?.block_count});
        
        var current_block: u16 = 0;
        
        while (frame.pc < contract.code_size) {
            @branchHint(.likely);
            
            // Find current block index
            if (current_block < contract.analysis.?.block_count) {
                const block_result = execute_block(self, &frame, current_block) catch |err| {
                    // Handle block execution error
                    contract.gas = frame.gas_remaining;
                    return handle_execution_error(self, &frame, err, initial_gas);
                };
                
                // Handle block exit
                switch (block_result.exit_type) {
                    .continue_sequential => {
                        // Move to next block
                        current_block += 1;
                        frame.pc = block_result.next_pc;
                    },
                    .jump => {
                        // Find target block
                        if (block_result.jump_target) |target| {
                            frame.pc = target;
                            current_block = find_block_index(contract.analysis.?, target);
                        }
                    },
                    .conditional_jump => {
                        if (block_result.condition) {
                            // Take jump
                            if (block_result.jump_target) |target| {
                                frame.pc = target;
                                current_block = find_block_index(contract.analysis.?, target);
                            }
                        } else {
                            // Continue to next block
                            frame.pc = block_result.next_pc;
                            current_block += 1;
                        }
                    },
                    .stop, .return_, .revert => {
                        // Execution complete
                        contract.gas = frame.gas_remaining;
                        return block_result.to_run_result(initial_gas, frame.gas_remaining);
                    },
                    .error_ => {
                        contract.gas = frame.gas_remaining;
                        if (block_result.err) |err| {
                            return handle_execution_error(self, &frame, err, initial_gas);
                        }
                        return RunResult.init(initial_gas, 0, .Invalid, ExecutionError.Error.InvalidOpcode, null);
                    },
                    .call, .create => {
                        // Not yet implemented in block execution
                        // Fall back to regular execution for this opcode
                        const op = contract.get_op(frame.pc);
                        const result = self.table.execute(frame.pc, interpreter, state, op) catch |err| {
                            contract.gas = frame.gas_remaining;
                            return handle_execution_error(self, &frame, err, initial_gas);
                        };
                        frame.pc += result.bytes_consumed;
                    },
                }
            } else {
                // Fallback to regular execution if we can't find block
                break;
            }
        }
    } else {
        // Original execution path
        while (frame.pc < contract.code_size) {
            @branchHint(.likely);
            const op = contract.get_op(frame.pc);

            const result = self.table.execute(frame.pc, interpreter, state, op) catch |err| {
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

/// Execute a basic block of EVM bytecode using pre-validated metadata.
///
/// This function executes an entire basic block without per-instruction validation,
/// relying on pre-computed block metadata for gas and stack requirements.
/// 
/// ## Safety Requirements:
/// - Block metadata must be accurate and trusted
/// - Stack must have sufficient depth for the block
/// - Gas must be sufficient for the entire block
/// - Block must not contain dynamic jumps
///
/// ## Performance Benefits:
/// - Single gas check instead of per-instruction
/// - Single stack validation instead of per-instruction
/// - Predictable control flow enables optimizations
/// - Reduced branch mispredictions
///
/// @param self The VM instance
/// @param frame Current execution frame
/// @param block_idx Index of the block to execute
/// @return BlockResult describing how the block exited
fn execute_block(self: *Vm, frame: *Frame, block_idx: u16) !BlockResult {
    const analysis = frame.contract.analysis.?;
    
    // Bounds check
    if (block_idx >= analysis.block_count) {
        return BlockResult.error_(ExecutionError.Error.InvalidJump, 0);
    }
    
    // Get block metadata
    const block_meta = analysis.block_metadata[block_idx];
    
    Log.debug("execute_block: Executing block {}, gas_cost={}, stack_req={}, stack_max={}", 
        .{ block_idx, block_meta.gas_cost, block_meta.stack_req, block_meta.stack_max });
    
    // Pre-validate gas for entire block
    if (frame.gas_remaining < block_meta.gas_cost) {
        return BlockResult.error_(ExecutionError.Error.OutOfGas, 0);
    }
    
    // Pre-validate stack requirements
    // SAFETY: After these checks, all stack operations in the block are guaranteed safe:
    // - We have at least stack_req items, so all pops will succeed
    // - We won't exceed capacity, so all pushes will succeed
    const stack_size: i16 = @intCast(frame.stack.size());
    if (stack_size < block_meta.stack_req) {
        return BlockResult.error_(ExecutionError.Error.StackUnderflow, 0);
    }
    if (stack_size + block_meta.stack_max > @as(i16, @intCast(Stack.CAPACITY))) {
        return BlockResult.error_(ExecutionError.Error.StackOverflow, 0);
    }
    
    // Consume gas for entire block upfront
    frame.gas_remaining -= block_meta.gas_cost;
    
    // Store block cost for gas corrections (e.g., GAS opcode)
    frame.current_block_cost = block_meta.gas_cost;
    
    // Find block boundaries
    const block_start = find_block_start(analysis, block_idx);
    const block_end = find_block_end(analysis, block_idx, frame.contract.code_size);
    
    Log.debug("execute_block: Block {} spans PC {}-{}", .{ block_idx, block_start, block_end });
    
    // Execute instructions in the block
    frame.pc = block_start;
    var last_opcode: u8 = 0;
    
    while (frame.pc < block_end) {
        const op = frame.contract.get_op(frame.pc);
        last_opcode = op;
        
        // Execute opcode without validation (unsafe but fast)
        const result = try execute_opcode_unsafe(self, frame, op);
        
        // Check if this opcode changes control flow
        if (result.exits_block) {
            return result.block_result;
        }
        
        // Advance PC
        frame.pc += result.bytes_consumed;
    }
    
    // Block ended without explicit exit - continue to next block
    return BlockResult.continue_sequential(frame.pc, block_meta.gas_cost);
}

/// Find the starting PC of a block.
fn find_block_start(analysis: *const CodeAnalysis, block_idx: u16) usize {
    // O(1) lookup using pre-computed positions
    if (block_idx >= analysis.block_count) return 0;
    return analysis.block_start_positions[block_idx];
}

/// Find the ending PC of a block (exclusive).
fn find_block_end(analysis: *const CodeAnalysis, block_idx: u16, code_size: usize) usize {
    if (block_idx + 1 >= analysis.block_count) {
        return code_size;
    }
    
    // O(1) lookup of next block's start position
    return analysis.block_start_positions[block_idx + 1];
}

/// Result of executing a single opcode in unsafe mode.
const UnsafeExecutionResult = struct {
    /// Number of bytes consumed (including opcode and operands)
    bytes_consumed: u8,
    /// Whether this opcode exits the block
    exits_block: bool = false,
    /// If exits_block is true, the block result
    block_result: BlockResult = undefined,
};

/// Execute a single opcode without validation.
/// 
/// SAFETY: This function assumes:
/// - Gas has been pre-checked for the entire block
/// - Stack requirements have been pre-validated
/// - The opcode is valid and within bounds
///
/// This function is only safe to call within execute_block after validation.
fn execute_opcode_unsafe(vm: *Vm, frame: *Frame, op: u8) !UnsafeExecutionResult {
    const intrinsic = @import("../opcodes/intrinsic.zig");
    
    // Check for BEGINBLOCK intrinsic
    if (op == @intFromEnum(intrinsic.IntrinsicOpcodes.BEGINBLOCK)) {
        // BEGINBLOCK is handled by execute_block, should not reach here
        unreachable;
    }
    
    // Debug assertions to catch validation errors during development
    if (std.debug.runtime_safety) {
        // These checks should never fail if block validation is correct
        std.debug.assert(frame.stack.size() <= Stack.CAPACITY);
        std.debug.assert(frame.gas_remaining >= 0);
    }
    
    // Handle common hot opcodes inline for better performance
    switch (op) {
        // Stack operations
        0x50 => { // POP
            _ = frame.stack.pop_unsafe();
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x51 => { // MLOAD
            const offset = frame.stack.pop_unsafe();
            const value = try frame.memory.get_u256(@intCast(offset));
            frame.stack.append_unsafe(value);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x52 => { // MSTORE
            const offset = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            try frame.memory.set_u256(@intCast(offset), value);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Arithmetic
        0x01 => { // ADD
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(a +% b);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x02 => { // MUL  
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(a *% b);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x03 => { // SUB
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(a -% b);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x04 => { // DIV
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const result = if (b == 0) 0 else a / b;
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x05 => { // SDIV
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const result = if (b == 0) 0 else blk: {
                const a_signed = @as(i256, @bitCast(a));
                const b_signed = @as(i256, @bitCast(b));
                break :blk @as(u256, @bitCast(@divTrunc(a_signed, b_signed)));
            };
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x06 => { // MOD
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const result = if (b == 0) 0 else a % b;
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x07 => { // SMOD
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const result = if (b == 0) 0 else blk: {
                const a_signed = @as(i256, @bitCast(a));
                const b_signed = @as(i256, @bitCast(b));
                break :blk @as(u256, @bitCast(@rem(a_signed, b_signed)));
            };
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Comparison operations
        0x10 => { // LT
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(if (a < b) 1 else 0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x11 => { // GT
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(if (a > b) 1 else 0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x12 => { // SLT
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const a_signed = @as(i256, @bitCast(a));
            const b_signed = @as(i256, @bitCast(b));
            frame.stack.append_unsafe(if (a_signed < b_signed) 1 else 0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x13 => { // SGT
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const a_signed = @as(i256, @bitCast(a));
            const b_signed = @as(i256, @bitCast(b));
            frame.stack.append_unsafe(if (a_signed > b_signed) 1 else 0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x14 => { // EQ
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(if (a == b) 1 else 0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x15 => { // ISZERO
            const a = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(if (a == 0) 1 else 0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Bitwise operations
        0x16 => { // AND
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(a & b);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x17 => { // OR
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(a | b);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x18 => { // XOR
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(a ^ b);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x19 => { // NOT
            const a = frame.stack.pop_unsafe();
            frame.stack.append_unsafe(~a);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x1b => { // SHL
            const shift = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            const result = if (shift >= 256) 0 else value << @intCast(shift);
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x1c => { // SHR
            const shift = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            const result = if (shift >= 256) 0 else value >> @intCast(shift);
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x1d => { // SAR (arithmetic shift right)
            const shift = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            const result = if (shift >= 256) blk: {
                // If negative, result is -1, else 0
                const is_negative = value >> 255 == 1;
                break :blk if (is_negative) @as(u256, std.math.maxInt(u256)) else @as(u256, 0);
            } else blk: {
                const value_signed = @as(i256, @bitCast(value));
                break :blk @as(u256, @bitCast(value_signed >> @intCast(shift)));
            };
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Environment operations
        0x30 => { // ADDRESS
            frame.stack.append_unsafe(primitives.Address.to_u256(frame.contract.address));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x33 => { // CALLER
            frame.stack.append_unsafe(primitives.Address.to_u256(frame.contract.caller));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x34 => { // CALLVALUE
            frame.stack.append_unsafe(frame.contract.value);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x35 => { // CALLDATALOAD
            const offset = frame.stack.pop_unsafe();
            const offset_usize = @as(usize, @intCast(@min(offset, std.math.maxInt(usize))));
            
            var value: u256 = 0;
            if (offset_usize < frame.input.len) {
                const remaining = frame.input.len - offset_usize;
                const copy_len = @min(32, remaining);
                var bytes: [32]u8 = [_]u8{0} ** 32;
                @memcpy(bytes[0..copy_len], frame.input[offset_usize..][0..copy_len]);
                value = std.mem.readInt(u256, &bytes, .big);
            }
            
            frame.stack.append_unsafe(value);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x36 => { // CALLDATASIZE
            frame.stack.append_unsafe(@as(u256, @intCast(frame.input.len)));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Additional bitwise operation
        0x1a => { // BYTE
            const index = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            const result = if (index >= 32) 0 else (value >> @intCast((31 - index) * 8)) & 0xFF;
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Memory operations
        0x53 => { // MSTORE8
            const offset = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            const byte_value = @as(u8, @truncate(value));
            const bytes = [_]u8{byte_value};
            try frame.memory.set_data(@intCast(offset), &bytes);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Stack operations
        0x58 => { // PC
            frame.stack.append_unsafe(@as(u256, @intCast(frame.pc)));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x59 => { // MSIZE
            frame.stack.append_unsafe(@as(u256, @intCast(frame.memory.size())));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x5a => { // GAS
            frame.stack.append_unsafe(@as(u256, @intCast(frame.gas_remaining)));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x5f => { // PUSH0 (Shanghai)
            frame.stack.append_unsafe(0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Arithmetic operations
        0x08 => { // ADDMOD
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const n = frame.stack.pop_unsafe();
            const result = if (n == 0) 0 else blk: {
                // Use u512 to prevent overflow in addition
                const a_wide = @as(u512, a);
                const b_wide = @as(u512, b);
                const n_wide = @as(u512, n);
                const sum = (a_wide + b_wide) % n_wide;
                break :blk @as(u256, @intCast(sum));
            };
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x09 => { // MULMOD
            const a = frame.stack.pop_unsafe();
            const b = frame.stack.pop_unsafe();
            const n = frame.stack.pop_unsafe();
            const result = if (n == 0) 0 else blk: {
                // Use u512 to prevent overflow in multiplication
                const a_wide = @as(u512, a);
                const b_wide = @as(u512, b);
                const n_wide = @as(u512, n);
                const product = (a_wide * b_wide) % n_wide;
                break :blk @as(u256, @intCast(product));
            };
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x0a => { // EXP
            const base = frame.stack.pop_unsafe();
            const exp = frame.stack.pop_unsafe();
            
            // Fast paths
            if (exp == 0) {
                frame.stack.append_unsafe(1);
                return UnsafeExecutionResult{ .bytes_consumed = 1 };
            }
            if (base == 0) {
                frame.stack.append_unsafe(0);
                return UnsafeExecutionResult{ .bytes_consumed = 1 };
            }
            if (base == 1) {
                frame.stack.append_unsafe(1);
                return UnsafeExecutionResult{ .bytes_consumed = 1 };
            }
            if (exp == 1) {
                frame.stack.append_unsafe(base);
                return UnsafeExecutionResult{ .bytes_consumed = 1 };
            }
            
            // Compute base^exp with wrapping arithmetic
            var result: u256 = 1;
            var b = base;
            var e = exp;
            while (e > 0) {
                if (e & 1 == 1) {
                    result *%= b;
                }
                b *%= b;
                e >>= 1;
            }
            
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x0b => { // SIGNEXTEND
            const byte_num = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            
            const result = if (byte_num >= 31) value else blk: {
                const bit_pos = byte_num * 8 + 7;
                const bit = (value >> @intCast(bit_pos)) & 1;
                const mask = (@as(u256, 1) << @intCast(bit_pos + 1)) - 1;
                break :blk if (bit == 1) value | ~mask else value & mask;
            };
            
            frame.stack.append_unsafe(result);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Keccak256
        0x20 => { // KECCAK256
            const offset = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size == 0) {
                // Keccak256 of empty data
                const empty_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                frame.stack.append_unsafe(empty_hash);
                return UnsafeExecutionResult{ .bytes_consumed = 1 };
            }
            
            const data = try frame.memory.get_slice(@intCast(offset), @intCast(size));
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
            const hash_u256 = std.mem.readInt(u256, &hash, .big);
            frame.stack.append_unsafe(hash_u256);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // More environment operations
        0x32 => { // ORIGIN
            frame.stack.append_unsafe(primitives.Address.to_u256(vm.context.tx_origin));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x3a => { // GASPRICE
            frame.stack.append_unsafe(vm.context.gas_price);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Block information
        0x41 => { // COINBASE
            frame.stack.append_unsafe(primitives.Address.to_u256(vm.context.block_coinbase));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x42 => { // TIMESTAMP
            frame.stack.append_unsafe(@as(u256, vm.context.block_timestamp));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x43 => { // NUMBER
            frame.stack.append_unsafe(@as(u256, vm.context.block_number));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x44 => { // PREVRANDAO (was DIFFICULTY)
            frame.stack.append_unsafe(vm.context.block_difficulty);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x45 => { // GASLIMIT
            frame.stack.append_unsafe(@as(u256, vm.context.block_gas_limit));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x46 => { // CHAINID
            frame.stack.append_unsafe(vm.context.chain_id);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x48 => { // BASEFEE
            frame.stack.append_unsafe(vm.context.block_base_fee);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Code operations
        0x38 => { // CODESIZE
            frame.stack.append_unsafe(@as(u256, @intCast(frame.contract.code_size)));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x39 => { // CODECOPY
            const mem_offset = frame.stack.pop_unsafe();
            const code_offset = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size > 0) {
                const code_offset_usize = @as(usize, @intCast(@min(code_offset, std.math.maxInt(usize))));
                const size_usize = @as(usize, @intCast(@min(size, std.math.maxInt(usize))));
                
                try frame.memory.set_data_bounded(
                    @intCast(mem_offset),
                    frame.contract.code,
                    code_offset_usize,
                    size_usize
                );
            }
            
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x37 => { // CALLDATACOPY
            const mem_offset = frame.stack.pop_unsafe();
            const data_offset = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size > 0) {
                const data_offset_usize = @as(usize, @intCast(@min(data_offset, std.math.maxInt(usize))));
                const size_usize = @as(usize, @intCast(@min(size, std.math.maxInt(usize))));
                
                try frame.memory.set_data_bounded(
                    @intCast(mem_offset),
                    frame.input,
                    data_offset_usize,
                    size_usize
                );
            }
            
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Storage operations (require state access but are common)
        0x54 => { // SLOAD
            const key = frame.stack.pop_unsafe();
            const value = vm.state.get_storage(frame.contract.address, key);
            frame.stack.append_unsafe(value);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x55 => { // SSTORE
            const key = frame.stack.pop_unsafe();
            const value = frame.stack.pop_unsafe();
            vm.state.set_storage(frame.contract.address, key, value) catch {};
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Account operations
        0x31 => { // BALANCE
            const addr_u256 = frame.stack.pop_unsafe();
            const addr = primitives.Address.from_u256(addr_u256);
            const balance = vm.state.get_balance(addr);
            frame.stack.append_unsafe(balance);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x3b => { // EXTCODESIZE
            const addr_u256 = frame.stack.pop_unsafe();
            const addr = primitives.Address.from_u256(addr_u256);
            const code = vm.state.get_code(addr);
            frame.stack.append_unsafe(@as(u256, @intCast(code.len)));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x3c => { // EXTCODECOPY
            const addr_u256 = frame.stack.pop_unsafe();
            const mem_offset = frame.stack.pop_unsafe();
            const code_offset = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size > 0) {
                const addr = primitives.Address.from_u256(addr_u256);
                const account = vm.state.database.get_account(addr) catch null;
                const code = if (account) |acc| vm.state.database.get_code(acc.code_hash) catch &.{} else &.{};
                const code_offset_usize = @as(usize, @intCast(@min(code_offset, std.math.maxInt(usize))));
                const size_usize = @as(usize, @intCast(@min(size, std.math.maxInt(usize))));
                
                try frame.memory.set_data_bounded(
                    @intCast(mem_offset),
                    code,
                    code_offset_usize,
                    size_usize
                );
            }
            
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x3f => { // EXTCODEHASH
            const addr_u256 = frame.stack.pop_unsafe();
            const addr = primitives.Address.from_u256(addr_u256);
            const account = vm.state.database.get_account(addr) catch null;
            const code = if (account) |acc| vm.state.database.get_code(acc.code_hash) catch &.{} else &.{};
            
            if (code.len == 0) {
                frame.stack.append_unsafe(0);
            } else {
                var hash: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});
                const hash_u256 = std.mem.readInt(u256, &hash, .big);
                frame.stack.append_unsafe(hash_u256);
            }
            
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x47 => { // SELFBALANCE
            const balance = vm.state.get_balance(frame.contract.address);
            frame.stack.append_unsafe(balance);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x40 => { // BLOCKHASH
            const block_num = frame.stack.pop_unsafe();
            // For now return 0 - proper implementation would check last 256 blocks
            _ = block_num; // Suppress unused variable warning
            frame.stack.append_unsafe(0);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Memory copy operation (EIP-5656)
        0x5e => { // MCOPY
            const dest = frame.stack.pop_unsafe();
            const src = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size > 0) {
                const dest_usize = @as(usize, @intCast(@min(dest, std.math.maxInt(usize))));
                const src_usize = @as(usize, @intCast(@min(src, std.math.maxInt(usize))));
                const size_usize = @as(usize, @intCast(@min(size, std.math.maxInt(usize))));
                
                // Get memory slice and handle overlapping copy
                const mem_slice = frame.memory.slice();
                const max_addr = @max(dest_usize + size_usize, src_usize + size_usize);
                if (mem_slice.len >= max_addr) {
                    if (dest_usize > src_usize and dest_usize < src_usize + size_usize) {
                        // Forward overlap: copy backwards
                        std.mem.copyBackwards(u8, mem_slice[dest_usize..dest_usize + size_usize], mem_slice[src_usize..src_usize + size_usize]);
                    } else {
                        // No overlap or backward overlap: copy forwards
                        std.mem.copyForwards(u8, mem_slice[dest_usize..dest_usize + size_usize], mem_slice[src_usize..src_usize + size_usize]);
                    }
                }
            }
            
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // JUMPDEST - no operation, just marks valid jump destination
        0x5b => { // JUMPDEST
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Return data operations
        0x3d => { // RETURNDATASIZE
            frame.stack.append_unsafe(@as(u256, @intCast(frame.return_data.size())));
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        0x3e => { // RETURNDATACOPY
            const mem_offset = frame.stack.pop_unsafe();
            const data_offset = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size > 0) {
                const data_offset_usize = @as(usize, @intCast(@min(data_offset, std.math.maxInt(usize))));
                const size_usize = @as(usize, @intCast(@min(size, std.math.maxInt(usize))));
                
                try frame.memory.set_data_bounded(
                    @intCast(mem_offset),
                    frame.return_data.get(),
                    data_offset_usize,
                    size_usize
                );
            }
            
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // Control flow - these exit the block
        0x00 => { // STOP
            return UnsafeExecutionResult{
                .bytes_consumed = 1,
                .exits_block = true,
                .block_result = BlockResult.stop(0),
            };
        },
        0x56 => { // JUMP
            const dest = frame.stack.pop_unsafe();
            
            // In block execution mode, jumps should be pre-validated
            // But we add validation for safety and for dynamic jumps
            if (frame.contract.analysis) |analysis| {
                if (analysis.jump_analysis) |jump_analysis| {
                    // Use optimized validation with PC information
                    const jump_module = @import("../frame/jump_analysis.zig");
                    if (!jump_module.optimize_jump_validation(jump_analysis, frame.pc, dest)) {
                        return UnsafeExecutionResult{
                            .bytes_consumed = 1,
                            .exits_block = true,
                            .block_result = BlockResult.error_(ExecutionError.Error.InvalidJump, 0),
                        };
                    }
                }
            }
            
            frame.pc = @intCast(dest);
            return UnsafeExecutionResult{
                .bytes_consumed = 1,
                .exits_block = true,
                .block_result = BlockResult.jump(@intCast(dest), 0),
            };
        },
        0x57 => { // JUMPI
            const dest = frame.stack.pop_unsafe();
            const condition = frame.stack.pop_unsafe();
            if (condition != 0) {
                // Validate jump destination using optimized validation
                if (frame.contract.analysis) |analysis| {
                    if (analysis.jump_analysis) |jump_analysis| {
                        const jump_module = @import("../frame/jump_analysis.zig");
                        if (!jump_module.optimize_jump_validation(jump_analysis, frame.pc, dest)) {
                            return UnsafeExecutionResult{
                                .bytes_consumed = 1,
                                .exits_block = true,
                                .block_result = BlockResult.error_(ExecutionError.Error.InvalidJump, 0),
                            };
                        }
                    }
                }
                
                frame.pc = @intCast(dest);
                return UnsafeExecutionResult{
                    .bytes_consumed = 1,
                    .exits_block = true,
                    .block_result = BlockResult.conditional_jump(@intCast(dest), true, frame.pc + 1, 0),
                };
            } else {
                return UnsafeExecutionResult{
                    .bytes_consumed = 1,
                    .exits_block = true,
                    .block_result = BlockResult.conditional_jump(@intCast(dest), false, frame.pc + 1, 0),
                };
            }
        },
        0xf3 => { // RETURN
            const offset = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size > 0) {
                const mem_data = try frame.memory.get_slice(@intCast(offset), @intCast(size));
                // Note: Memory allocated here is owned by the RunResult and must be freed by the caller
                const data = try vm.allocator.alloc(u8, @intCast(size));
                @memcpy(data, mem_data);
                frame.output = data;
            }
            
            return UnsafeExecutionResult{
                .bytes_consumed = 1,
                .exits_block = true,
                .block_result = BlockResult.return_(frame.output, 0),
            };
        },
        0xfd => { // REVERT
            const offset = frame.stack.pop_unsafe();
            const size = frame.stack.pop_unsafe();
            
            if (size > 0) {
                const mem_data = try frame.memory.get_slice(@intCast(offset), @intCast(size));
                // Note: Memory allocated here is owned by the RunResult and must be freed by the caller
                const data = try vm.allocator.alloc(u8, @intCast(size));
                @memcpy(data, mem_data);
                frame.output = data;
            }
            
            return UnsafeExecutionResult{
                .bytes_consumed = 1,
                .exits_block = true,
                .block_result = BlockResult.revert(frame.output, 0),
            };
        },
        
        // PUSH operations
        0x60...0x7f => |push_op| {
            const n = push_op - 0x5f;
            const bytes = frame.contract.code[frame.pc + 1..][0..n];
            var value: u256 = 0;
            for (bytes) |byte| {
                value = (value << 8) | byte;
            }
            frame.stack.append_unsafe(value);
            return UnsafeExecutionResult{ .bytes_consumed = 1 + n };
        },
        
        // DUP operations
        0x80...0x8f => |dup_op| {
            const n = dup_op - 0x80 + 1;
            frame.stack.dup_unsafe(n);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // SWAP operations  
        0x90...0x9f => |swap_op| {
            const n = swap_op - 0x90 + 1;
            frame.stack.swap_unsafe(n);
            return UnsafeExecutionResult{ .bytes_consumed = 1 };
        },
        
        // LOG operations
        0xa0...0xa4 => |log_op| {
            const n = log_op - 0xa0;
            _ = frame.stack.pop_unsafe(); // offset
            _ = frame.stack.pop_unsafe(); // size
            
            // Pop topics
            var i: usize = 0;
            while (i < n) : (i += 1) {
                _ = frame.stack.pop_unsafe();
            }
            
            // LOG operations are terminal for the block since they access memory
            // and may have side effects that need proper gas accounting
            return UnsafeExecutionResult{
                .bytes_consumed = 1,
                .exits_block = true,
                .block_result = BlockResult.continue_sequential(frame.pc + 1, 0),
            };
        },
        
        // INVALID opcode - consumes all gas and halts
        0xfe => { // INVALID
            frame.gas_remaining = 0;
            return UnsafeExecutionResult{
                .bytes_consumed = 1,
                .exits_block = true,
                .block_result = BlockResult.error_(ExecutionError.Error.InvalidOpcode, frame.gas_remaining),
            };
        },
        
        // For other opcodes, fall back to regular execution
        // This is safe because we already consumed gas for the block
        else => {
            const interpreter: Operation.Interpreter = vm;
            const state: Operation.State = frame;
            
            // Temporarily add back the gas for this operation since execute will consume it
            const operation = vm.table.get_operation(op);
            frame.gas_remaining += operation.constant_gas;
            
            const result = try vm.table.execute(frame.pc, interpreter, state, op);
            
            // Check if this was a control flow operation we didn't handle
            const old_pc = frame.pc;
            if (frame.pc != old_pc) {
                // PC was modified - this exits the block
                return UnsafeExecutionResult{
                    .bytes_consumed = @intCast(result.bytes_consumed),
                    .exits_block = true,
                    .block_result = BlockResult.jump(frame.pc, 0),
                };
            }
            
            return UnsafeExecutionResult{ .bytes_consumed = @intCast(result.bytes_consumed) };
        },
    }
}

/// Check if a block is safe for block-based execution.
///
/// A block is considered safe if:
/// - It has no dynamic jumps (JUMP/JUMPI with non-constant targets)
/// - It doesn't call external contracts (CALL/DELEGATECALL/etc)
/// - It has reasonable size (not too large)
fn is_safe_block(analysis: *const CodeAnalysis, block_idx: u16) bool {
    // For now, use simple heuristics
    const block_meta = analysis.block_metadata[block_idx];
    
    // Skip blocks with very high gas costs (likely complex)
    if (block_meta.gas_cost > 1000) {
        return false;
    }
    
    // Skip if contract has dynamic jumps anywhere
    // (more sophisticated analysis would check per-block)
    if (analysis.has_dynamic_jumps) {
        return false;
    }
    
    return true;
}

/// Find the block index for a given PC.
fn find_block_index(analysis: *const CodeAnalysis, pc: usize) u16 {
    if (pc >= analysis.pc_to_block.len) {
        return analysis.block_count; // Invalid block
    }
    return analysis.pc_to_block[pc];
}

/// Handle execution errors uniformly.
fn handle_execution_error(self: *Vm, frame: *Frame, err: ExecutionError.Error, initial_gas: u64) RunResult {
    var output: ?[]const u8 = null;
    const return_data = frame.output;
    
    Log.debug("VM.handle_execution_error: Error occurred: {}, output_size={}", .{ err, return_data.len });
    
    if (return_data.len > 0) {
        output = self.allocator.dupe(u8, return_data) catch {
            return RunResult.init(initial_gas, 0, .OutOfGas, ExecutionError.Error.OutOfMemory, null);
        };
    }
    
    return switch (err) {
        ExecutionError.Error.InvalidOpcode => {
            @branchHint(.cold);
            frame.gas_remaining = 0;
            return RunResult.init(initial_gas, 0, .Invalid, err, output);
        },
        ExecutionError.Error.STOP => {
            return RunResult.init(initial_gas, frame.gas_remaining, .Success, null, output);
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
        else => RunResult.init(initial_gas, frame.gas_remaining, .Invalid, err, output),
    };
}
