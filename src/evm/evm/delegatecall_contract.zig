const std = @import("std");
const primitives = @import("primitives");
const CallResult = @import("call_result.zig").CallResult;
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const Contract = @import("../frame/contract.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Keccak256 = std.crypto.hash.sha3.Keccak256;

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

    // Calculate code hash
    var hasher = Keccak256.init(.{});
    hasher.update(code);
    var code_hash: [32]u8 = undefined;
    hasher.final(&code_hash);

    // Create contract context for DELEGATECALL execution
    // IMPORTANT: For DELEGATECALL:
    // - Storage operations use current contract's address
    // - CALLER opcode returns the preserved caller (not current)
    // - CALLVALUE opcode returns the preserved value
    // - ADDRESS opcode returns current contract's address
    var contract = Contract.init(
        caller, // preserve original caller (for CALLER opcode)
        current, // current contract's address (for ADDRESS opcode and storage)
        value, // preserve original value (for CALLVALUE opcode)
        execution_gas, // gas for execution
        code, // target contract's code
        code_hash, // code hash
        input, // call data
        is_static, // static flag
    );
    defer contract.deinit(self.allocator, null);

    // Analyze jump destinations before execution
    contract.analyze_jumpdests(self.allocator);

    // Execute the contract in the current context
    Log.debug("VM.delegatecall_contract: About to execute contract with gas={}", .{execution_gas});
    const result = self.interpret(&contract, input, is_static) catch |err| {
        Log.debug("VM.delegatecall_contract: Execution failed with error: {}", .{err});

        // For REVERT, we return partial gas
        if (err == ExecutionError.Error.REVERT) {
            // REVERT returns partial gas but no output data in error case
            return CallResult{ .success = false, .gas_left = contract.gas, .output = null };
        }

        // Other errors consume all gas
        return CallResult{ .success = false, .gas_left = 0, .output = null };
    };
    defer if (result.output) |out| self.allocator.free(out);

    Log.debug("VM.delegatecall_contract: Execution completed, status={}, gas_used={}, output_size={}", .{ result.status, result.gas_used, if (result.output) |o| o.len else 0 });

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

    Log.debug("VM.delegatecall_contract: Delegatecall completed, success={}, gas_used={}, gas_left={}, output_size={}", .{ success, result.gas_used, result.gas_left, if (output) |o| o.len else 0 });

    // The intrinsic gas is consumed, so we don't add it back to gas_left
    return CallResult{ .success = success, .gas_left = result.gas_left, .output = output };
}
