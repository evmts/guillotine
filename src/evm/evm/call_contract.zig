const std = @import("std");
const primitives = @import("primitives");
const CallResult = @import("call_result.zig").CallResult;
const precompiles = @import("../precompiles/precompiles.zig");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const Contract = @import("../frame/contract.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;

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
pub inline fn call_contract(self: *Vm, caller: primitives.Address.Address, to: primitives.Address.Address, value: u256, input: []const u8, gas: u64, is_static: bool) CallContractError!CallResult {
    @branchHint(.likely);

    Log.debug("VM.call_contract: Call from {any} to {any}, gas={}, static={}", .{ caller, to, gas, is_static });

    // Check if this is a precompile call
    if (precompile_addresses.get_precompile_id_checked(to)) |precompile_id| {
        Log.debug("VM.call_contract: Detected precompile call to {any} (ID {})", .{ to, precompile_id });
        return self.execute_precompile_call_by_id(precompile_id, input, gas, is_static);
    }

    // Regular contract call
    Log.debug("VM.call_contract: Regular contract call to {any}", .{to});

    // Check call depth limit (1024)
    if (self.depth >= 1024) {
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

    // Calculate code hash
    var hasher = Keccak256.init(.{});
    hasher.update(code);
    var code_hash: [32]u8 = undefined;
    hasher.final(&code_hash);

    // Create contract context for execution
    var contract = Contract.init(
        caller, // caller
        to, // address being called
        value, // value already transferred
        execution_gas, // gas for execution
        code, // contract code
        code_hash, // code hash
        input, // call data
        is_static, // static flag
    );
    defer contract.deinit(self.allocator, null);

    // Execute the contract
    Log.debug("VM.call_contract: About to execute contract with gas={}", .{execution_gas});
    const result = self.interpret(&contract, input, is_static) catch |err| {
        Log.debug("VM.call_contract: Execution failed with error: {}", .{err});

        // On error, revert value transfer
        if (value > 0) {
            const caller_balance = self.state.get_balance(caller);
            try self.state.set_balance(caller, caller_balance + value);
            const to_balance = self.state.get_balance(to);
            try self.state.set_balance(to, to_balance - value);
        }

        // For REVERT, we return partial gas
        if (err == ExecutionError.Error.REVERT) {
            // REVERT returns partial gas but no output data in error case
            return CallResult{ .success = false, .gas_left = contract.gas, .output = null };
        }

        // Other errors consume all gas
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer if (result.output) |out| self.allocator.free(out);

    Log.debug("VM.call_contract: Execution completed, status={}, gas_used={}, output_size={}", .{ result.status, result.gas_used, if (result.output) |o| o.len else 0 });

    // Prepare output
    const output = if (result.output) |out|
        try self.allocator.dupe(u8, out)
    else
        null;

    // Check execution status
    const success = switch (result.status) {
        .Success => true,
        .Revert => false,
        .Invalid => false,
        .OutOfGas => false,
    };

    // If execution failed, revert value transfer
    if (!success and value > 0) {
        const caller_balance = self.state.get_balance(caller);
        try self.state.set_balance(caller, caller_balance + value);
        const to_balance = self.state.get_balance(to);
        try self.state.set_balance(to, to_balance - value);
    }

    Log.debug("VM.call_contract: Call completed, success={}, gas_used={}, gas_left={}, output_size={}", .{ success, result.gas_used, result.gas_left, if (output) |o| o.len else 0 });

    // The intrinsic gas is consumed, so we don't add it back to gas_left
    return CallResult{ .success = success, .gas_left = result.gas_left, .output = output };
}
