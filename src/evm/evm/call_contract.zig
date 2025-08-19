const std = @import("std");
const primitives = @import("primitives");
const CallResult = @import("call_result.zig").CallResult;
const precompiles = @import("../precompiles/precompiles.zig");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const CodeAnalysis = @import("../analysis.zig").CodeAnalysis;
const ChainRules = @import("../hardforks/chain_rules.zig").ChainRules;
const Host = @import("../host.zig").Host;
const evm_limits = @import("../constants/evm_limits.zig");

pub const CallContractError = std.mem.Allocator.Error || ExecutionError.Error || @import("../state/database_interface.zig").DatabaseError;

/// Execute a CALL operation to another contract or precompile.
///
/// This method handles both regular contract calls and precompile calls.
/// For precompiles, it routes to the appropriate precompile implementation.
/// For regular contracts, it currently returns failure (TODO: implement contract execution).
///
/// @param caller The address initiating the call
/// @param to The address being called (may be a precompile)
/// @param value The amount of ETH being transferred (must be 0 for static calls)
/// @param input Input data for the call
/// @param gas Gas limit available for the call
/// @param is_static Whether this is a static call (no state changes allowed)
/// @return CallResult indicating success/failure and return data
pub fn call_contract(self: *Vm, caller: primitives.Address.Address, to: primitives.Address.Address, value: u256, input: []const u8, gas: u64, is_static: bool) CallContractError!CallResult {
    @branchHint(.likely);

    Log.debug("VM.call_contract: Call from {any} to {any}, gas={}, static={}", .{ caller, to, gas, is_static });

    // Check if this is a precompile call
    if (precompile_addresses.get_precompile_id_checked(to)) |precompile_id| {
        Log.debug("VM.call_contract: Detected precompile call to {any} (ID {})", .{ to, precompile_id });
        return self.execute_precompile_call_by_id(precompile_id, input, gas, is_static);
    }

    // Regular contract call
    Log.debug("VM.call_contract: Regular contract call to {any}", .{to});

    // Check call depth limit
    if (self.depth >= evm_limits.MAX_CALL_DEPTH) {
        @branchHint(.unlikely);
        Log.debug("VM.call_contract: Call depth limit exceeded", .{});
        return CallResult{ .success = false, .gas_left = gas, .output = null };
    }

    // Check if static call tries to send value
    if (is_static and value > 0) {
        @branchHint(.unlikely);
        Log.debug("VM.call_contract: Static call cannot transfer value", .{});
        return CallResult{ .success = false, .gas_left = gas, .output = null };
    }

    // Get the contract code
    const code = self.state.get_code(to);
    Log.debug("VM.call_contract: Got code for {any}, len={}", .{ to, code.len });

    if (code.len == 0) {
        // Calling empty contract - this is actually successful
        Log.debug("VM.call_contract: Calling empty contract", .{});

        // Transfer value if any
        if (value > 0) {
            const caller_balance = self.state.get_balance(caller);
            if (caller_balance < value) {
                @branchHint(.unlikely);
                Log.debug("VM.call_contract: Insufficient balance for value transfer", .{});
                return CallResult{ .success = false, .gas_left = gas, .output = null };
            }

            try self.state.set_balance(caller, caller_balance - value);
            const to_balance = self.state.get_balance(to);
            try self.state.set_balance(to, to_balance + value);
        }

        return CallResult{ .success = true, .gas_left = gas, .output = null };
    }

    // Calculate intrinsic gas for the call
    // Base cost is 100 gas for CALL
    const intrinsic_gas: u64 = 100;
    if (gas < intrinsic_gas) {
        @branchHint(.unlikely);
        Log.debug("VM.call_contract: Insufficient gas for call", .{});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    }

    const execution_gas = gas - intrinsic_gas;
    Log.debug("VM.call_contract: Starting execution with gas={}, intrinsic_gas={}, execution_gas={}", .{ gas, intrinsic_gas, execution_gas });

    // Transfer value before execution (if any)
    if (value > 0) {
        const caller_balance = self.state.get_balance(caller);
        if (caller_balance < value) {
            Log.debug("VM.call_contract: Insufficient balance for value transfer", .{});
            return CallResult{ .success = false, .gas_left = gas, .output = null };
        }

        try self.state.set_balance(caller, caller_balance - value);
        const to_balance = self.state.get_balance(to);
        try self.state.set_balance(to, to_balance + value);
    }

    // Create code analysis for the contract bytecode
    var analysis = CodeAnalysis.from_code(self.allocator, code, &self.table) catch |err| {
        Log.debug("VM.call_contract: Code analysis failed with error: {any}", .{err});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer analysis.deinit();

    // Create host interface from self
    const host = Host.init(self);

    // Create snapshot before creating the frame
    const snapshot_id = host.create_snapshot();

    // Create execution context for the contract
    var context = Frame.init(execution_gas, // gas remaining
        to, // contract address
        analysis.analysis, // simple analysis
        analysis.metadata, // metadata array
        &[_]*const anyopaque{}, // empty ops array - interpret2 will set this up
        host, // host interface from self
        self.state.database, // database interface
        self.allocator // allocator
    ) catch |err| {
        Log.debug("VM.call_contract: Frame creation failed with error: {any}", .{err});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer context.deinit(self.allocator);

    // Set up frame metadata
    if (self.current_frame_depth < @import("../evm.zig").MAX_CALL_DEPTH) {
        self.frame_metadata[self.current_frame_depth] = @import("../evm.zig").StackFrameMetadata{
            .caller = caller,
            .value = value,
            .input_buffer = input,
            .output_buffer = &.{},
            .is_static = is_static,
            .depth = self.current_frame_depth,
        };
    }

    // TODO: Execute the contract using the Frame
    // This would require implementing a new execution method that works with Frame
    // For now, return a failure indicating this isn't implemented yet
    Log.debug("VM.call_contract: Contract execution with Frame not yet implemented", .{});
    const result = CallResult{ .success = false, .gas_left = execution_gas, .output = null };

    // Handle execution errors (placeholder)
    const err_handler_start = false;
    if (err_handler_start) {
        // This error handling block is now a placeholder
        // When actual execution is implemented, this will handle real errors
        _ = ExecutionError.Error.REVERT;
        host.revert_to_snapshot(snapshot_id);
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    }

    // When actual execution is implemented, this will process the real result
    Log.debug("VM.call_contract: Call completed (placeholder implementation), gas_left={}", .{result.gas_left});

    // The intrinsic gas is consumed, so we don't add it back to gas_left
    return result;
}
