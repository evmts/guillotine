const std = @import("std");
const primitives = @import("primitives");
const CallResult = @import("call_result.zig").CallResult;
const precompiles = @import("../precompiles/precompiles.zig");
const precompile_addresses = @import("../precompiles/precompile_addresses.zig");
const Log = @import("../log.zig");
const EvmModule = @import("../evm.zig");
const EvmConfig = @import("../config.zig").EvmConfig;
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const CodeAnalysis = @import("../analysis.zig");
const ChainRules = @import("../frame.zig").ChainRules;
const Host = @import("../host.zig").Host;
const CallFrameAccessList = @import("../access_list/access_list.zig");
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
pub fn call_contract(comptime config: EvmConfig) type {
    return struct {
        pub fn callContractImpl(self: *EvmModule.Evm(config), caller: primitives.Address.Address, to: primitives.Address.Address, value: u256, input: []const u8, gas: u64, is_static: bool) CallContractError!CallResult {
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
    if (self.depth >= config.max_call_depth) {
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
    var analysis = CodeAnalysis.from_code(self.allocator, code, &config.opcodes.jump_table) catch |err| {
        Log.debug("VM.call_contract: Code analysis failed with error: {}", .{err});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer analysis.deinit();

    // Create host interface from self
    var host = Host.init(self);
    
    // Create temporary AccessList for Frame (different type from EVM's access_list)
    const Context = @import("../access_list/context.zig");
    const access_context = Context.init();
    var frame_access_list = CallFrameAccessList.init(self.allocator, access_context);
    defer frame_access_list.deinit();
    
    // Create execution context for the contract
    var context = Frame.init(
        execution_gas, // gas remaining
        is_static, // static call flag 
        @intCast(self.depth), // call depth
        to, // contract address
        caller, // caller address
        value, // value being transferred
        &analysis, // code analysis
        &frame_access_list, // access list
        &self.journal, // call journal
        &host, // host interface from self
        self.journal.create_snapshot(), // create new snapshot id
        self.state.database, // database interface
        self.chain_rules, // chain rules
        null, // self_destruct (not supported in this context)
        null, // created_contracts (not needed in isolated call)
        input, // input data
        self.allocator, // allocator
        null, // next_frame (no nested calls)
        false, // is_create_call
        false, // is_delegate_call
    ) catch |err| {
        Log.debug("VM.call_contract: Frame creation failed with error: {}", .{err});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer context.deinit();

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
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    }

    // When actual execution is implemented, this will process the real result
    Log.debug("VM.call_contract: Call completed (placeholder implementation), gas_left={}", .{result.gas_left});

    // The intrinsic gas is consumed, so we don't add it back to gas_left  
    return result;
        }
    };
}
