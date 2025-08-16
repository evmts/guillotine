const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;
const Host = @import("../host.zig").Host;
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const primitives = @import("primitives");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const CodeAnalysis = @import("../analysis.zig").CodeAnalysis;
const Memory = @import("../memory/memory.zig");
const MAX_INPUT_SIZE = 131072; // 128KB
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;
const MAX_CALL_DEPTH = @import("../constants/evm_limits.zig").MAX_CALL_DEPTH;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;

/// Simplified EVM execution without analysis - performs lazy jumpdest validation
/// This is a simpler alternative to the analysis-based approach used in call()
pub fn call_mini(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    const Log = @import("../log.zig");
    const opcode_mod = @import("../opcodes/opcode.zig");

    Log.debug("[call_mini] Starting simplified execution", .{});

    // Create host interface
    const host = Host.init(self);

    // Check if top-level call
    const is_top_level_call = !self.is_currently_executing();
    Log.debug("[call_mini] is_top_level_call={}, is_executing={}, current_frame_depth={}", .{ is_top_level_call, self.is_currently_executing(), self.current_frame_depth });
    const snapshot_id = if (!is_top_level_call) host.create_snapshot() else 0;

    // Extract call parameters
    var call_address: primitives.Address.Address = undefined;
    var call_code: []const u8 = undefined;
    var call_input: []const u8 = undefined;
    var call_gas: u64 = undefined;
    var call_is_static: bool = undefined;
    var call_caller: primitives.Address.Address = undefined;
    var call_value: u256 = undefined;

    switch (params) {
        .call => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            call_input = call_data.input;
            call_gas = call_data.gas;
            call_is_static = false;
            call_caller = call_data.caller;
            call_value = call_data.value;
        },
        .staticcall => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            call_input = call_data.input;
            call_gas = call_data.gas;
            call_is_static = true;
            call_caller = call_data.caller;
            call_value = 0;
        },
        else => {
            Log.debug("[call_mini] Unsupported call type", .{});
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        },
    }

    // Validate inputs
    if (call_input.len > MAX_INPUT_SIZE or call_code.len > MAX_CODE_SIZE) {
        if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }

    // Charge base transaction cost for top-level calls
    var gas_after_base = call_gas;
    if (is_top_level_call) {
        const GasConstants = @import("primitives").GasConstants;
        const base_cost = GasConstants.TxGas;

        if (gas_after_base < base_cost) {
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        }
        gas_after_base -= base_cost;
    }

    // Check for precompiles
    if (precompile_addresses.get_precompile_id_checked(call_address)) |precompile_id| {
        const precompile_result = self.execute_precompile_call_by_id(precompile_id, call_input, gas_after_base, call_is_static) catch |err| {
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return switch (err) {
                else => CallResult{ .success = false, .gas_left = 0, .output = &.{} },
            };
        };

        if (self.current_frame_depth > 0 and !precompile_result.success) {
            host.revert_to_snapshot(snapshot_id);
        }

        return precompile_result;
    }

    // Initialize frame state for top-level calls
    if (is_top_level_call) {
        self.current_frame_depth = 0;
        self.access_list.clear();

        self.self_destruct.deinit();
        self.self_destruct = SelfDestruct.init(self.allocator);

        self.created_contracts.deinit();
        self.created_contracts = CreatedContracts.init(self.allocator);

        // Clear output and input state
        self.current_output = &.{};
        self.current_input = &.{};

        if (self.frame_stack == null) {
            self.frame_stack = try std.heap.page_allocator.alloc(Frame, MAX_CALL_DEPTH);
        }
    } else {
        // Nested call - check depth
        const new_depth = self.current_frame_depth + 1;
        if (new_depth >= MAX_CALL_DEPTH) {
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = gas_after_base, .output = &.{} };
        }
    }

    // Prewarm addresses for Berlin
    if (self.chain_rules.is_berlin) {
        const addresses_to_warm = [_]primitives.Address.Address{ call_address, call_caller };
        self.access_list.pre_warm_addresses(&addresses_to_warm) catch |err| {
            Log.debug("[call_mini] Failed to warm addresses: {}", .{err});
        };
    }

    // Use cached analysis if available, otherwise analyze and cache
    var analysis_owned = false;
    var analysis_ptr: *CodeAnalysis = if (self.analysis_cache) |*cache| blk: {
        Log.debug("[call_mini] Using analysis cache for code analysis", .{});
        break :blk cache.getOrAnalyze(call_code, &self.table) catch |err| {
            Log.err("[call_mini] Cached code analysis failed: {}", .{err});
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_gas, .output = &.{} };
        };
    } else blk: {
        Log.debug("[call_mini] No cache available, analyzing code directly", .{});
        var analysis_val = CodeAnalysis.from_code(self.allocator, call_code, &self.table) catch |err| {
            Log.err("[call_mini] Code analysis failed: {}", .{err});
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_gas, .output = &.{} };
        };
        const analysis_heap = self.allocator.create(CodeAnalysis) catch {
            analysis_val.deinit();
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = call_gas, .output = &.{} };
        };
        analysis_heap.* = analysis_val;
        analysis_owned = true;
        break :blk analysis_heap;
    };
    defer if (analysis_owned) {
        analysis_ptr.deinit();
        self.allocator.destroy(analysis_ptr);
    };

    // Create frame
    const contract_addr_for_frame = call_address;
    var frame = try Frame.init(
        gas_after_base,
        call_is_static,
        @intCast(self.current_frame_depth),
        contract_addr_for_frame,
        call_caller,
        call_value,
        analysis_ptr,
        host,
        self.state.database,
        self.allocator,
    );
    defer frame.deinit(self.allocator);

    // Set the input buffer for the frame
    frame.input_buffer = call_input;

    // Store the current input for the host interface to access
    self.current_input = call_input;

    // Store the frame in the frame stack if it exists
    if (self.frame_stack) |frames| {
        if (self.current_frame_depth < frames.len) {
            frames[self.current_frame_depth] = frame;
        }
    }

    // Main execution loop
    var exec_err: ?ExecutionError.Error = null;
    const was_executing = self.is_currently_executing();
    self.set_is_executing(true);
    defer self.set_is_executing(was_executing);

    // For mini EVM, we'll use simple PC tracking instead of analysis blocks
    var pc: usize = 0;

    while (pc < call_code.len) {
        const op = call_code[pc];

        // Get operation metadata from table
        const operation = self.table.get_operation(op);

        // Check if opcode is undefined
        if (operation.undefined) {
            exec_err = ExecutionError.Error.InvalidOpcode;
            break;
        }

        // Check gas
        if (frame.gas_remaining < operation.constant_gas) {
            exec_err = ExecutionError.Error.OutOfGas;
            break;
        }
        frame.gas_remaining -= operation.constant_gas;

        // Check stack requirements
        if (frame.stack.size() < operation.min_stack) {
            exec_err = ExecutionError.Error.StackUnderflow;
            break;
        }
        // max_stack represents the maximum stack size allowed before operation
        if (frame.stack.size() > operation.max_stack) {
            exec_err = ExecutionError.Error.StackOverflow;
            break;
        }

        // Handle specific opcodes that need special handling
        switch (op) {
            @intFromEnum(opcode_mod.Enum.STOP) => {
                exec_err = ExecutionError.Error.STOP;
                break;
            },
            @intFromEnum(opcode_mod.Enum.JUMP) => {
                const dest = try frame.stack.pop();

                // Check if destination fits in usize and is within bounds
                if (dest > call_code.len) {
                    exec_err = ExecutionError.Error.InvalidJump;
                    break;
                }

                const dest_usize = @as(usize, @intCast(dest));

                // Check if destination is valid jumpdest
                if (dest_usize >= call_code.len or call_code[dest_usize] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                    exec_err = ExecutionError.Error.InvalidJump;
                    break;
                }

                pc = dest_usize;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.JUMPI) => {
                Log.debug("[JUMPI_DEBUG] PC={}, stack_size={}", .{ pc, frame.stack.size() });

                const dest = try frame.stack.pop();
                const cond = try frame.stack.pop();

                Log.debug("[JUMPI_DEBUG] dest={}, cond={}, taking_jump={}", .{ dest, cond, cond != 0 });

                if (cond != 0) {
                    // Check if destination fits in usize and is within bounds
                    if (dest > call_code.len) {
                        Log.debug("[JUMPI_DEBUG] Invalid jump: dest={} > code_len={}", .{ dest, call_code.len });
                        exec_err = ExecutionError.Error.InvalidJump;
                        break;
                    }

                    const dest_usize = @as(usize, @intCast(dest));

                    // Check if destination is valid jumpdest
                    if (dest_usize >= call_code.len or call_code[dest_usize] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                        const byte_at_dest = if (dest_usize < call_code.len) call_code[dest_usize] else 0;
                        Log.debug("[JUMPI_DEBUG] Invalid jumpdest: dest={}, byte_at_dest=0x{x:0>2}, expected=0x{x:0>2}", .{ dest_usize, byte_at_dest, @intFromEnum(opcode_mod.Enum.JUMPDEST) });
                        exec_err = ExecutionError.Error.InvalidJump;
                        break;
                    }

                    Log.debug("[JUMPI_DEBUG] Valid jump to {}", .{dest_usize});
                    pc = dest_usize;
                    continue;
                }

                Log.debug("[JUMPI_DEBUG] Not taking jump, continuing to PC={}", .{pc + 1});
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.PC) => {
                try frame.stack.append(@intCast(pc));
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.JUMPDEST) => {
                // JUMPDEST is a no-op, just advance PC
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.PUSH0) => {
                // PUSH0 pushes 0 onto the stack
                try frame.stack.append(0);
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.RETURN) => {
                const offset = try frame.stack.pop();
                const size = try frame.stack.pop();

                Log.debug("RETURN opcode: offset={}, size={}", .{ offset, size });

                // Get return data from memory
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = try frame.memory.get_slice(offset_usize, size_usize);
                    Log.debug("RETURN reading {} bytes from memory[{}..{}]", .{ size_usize, offset_usize, offset_usize + size_usize });
                    Log.debug("RETURN data: {x}", .{std.fmt.fmtSliceHexLower(data)});
                    host.set_output(data) catch {
                        exec_err = ExecutionError.Error.DatabaseCorrupted;
                        break;
                    };
                    Log.debug("RETURN data set to host output, size: {}", .{data.len});
                }

                exec_err = ExecutionError.Error.RETURN;
                break;
            },
            @intFromEnum(opcode_mod.Enum.REVERT) => {
                const offset = try frame.stack.pop();
                const size = try frame.stack.pop();

                // Get revert data from memory
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = try frame.memory.get_slice(offset_usize, size_usize);
                    host.set_output(data) catch {
                        exec_err = ExecutionError.Error.DatabaseCorrupted;
                        break;
                    };
                }

                exec_err = ExecutionError.Error.REVERT;
                break;
            },
            else => {
                // Handle PUSH opcodes
                if (opcode_mod.is_push(op)) {
                    const push_size = opcode_mod.get_push_size(op);

                    Log.debug("[PUSH_DEBUG] PC={}, opcode=0x{x:0>2}, push_size={}", .{ pc, op, push_size });

                    if (pc + push_size >= call_code.len) {
                        Log.debug("[PUSH_DEBUG] Out of bounds: pc={}, push_size={}, code_len={}", .{ pc, push_size, call_code.len });
                        exec_err = ExecutionError.Error.OutOfOffset;
                        break;
                    }

                    // Read push data
                    var value: u256 = 0;
                    const data_start = pc + 1;
                    const data_end = @min(data_start + push_size, call_code.len);
                    const data = call_code[data_start..data_end];

                    Log.debug("[PUSH_DEBUG] Reading bytes from [{}..{}]: {x}", .{ data_start, data_end, std.fmt.fmtSliceHexLower(data) });

                    // Convert bytes to u256 (big-endian)
                    for (data) |byte| {
                        value = (value << 8) | byte;
                    }

                    Log.debug("[PUSH_DEBUG] Final value pushed: {}", .{value});

                    try frame.stack.append(value);
                    pc += 1 + push_size;
                    continue;
                }

                // For all other opcodes, use the execution function from the jump table
                // Create a context pointer for the execution function
                const context: *anyopaque = @ptrCast(&frame);
                operation.execute(context) catch |err| {
                    exec_err = err;
                    break;
                };
                pc += 1;
            },
        }
    }

    // Handle snapshot revert for failed nested calls
    if (!is_top_level_call and exec_err != null) {
        const should_revert = switch (exec_err.?) {
            ExecutionError.Error.STOP => false,
            ExecutionError.Error.RETURN => false,
            else => true,
        };
        if (should_revert) {
            host.revert_to_snapshot(snapshot_id);
        }
    }

    // Map error to success status
    const success = if (exec_err) |e| switch (e) {
        ExecutionError.Error.STOP => true,
        ExecutionError.Error.RETURN => true,
        else => false,
    } else false;

    // Store output in mini_output buffer to avoid conflicts with regular execution
    // Free previous mini output if any
    if (self.mini_output) |buf| {
        self.allocator.free(buf);
        self.mini_output = null;
    }

    // Copy current_output to mini_output if there's data
    const output = if (self.current_output.len > 0) blk: {
        const copy = try self.allocator.dupe(u8, self.current_output);
        self.mini_output = copy;
        if (copy.len >= 32) {
            const val = std.mem.readInt(u256, copy[0..32], .big);
            Log.debug("[call_mini] Returning output: len={}, value={x}, success={}", .{ copy.len, val, success });
        } else {
            Log.debug("[call_mini] Returning output: len={}, success={}", .{ copy.len, success });
        }
        break :blk copy;
    } else &.{};

    // Clear current_input to avoid interference with regular execution
    // Don't clear current_output as it might be needed by subsequent operations
    self.current_input = &.{};

    return CallResult{
        .success = success,
        .gas_left = frame.gas_remaining,
        .output = output,
    };
}
