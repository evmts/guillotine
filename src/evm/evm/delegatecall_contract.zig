const std = @import("std");
const primitives = @import("primitives");
const CallResult = @import("call_result.zig").CallResult;
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const ExecutionContext = @import("../execution_context.zig").ExecutionContext;
const CodeAnalysis = @import("../analysis.zig");
const ChainRules = @import("../execution_context.zig").ChainRules;

pub const DelegatecallContractError = std.mem.Allocator.Error || ExecutionError.Error || @import("../state/database_interface.zig").DatabaseError;

/// Execute a DELEGATECALL operation.
/// Executes the target contract's code in the current contract's context.
/// This means:
/// - Storage operations affect the current contract's storage
/// - msg.sender and msg.value are preserved from the parent call
/// - The current contract's address is used for ADDRESS opcode
/// - No value transfer occurs (DELEGATECALL has no value parameter)
///
/// @param current The current contract's address (where storage operations will occur)
/// @param code_address The address of the contract whose code will be executed
/// @param caller The original caller to preserve (msg.sender)
/// @param value The original value to preserve (msg.value)
/// @param input The input data for the call
/// @param gas The gas limit for the execution
/// @param is_static Whether this is part of a static call chain
pub fn delegatecall_contract(self: *Vm, current: primitives.Address.Address, code_address: primitives.Address.Address, caller: primitives.Address.Address, value: u256, input: []const u8, gas: u64, is_static: bool) DelegatecallContractError!CallResult {
    @branchHint(.likely);

    Log.debug("VM.delegatecall_contract: DELEGATECALL from {any} to {any}, caller={any}, value={}, gas={}, static={}", .{ current, code_address, caller, value, gas, is_static });

    // Check call depth limit (1024)
    if (self.depth >= 1024) {
        @branchHint(.unlikely);
        Log.debug("VM.delegatecall_contract: Call depth limit exceeded", .{});
        return CallResult{ .success = false, .gas_left = gas, .output = null };
    }

    // Get the target contract's code
    const code = self.state.get_code(code_address);
    Log.debug("VM.delegatecall_contract: Got code for {any}, len={}", .{ code_address, code.len });

    if (code.len == 0) {
        // Delegating to empty contract - this is successful but does nothing
        Log.debug("VM.delegatecall_contract: Delegating to empty contract", .{});
        return CallResult{ .success = true, .gas_left = gas, .output = null };
    }

    // Calculate intrinsic gas for the delegatecall
    // Base cost is 100 gas for DELEGATECALL
    const intrinsic_gas: u64 = 100;
    if (gas < intrinsic_gas) {
        @branchHint(.unlikely);
        Log.debug("VM.delegatecall_contract: Insufficient gas for delegatecall", .{});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    }

    const execution_gas = gas - intrinsic_gas;
    Log.debug("VM.delegatecall_contract: Starting execution with gas={}, intrinsic_gas={}, execution_gas={}", .{ gas, intrinsic_gas, execution_gas });

    // Create code analysis for the target contract bytecode
    var analysis = CodeAnalysis.from_code(self.allocator, code, &self.table) catch |err| {
        Log.debug("VM.delegatecall_contract: Code analysis failed with error: {}", .{err});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer analysis.deinit();

    // Create execution context for DELEGATECALL execution
    // IMPORTANT: For DELEGATECALL:
    // - Storage operations use current contract's address (passed as contract_address)
    // - The code being executed comes from code_address
    // - CALLER opcode should return the preserved caller
    // - CALLVALUE opcode should return the preserved value
    // - ADDRESS opcode should return current contract's address
    var context = ExecutionContext.init(
        execution_gas, // gas remaining
        is_static, // static call flag 
        @intCast(self.depth), // call depth
        current, // current contract's address (for storage operations and ADDRESS opcode)
        &analysis, // code analysis for the target code
        &self.access_list, // access list
        self.state.to_database_interface(), // database interface
        self.chain_rules, // chain rules
        null, // self_destruct (not supported in this context)
        input, // input data
        self.allocator, // allocator
    ) catch |err| {
        Log.debug("VM.delegatecall_contract: ExecutionContext creation failed with error: {}", .{err});
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer context.deinit();

    // TODO: Execute the contract using the ExecutionContext
    // This would require implementing a new execution method that works with ExecutionContext
    // For DELEGATECALL, we need to preserve caller and value from parent context
    // For now, return a failure indicating this isn't implemented yet
    Log.debug("VM.delegatecall_contract: Delegatecall execution with ExecutionContext not yet implemented", .{});
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
    Log.debug("VM.delegatecall_contract: Delegatecall completed (placeholder implementation), gas_left={}", .{result.gas_left});

    // The intrinsic gas is consumed, so we don't add it back to gas_left  
    return result;
}
