const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;
const Host = @import("../host.zig").Host;
const StackFrame = @import("../stack_frame.zig").StackFrame;
const Frame = StackFrame;
const Evm = @import("../evm.zig");
const interpret2 = @import("interpret2.zig").interpret2;
const primitives = @import("primitives");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const MAX_INPUT_SIZE = 131072; // 128KB
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;
const MAX_CALL_DEPTH = @import("../constants/evm_limits.zig").MAX_CALL_DEPTH;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
// InstructionMetadata no longer exists - using bucketed system

pub fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Initialize frame stack for top-level call
    self.frames.clearRetainingCapacity();
    return _call(self, params, true);
}
pub fn inner_call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Check max depth with cold branch hint
    if (self.frames.items.len >= MAX_CALL_DEPTH) {
        @branchHint(.cold);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }
    
    // Push a placeholder frame (will be filled by _call)
    // We need to reserve space but the actual frame will be created in _call
    try self.frames.append(undefined);
    const result = _call(self, params, false) catch |err| {
        // Pop the frame on error
        _ = self.frames.pop();
        return err;
    };
    
    // Pop the frame on successful completion
    if (self.frames.pop()) |frame| {
        var frame_copy = frame;
        frame_copy.deinit(self.allocator);
    }
    
    return result;
}

