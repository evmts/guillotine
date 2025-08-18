const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("../host.zig").CallParams;
const Host = @import("../host.zig").Host;
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const interpret2 = @import("interpret2.zig").interpret2;
const primitives = @import("primitives");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const MAX_INPUT_SIZE = 131072; // 128KB
const MAX_CODE_SIZE = @import("../opcodes/opcode.zig").MAX_CODE_SIZE;
const MAX_CALL_DEPTH = @import("../constants/evm_limits.zig").MAX_CALL_DEPTH;
const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;

/// EVM execution using the new interpret2 interpreter with tailcall dispatch
/// This wraps interpret2 similar to how call wraps interpret
pub fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    const Log = @import("../log.zig");
    Log.debug("[call] Starting execution with interpret2", .{});

    // Create host interface
    const host = Host.init(self);

    // Check if top-level call
    const is_top_level_call = !self.is_currently_executing();
    Log.debug("[call] is_top_level_call={}, is_executing={}, current_frame_depth={}", .{ is_top_level_call, self.is_currently_executing(), self.current_frame_depth });
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
        // Nested call - check depth and increment
        const new_depth = self.current_frame_depth + 1;
        if (new_depth >= MAX_CALL_DEPTH) {
            if (self.current_frame_depth > 0) host.revert_to_snapshot(snapshot_id);
            return CallResult{ .success = false, .gas_left = gas_after_base, .output = &.{} };
        }
        // CRITICAL: Actually update the frame depth for nested calls
        self.current_frame_depth = new_depth;
    }

    // Prewarm addresses for Berlin
    if (self.chain_rules.is_berlin) {
        const addresses_to_warm = [_]primitives.Address.Address{ call_address, call_caller };
        self.access_list.pre_warm_addresses(&addresses_to_warm) catch |err| {
            Log.debug("[call] Failed to warm addresses: {any}", .{err});
        };
    }

    // Create a minimal dummy CodeAnalysis for Frame compatibility
    // interpret2 does its own analysis internally, so this is just to satisfy Frame's requirements
    const analysis_mod = @import("../analysis.zig");
    const CodeAnalysis = analysis_mod.CodeAnalysis;
    const size_buckets = @import("../size_buckets.zig");

    // Create empty size buckets for dummy analysis
    const empty_size0_counts = size_buckets.Size0Counts{
        .noop = 0,
        .conditional_jump_unresolved = 0,
        .conditional_jump_invalid = 0,
    };
    const empty_size2_counts = size_buckets.Size2Counts{
        .jump_pc = 0,
        .conditional_jump_pc = 0,
        .pc = 0,
    };
    const empty_size8_counts = size_buckets.Size8Counts{
        .real_opcodes = 0,
        .block_info = 0,
    };
    const empty_size16_counts = size_buckets.Size16Counts{
        .word = 0,
    };

    var dummy_analysis = CodeAnalysis{
        .code = call_code,
        .code_len = call_code.len,
        .instructions = &.{},
        .size2_instructions = &.{},
        .size8_instructions = &.{},
        .size16_instructions = &.{},
        .size0_counts = empty_size0_counts,
        .size2_counts = empty_size2_counts,
        .size8_counts = empty_size8_counts,
        .size16_counts = empty_size16_counts,
        .pc_to_block_start = &.{},
        .jumpdest_array = size_buckets.JumpdestArray{
            .positions = &.{},
            .code_len = call_code.len,
        },
        .inst_jump_type = &.{},
        .inst_to_pc = &.{},
        .allocator = self.allocator,
    };

    // Create frame - interpret2 doesn't use CodeAnalysis, but Frame requires it
    const contract_addr_for_frame = call_address;
    var frame = try Frame.init(
        gas_after_base,
        call_is_static,
        @intCast(self.current_frame_depth),
        contract_addr_for_frame,
        call_caller,
        call_value,
        &dummy_analysis,
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

    // Main execution with interpret2
    var exec_err: ?ExecutionError.Error = null;
    // Call interpret2 which will handle its own analysis and tailcall dispatch
    Log.debug("[call] About to call interpret2 with code.len={}", .{call_code.len});
    interpret2(&frame, call_code) catch |err| {
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

    // Return VM-owned view; callers must not free (same as standard call)
    const output = if (self.current_output.len > 0) self.current_output else &.{};

    // Clear current_input to avoid interference
    self.current_input = &.{};

    // Restore frame depth for nested calls
    if (!is_top_level_call) {
        self.current_frame_depth -= 1;
    }

    return CallResult{
        .success = success,
        .gas_left = frame.gas_remaining,
        .output = output,
    };
}

/// Alias for backward compatibility with tests and benchmarks
/// that still reference call_mini
pub const call_mini = call;
