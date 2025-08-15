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
pub inline fn call_mini(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    const Log = @import("../log.zig");
    const opcode_mod = @import("../opcodes/opcode.zig");
    
    Log.debug("[call_mini] Starting simplified execution", .{});

    // Create host interface
    const host = Host.init(self);

    // Check if top-level call
    const is_top_level_call = !self.is_executing;
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

    // Initialize frame for execution
    if (is_top_level_call) {
        // Reset execution state
        self.current_frame_depth = 0;
        self.access_list.clear();
        self.self_destruct.deinit();
        self.self_destruct = SelfDestruct.init(self.allocator);
        self.created_contracts.deinit();
        self.created_contracts = CreatedContracts.init(self.allocator);
        self.current_output = &.{};

        // Allocate frame stack if needed
        if (self.frame_stack == null) {
            self.frame_stack = try self.allocator.alloc(Frame, MAX_CALL_DEPTH);
        }
    } else {
        // Nested call - check depth
        const new_depth = self.current_frame_depth + 1;
        if (new_depth >= MAX_CALL_DEPTH) {
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = gas_after_base, .output = &.{} };
        }
    }

    // Pre-warm addresses for Berlin
    if (self.chain_rules.is_berlin) {
        const addresses_to_warm = [_]primitives.Address.Address{ call_address, call_caller };
        self.access_list.pre_warm_addresses(&addresses_to_warm) catch {};
    }

    // Analyze code for jumpdest validation
    var analysis_owned = false;
    const analysis_ptr: *CodeAnalysis = blk: {
        Log.debug("[call_mini] Analyzing code directly", .{});
        var analysis_val = CodeAnalysis.from_code(self.allocator, call_code, &self.table) catch |err| {
            Log.err("[call_mini] Code analysis failed: {}", .{err});
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = gas_after_base, .output = &.{} };
        };
        const analysis_heap = self.allocator.create(CodeAnalysis) catch {
            analysis_val.deinit();
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = gas_after_base, .output = &.{} };
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

    // Main execution loop
    var exec_err: ?ExecutionError.Error = null;
    const was_executing = self.is_executing;
    self.is_executing = true;
    defer self.is_executing = was_executing;
    
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
        
        // Handle specific opcodes inline
        switch (op) {
            @intFromEnum(opcode_mod.Enum.STOP) => {
                exec_err = ExecutionError.Error.STOP;
                break;
            },
            @intFromEnum(opcode_mod.Enum.JUMP) => {
                const dest = try frame.stack.pop();
                if (dest > call_code.len) {
                    exec_err = ExecutionError.Error.InvalidJump;
                    break;
                }
                const dest_usize = @as(usize, @intCast(dest));
                if (!frame.valid_jumpdest(dest)) {
                    exec_err = ExecutionError.Error.InvalidJump;
                    break;
                }
                pc = dest_usize;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.JUMPI) => {
                const dest = try frame.stack.pop();
                const condition = try frame.stack.pop();
                if (condition != 0) {
                    if (dest > call_code.len) {
                        exec_err = ExecutionError.Error.InvalidJump;
                        break;
                    }
                    const dest_usize = @as(usize, @intCast(dest));
                    if (!frame.valid_jumpdest(dest)) {
                        exec_err = ExecutionError.Error.InvalidJump;
                        break;
                    }
                    pc = dest_usize;
                    continue;
                }
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.PC) => {
                try frame.stack.append(@intCast(pc));
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.RETURN) => {
                const offset = try frame.stack.pop();
                const size = try frame.stack.pop();
                
                // Get return data from memory
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = try frame.memory.get_slice(offset_usize, size_usize);
                    const output = try self.allocator.dupe(u8, data);
                    host.set_output(output) catch {
                        exec_err = ExecutionError.Error.DatabaseCorrupted;
                        break;
                    };
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
                    const output = try self.allocator.dupe(u8, data);
                    host.set_output(output) catch {
                        exec_err = ExecutionError.Error.DatabaseCorrupted;
                        break;
                    };
                }
                
                exec_err = ExecutionError.Error.REVERT;
                break;
            },
            @intFromEnum(opcode_mod.Enum.INVALID) => {
                exec_err = ExecutionError.Error.INVALID;
                break;
            },
            @intFromEnum(opcode_mod.Enum.JUMPDEST) => {
                // No-op, just advance
                pc += 1;
                continue;
            },
            else => {
                // For push opcodes, handle data
                if (opcode_mod.is_push(op)) {
                    const push_size = opcode_mod.get_push_size(op);
                    if (pc + push_size >= call_code.len) {
                        exec_err = ExecutionError.Error.OutOfOffset;
                        break;
                    }
                    
                    // Read push data
                    var value: u256 = 0;
                    const data_start = pc + 1;
                    const data_end = @min(data_start + push_size, call_code.len);
                    const data = call_code[data_start..data_end];
                    
                    // Convert bytes to primitives.u256 (big-endian)
                    for (data) |byte| {
                        value = (value << 8) | byte;
                    }
                    
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
                continue;
            },
        }
    }
    
    // Handle execution result
    if (exec_err == null and pc >= call_code.len) {
        // Fell off the end - treat as STOP
        exec_err = ExecutionError.Error.STOP;
    }
    
    // Revert snapshot for failed nested calls
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
    
    // Get output
    const output = self.allocator.dupe(u8, host.get_output()) catch &.{};
    
    // Determine success
    const success = if (exec_err) |e| switch (e) {
        ExecutionError.Error.STOP => true,
        ExecutionError.Error.RETURN => true,
        else => false,
    } else false;
    
    return CallResult{
        .success = success,
        .gas_left = frame.gas_remaining,
        .output = output,
    };
}