/// EVM execution using the new interpret2 interpreter with tailcall dispatch
/// This wraps interpret2 similar to how call wraps interpret
pub inline fn _call(self: *Evm, params: CallParams, comptime is_top_level_call: bool) ExecutionError.Error!CallResult {
    const Log = @import("../log.zig");
    Log.debug("[call] Starting execution with interpret2", .{});

    // host is a virtual interface back to the evm
    // so the opcodes can recursively call into the evm
    // Host also holds on to rarely accessed state to keep
    // Frame lean
    const host = Host.init(self);

    const snapshot_id = if (!is_top_level_call) host.create_snapshot() else 0;

    // Extract call parameters
    var call_address: primitives.Address.Address = undefined;
    var call_code: []const u8 = undefined;
    var call_input: []const u8 = undefined;
    var call_gas: u64 = undefined;
    var call_is_static: bool = undefined;
    var call_caller: primitives.Address.Address = undefined;
    var call_value: u256 = undefined;

    // Handle CREATE/CREATE2 differently as they need special processing
    switch (params) {
        .create, .create2 => {
            // For CREATE operations, delegate to the standard create_contract method
            // as interpret2 isn't designed to handle deployment bytecode
            Log.debug("[call] CREATE operation - delegating to standard create_contract", .{});

            const caller = if (params == .create) params.create.caller else params.create2.caller;
            const value = if (params == .create) params.create.value else params.create2.value;
            const init_code = if (params == .create) params.create.init_code else params.create2.init_code;
            const gas = if (params == .create) params.create.gas else params.create2.gas;

            const nonce = self.state.get_nonce(caller);
            const new_address = primitives.Address.get_contract_address(caller, nonce);
            _ = try self.state.increment_nonce(caller);
            const result = try self.create_contract_at(caller, value, init_code, gas, new_address);
            return CallResult{
                .success = result.status == .Success,
                .gas_left = result.gas_left,
                .output = result.output orelse &.{},
            };
        },
        .call => |call_data| {
            call_address = call_data.to;
            call_code = self.state.get_code(call_data.to);
            Log.debug("[call] Retrieved code for address: len={}", .{call_code.len});
            if (call_code.len > 0) {
                Log.debug("[call] First 10 bytes of code: {any}", .{std.fmt.fmtSliceHexLower(call_code[0..@min(10, call_code.len)])});
            }
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
            Log.debug("[call] Unsupported call type", .{});
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        },
    }

    // Validate inputs
    if (call_input.len > MAX_INPUT_SIZE or call_code.len > MAX_CODE_SIZE) {
        if (self.frames.items.len > 0) host.revert_to_snapshot(snapshot_id);
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
            if (self.frames.items.len > 0) host.revert_to_snapshot(snapshot_id);
            return switch (err) {
                else => CallResult{ .success = false, .gas_left = 0, .output = &.{} },
            };
        };

        if (self.frames.items.len > 0 and !precompile_result.success) {
            host.revert_to_snapshot(snapshot_id);
        }

        return precompile_result;
    }

    // Initialize frame state for top-level calls
    if (is_top_level_call) {
        // Frame depth is now managed by frames.items.len
        self.access_list.clear();

        self.self_destruct.deinit();
        self.self_destruct = SelfDestruct.init(self.allocator);

        self.created_contracts.deinit();
        self.created_contracts = CreatedContracts.init(self.allocator);

        // Clear input state
        self.current_input = &.{};

        // Frame stack is now always available as ArrayList
    } else {
        // Nested call - depth is already managed by inner_call frame push
        // The frame was already pushed in inner_call, so depth = frames.items.len
    }

    // Prewarm addresses for Berlin
    if (self.chain_rules.is_berlin) {
        const addresses_to_warm = [_]primitives.Address.Address{ call_address, call_caller };
        self.access_list.pre_warm_addresses(&addresses_to_warm) catch |err| {
            Log.debug("[call] Failed to warm addresses: {any}", .{err});
        };
    }

    // Create a StackFrame for interpret2
    const SimpleAnalysis = @import("analysis2.zig").SimpleAnalysis;

    // Create analysis with bytecode - interpret2 will analyze and fill the rest
    var empty_block_boundaries = std.bit_set.DynamicBitSet.initEmpty(self.allocator, 0) catch return error.OutOfMemory;
    defer empty_block_boundaries.deinit();

    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = call_code,
        .inst_count = 0,
        .block_boundaries = empty_block_boundaries,
        .jump_table = &self.table,
        .bucket_indices = &.{},
        .u16_bucket = &.{},
        .u32_bucket = &.{},
        .u64_bucket = &.{},
        .u256_bucket = &.{},
    };
    // No longer need metadata - using bucket system
    const empty_ops: []*const fn (*StackFrame) @import("../execution/execution_error.zig").Error!noreturn = &.{};

    // Create frame and store it appropriately
    var frame_storage: StackFrame = undefined;
    var frame: *StackFrame = undefined;
    
    if (is_top_level_call) {
        // Top-level call: use local storage
        frame_storage = try StackFrame.init(
            gas_after_base,
            call_address,
            empty_analysis,
            empty_ops,
            host,
            self.state.database,
            self.allocator,
            call_is_static,
            call_caller,
            call_value,
            call_input,
        );
        frame = &frame_storage;
        defer frame.deinit(self.allocator);
    } else {
        // Nested call: store frame in the frames array (placeholder was pushed by inner_call)
        const frame_index = self.frames.items.len - 1;
        self.frames.items[frame_index] = try StackFrame.init(
            gas_after_base,
            call_address,
            empty_analysis,
            empty_ops,
            host,
            self.state.database,
            self.allocator,
            call_is_static,
            call_caller,
            call_value,
            call_input,
        );
        frame = &self.frames.items[frame_index];
        // Note: frame cleanup handled by inner_call pop
    }

    // Store the current input for the host interface to access
    self.current_input = call_input;

    // Main execution with interpret2
    var exec_err: ?ExecutionError.Error = null;
    // Call interpret2 which will handle its own analysis and tailcall dispatch
    Log.debug("[call] About to call interpret2 with code.len={}", .{call_code.len});
    interpret2(frame) catch |err| {
        Log.debug("[call] interpret2 ended with error: {any}", .{err});
        exec_err = err;
    };

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

    // Return frame-owned output view; callers must not free (same as standard call)
    const output = if (frame.output_buffer.len > 0) frame.output_buffer else &.{};

    // Clear current_input to avoid interference
    self.current_input = &.{};

    // Frame depth restoration is handled by inner_call pop
    // No manual depth management needed here

    return CallResult{
        .success = success,
        .gas_left = frame.gas_remaining,
        .output = output,
    };
}
