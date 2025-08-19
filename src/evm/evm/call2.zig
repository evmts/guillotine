const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;
const Host = @import("../host.zig").Host;
const StackFrame = @import("../stack_frame.zig").StackFrame;
const Frame = StackFrame;
const Evm = @import("../evm.zig");
const StackFrameMetadata = Evm.StackFrameMetadata;
const interpret2 = @import("interpret2.zig").interpret2;
const primitives = @import("primitives");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const MAX_INPUT_SIZE = 131072; // 128KB
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;
const MAX_CALL_DEPTH = @import("../constants/evm_limits.zig").MAX_CALL_DEPTH;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;

pub fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    return _call(self, params, true);
}
pub fn inner_call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    return _call(self, params, false);
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

    // Define call context struct for better data locality
    const CallContext = struct {
        address: primitives.Address.Address,
        input: []const u8,
        gas: u64,
        is_static: bool,
        caller: primitives.Address.Address,
        value: u256,
    };

    // Extract parameters with most common cases first
    const call_context = switch (params) {
        .create, .create2 => {
            // For CREATE operations, delegate to the standard create_contract method
            // as interpret2 isn't designed to handle deployment bytecode
            Log.debug("[call] CREATE operation - delegating to standard create_contract", .{});

            const caller = if (params == .create) params.create.caller else params.create2.caller;
            const value = if (params == .create) params.create.value else params.create2.value;
            const init_code = if (params == .create) params.create.init_code else params.create2.init_code;
            const gas = if (params == .create) params.create.gas else params.create2.gas;

            // Use the standard create_contract for deployment
            const result = self.create_contract(caller, value, init_code, gas) catch |err| {
                Log.debug("[call] create_contract failed: {any}", .{err});
                return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
            };

            return CallResult{
                .success = result.status == .Success,
                .gas_left = result.gas_left,
                .output = result.output orelse &.{},
            };
        },
        .call => |call_data| CallContext{
            .address = call_data.to,
            .input = call_data.input,
            .gas = call_data.gas,
            .is_static = false,
            .caller = call_data.caller,
            .value = call_data.value,
        },
        .staticcall => |call_data| CallContext{
            .address = call_data.to,
            .input = call_data.input,
            .gas = call_data.gas,
            .is_static = true,
            .caller = call_data.caller,
            .value = 0,
        },
        else => {
            Log.debug("[call] Unsupported call type", .{});
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        },
    };

    // Get code once after extracting address
    const call_code = self.state.get_code(call_context.address);
    Log.debug("[call] Retrieved code for address: len={}", .{call_code.len});
    if (call_code.len > 0) {
        Log.debug("[call] First 10 bytes of code: {any}", .{std.fmt.fmtSliceHexLower(call_code[0..@min(10, call_code.len)])});
    }

    if (call_context.input.len > MAX_INPUT_SIZE or call_code.len > MAX_CODE_SIZE) {
        if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
    }

    var gas_after_base = call_context.gas;
    if (is_top_level_call) {
        const GasConstants = @import("primitives").GasConstants;
        const base_cost = GasConstants.TxGas;

        if (gas_after_base < base_cost) {
            return CallResult{ .success = false, .gas_left = 0, .output = &.{} };
        }
        gas_after_base -= base_cost;
    }

    if (precompile_addresses.get_precompile_id_checked(call_context.address)) |precompile_id| {
        const precompile_result = self.execute_precompile_call_by_id(precompile_id, call_context.input, gas_after_base, call_context.is_static) catch |err| {
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

    if (is_top_level_call) {
        self.current_frame_depth = 0;
        self.access_list.clear();

        self.self_destruct.deinit();
        self.self_destruct = SelfDestruct.init(self.allocator);

        self.created_contracts.deinit();
        self.created_contracts = CreatedContracts.init(self.allocator);

        self.current_output = &.{};
        self.current_input = &.{};

        if (self.frame_stack == null) {}
    } else {
        const new_depth = self.current_frame_depth + 1;
        if (new_depth >= MAX_CALL_DEPTH) {
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = gas_after_base, .output = &.{} };
        }
        self.current_frame_depth = new_depth;
        defer self.current_frame_depth -= 1;
    }

    if (self.chain_rules.is_berlin) {
        const addresses_to_warm = [_]primitives.Address.Address{ call_context.address, call_context.caller };
        self.access_list.pre_warm_addresses(&addresses_to_warm) catch |err| {
            Log.debug("[call] Failed to warm addresses: {any}", .{err});
        };
    }

    const analysis2 = @import("analysis2.zig");

    // Use tiered pre-allocation based on bytecode size
    var frame = StackFrame.init_with_bytecode_size(
        call_code.len,
        gas_after_base,
        call_context.address,
        host,
        self.state.database,
        self.allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BufferTooSmall, error.MisalignedBuffer => {
            // These should never happen with our allocation strategy
            unreachable;
        },
    };
    defer frame.deinit();
    
    // Pre-allocate buffers from frame's buffer allocator
    const buffer_allocator = frame.get_buffer_allocator();
    
    // Allocate analysis arrays
    const analysis_alloc = analysis2.calculate_analysis_allocation(call_code.len);
    const metadata_alloc = analysis2.calculate_metadata_allocation(call_code.len);
    const ops_alloc = analysis2.calculate_ops_allocation(call_code.len);
    
    // Debug assertions: verify allocation info is reasonable
    std.debug.assert(analysis_alloc.size > 0);
    std.debug.assert(metadata_alloc.size > 0);
    std.debug.assert(ops_alloc.size > 0);
    
    const inst_to_pc = try buffer_allocator.alloc(u16, call_code.len);
    const pc_to_inst = try buffer_allocator.alloc(u16, call_code.len);
    const metadata = try buffer_allocator.alloc(u32, call_code.len);
    const ops = try buffer_allocator.alloc(*const anyopaque, call_code.len + 1);
    
    // Debug assertions: verify allocations succeeded
    std.debug.assert(inst_to_pc.len >= call_code.len);
    std.debug.assert(pc_to_inst.len >= call_code.len);
    std.debug.assert(metadata.len >= call_code.len);
    std.debug.assert(ops.len >= call_code.len + 1);
    
    // Prepare analysis with pre-allocated buffers
    const prep_result = analysis2.prepare_with_buffers(
        inst_to_pc,
        pc_to_inst,
        metadata,
        ops,
        call_code,
    ) catch |err| switch (err) {
        error.CodeTooLarge => return error.MAX_CONTRACT_SIZE,
    };
    
    // Update frame with prepared data
    frame.analysis = prep_result.analysis;
    frame.metadata = prep_result.metadata;
    frame.ops = prep_result.ops;

    if (self.current_frame_depth < MAX_CALL_DEPTH) {
        self.frame_metadata[self.current_frame_depth] = StackFrameMetadata{
            .caller = call_context.caller,
            .value = call_context.value,
            .input_buffer = call_context.input,
            .output_buffer = &.{},
            .is_static = call_context.is_static,
            .depth = self.current_frame_depth,
        };
    }

    // Store the current input for the host interface to access
    self.current_input = call_context.input;

    // Main execution with interpret2
    // Interpret always throws an error to end execution even on success.
    // TODO make it return a success enum instead on succcess
    var exec_err: ExecutionError.Error = undefined;
    interpret2(&frame) catch |err| {
        Log.debug("[call] interpret2 ended with error: {any}", .{err});
        exec_err = err;
    };

    // Handle snapshot revert for failed nested calls - flatten conditions
    if (is_top_level_call) {
        // Top level calls don't need snapshot revert
    } else {
        // Only revert on actual errors, not STOP/RETURN
        const is_success = switch (exec_err) {
            ExecutionError.Error.STOP, ExecutionError.Error.RETURN => true,
            else => false,
        };
        if (!is_success) {
            host.revert_to_snapshot(snapshot_id);
        }
    }

    const success = switch (exec_err) {
        ExecutionError.Error.STOP => true,
        ExecutionError.Error.RETURN => true,
        else => false,
    };

    const output = if (self.current_output.len > 0) self.current_output else &.{};

    self.current_input = &.{};

    return CallResult{
        .success = success,
        .gas_left = frame.gas_remaining,
        .output = output,
    };
}
