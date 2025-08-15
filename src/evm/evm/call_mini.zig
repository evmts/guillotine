const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;
const Host = @import("../host.zig").Host;
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const primitives = @import("primitives");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
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
    var call_value: primitives.u256 = undefined;

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
    var remaining_gas = call_gas;
    if (is_top_level_call) {
        const GasConstants = @import("primitives").GasConstants;
        const base_cost = GasConstants.TxGas;
        
        if (remaining_gas < base_cost) {
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        }
        remaining_gas -= base_cost;
    }

    // Check for precompiles
    if (precompile_addresses.get_precompile_id_checked(call_address)) |precompile_id| {
        const precompile_result = self.execute_precompile_call_by_id(precompile_id, call_input, remaining_gas, call_is_static) catch |err| {
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
            return CallResult{ .success = false, .gas_left = remaining_gas, .output = &.{} };
        }
    }

    // Pre-warm addresses for Berlin
    if (self.chain_rules.is_berlin) {
        const addresses_to_warm = [_]primitives.Address.Address{ call_address, call_caller };
        self.access_list.pre_warm_addresses(&addresses_to_warm) catch {};
    }

    // Simple execution without analysis - use bitvector for jumpdest validation
    var pc: usize = 0;
    var stack = try @import("../stack/stack.zig").Stack.init(self.allocator);
    defer stack.deinit(self.allocator);
    var memory = try Memory.init(self.allocator, 1024, @import("../constants/memory_limits.zig").MAX_MEMORY_SIZE);
    defer memory.deinit();
    
    // Use DynamicBitSet for jumpdest tracking like analysis does
    var jumpdest_bitmap = try std.DynamicBitSet.initEmpty(self.allocator, call_code.len);
    defer jumpdest_bitmap.deinit();
    
    // Pre-scan for jumpdests using same logic as analysis
    var scan_pc: usize = 0;
    while (scan_pc < call_code.len) {
        const op = call_code[scan_pc];
        
        // Mark JUMPDEST positions in bitmap
        if (op == @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
            jumpdest_bitmap.set(scan_pc);
        }
        
        // Skip push data
        if (opcode_mod.is_push(op)) {
            const push_size = opcode_mod.get_push_size(op);
            scan_pc += push_size;
        }
        scan_pc += 1;
    }
    
    // Convert bitmap to JumpdestArray for efficient validation
    const size_buckets = @import("../size_buckets.zig");
    var jumpdest_array = try size_buckets.JumpdestArray.from_bitmap(self.allocator, &jumpdest_bitmap, call_code.len);
    defer jumpdest_array.deinit(self.allocator);

    // Main execution loop
    var exec_err: ?ExecutionError.Error = null;
    const was_executing = self.is_executing;
    self.is_executing = true;
    defer self.is_executing = was_executing;
    
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
        if (remaining_gas < operation.constant_gas) {
            exec_err = ExecutionError.Error.OutOfGas;
            break;
        }
        remaining_gas -= operation.constant_gas;
        
        // Check stack requirements
        if (stack.size() < operation.min_stack) {
            exec_err = ExecutionError.Error.StackUnderflow;
            break;
        }
        // max_stack represents the net stack effect after operation
        // We need to ensure we don't exceed 1024 after the operation
        const stack_after = stack.size() - operation.min_stack + operation.max_stack;
        if (stack_after > 1024) {
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
                const dest = try stack.pop();
                if (dest > call_code.len) {
                    exec_err = ExecutionError.Error.InvalidJump;
                    break;
                }
                const dest_usize = @as(usize, @intCast(dest));
                if (!jumpdest_array.is_valid_jumpdest(dest_usize)) {
                    exec_err = ExecutionError.Error.InvalidJump;
                    break;
                }
                pc = dest_usize;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.JUMPI) => {
                const dest = try stack.pop();
                const condition = try stack.pop();
                if (condition != 0) {
                    if (dest > call_code.len) {
                        exec_err = ExecutionError.Error.InvalidJump;
                        break;
                    }
                    const dest_usize = @as(usize, @intCast(dest));
                    if (!jumpdest_array.is_valid_jumpdest(dest_usize)) {
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
                try stack.append(@intCast(pc));
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.RETURN) => {
                const offset = try stack.pop();
                const size = try stack.pop();
                
                // Get return data from memory
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = try memory.get_slice(offset_usize, size_usize);
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
                const offset = try stack.pop();
                const size = try stack.pop();
                
                // Get revert data from memory
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = try memory.get_slice(offset_usize, size_usize);
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
            @intFromEnum(opcode_mod.Enum.ADD) => {
                const a = try stack.pop();
                const b = try stack.pop();
                const result = a +% b; // Wrapping addition
                try stack.append(result);
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.MUL) => {
                const a = try stack.pop();
                const b = try stack.pop();
                const result = a *% b; // Wrapping multiplication
                try stack.append(result);
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.SUB) => {
                const a = try stack.pop();
                const b = try stack.pop();
                const result = a -% b; // Wrapping subtraction
                try stack.append(result);
                pc += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.DIV) => {
                const a = try stack.pop();
                const b = try stack.pop();
                const result = if (b == 0) 0 else a / b;
                try stack.append(result);
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
                    var value: primitives.u256 = 0;
                    const data_start = pc + 1;
                    const data_end = @min(data_start + push_size, call_code.len);
                    const data = call_code[data_start..data_end];
                    
                    // Convert bytes to primitives.u256 (big-endian)
                    for (data) |byte| {
                        value = (value << 8) | byte;
                    }
                    
                    try stack.append(value);
                    pc += 1 + push_size;
                    continue;
                }
                
                // For simplicity, mini EVM only supports basic opcodes
                // More complex opcodes would need proper frame/context setup
                exec_err = ExecutionError.Error.OpcodeNotImplemented;
                break;
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
        .gas_left = remaining_gas,
        .output = output,
    };
}