const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const Vm = @import("../evm.zig");
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;
const CallFrameStack = @import("../call_frame_stack.zig").CallFrameStack;
const CallType = @import("../call_frame_stack.zig").CallType;
const CallParams = @import("../call_frame_stack.zig").CallParams;
const AccessList = @import("../access_list/access_list.zig");
const Log = @import("../log.zig");

// ============================================================================
// Call Operation Types and Gas Calculation
// ============================================================================

/// Input parameters for contract call operations
///
/// Contains all necessary information to execute a contract call including
/// addresses, value, call data, gas limits, and context information.
///
/// ## Field Ordering Optimization
/// Fields are ordered for optimal memory layout and cache performance:
/// - Large fields (u256) first
/// - Address fields grouped together
/// - Smaller integer fields grouped
/// - Optional fields last
pub const CallInput = struct {
    /// Value to transfer (ETH amount in wei)
    /// Largest field first for optimal alignment
    value: u256,

    /// Address fields grouped for better cache locality
    /// primitives.Address.Address of the contract to call
    contract_address: primitives.Address.Address,

    /// primitives.Address.Address of the caller (msg.sender in the called contract)
    caller: primitives.Address.Address,

    /// Input data (calldata) to pass to the contract
    input: []const u8,

    /// Gas limit for the call execution
    gas_limit: u64,

    /// Current call depth in the call stack
    depth: u32,

    /// Whether this is a static call (read-only, no state changes)
    /// Small bool field placed with other small fields
    is_static: bool,

    /// Optional fields last to minimize padding
    /// Original caller for DELEGATECALL context preservation (optional)
    original_caller: ?primitives.Address.Address = null,

    /// Original value for DELEGATECALL context preservation (optional)
    original_value: ?u256 = null,

    /// Create CallInput for a CALL operation
    pub fn call(
        contract_address: primitives.Address.Address,
        caller: primitives.Address.Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
        is_static: bool,
        depth: u32,
    ) CallInput {
        return CallInput{
            .value = value,
            .contract_address = contract_address,
            .caller = caller,
            .input = input,
            .gas_limit = gas_limit,
            .depth = depth,
            .is_static = is_static,
        };
    }

    /// Create CallInput for a DELEGATECALL operation
    /// Preserves original caller and value from parent context
    pub fn delegate_call(
        contract_address: primitives.Address.Address,
        original_caller: primitives.Address.Address,
        original_value: u256,
        input: []const u8,
        gas_limit: u64,
        is_static: bool,
        depth: u32,
    ) CallInput {
        return CallInput{
            .value = original_value, // Preserve original value
            .contract_address = contract_address,
            .caller = original_caller, // Preserve original caller
            .input = input,
            .gas_limit = gas_limit,
            .depth = depth,
            .is_static = is_static,
            .original_caller = original_caller,
            .original_value = original_value,
        };
    }

    /// Create CallInput for a STATICCALL operation
    /// Implicitly sets value to 0 and is_static to true
    pub fn static_call(
        contract_address: primitives.Address.Address,
        caller: primitives.Address.Address,
        input: []const u8,
        gas_limit: u64,
        depth: u32,
    ) CallInput {
        return CallInput{
            .value = 0, // Static calls cannot transfer value
            .contract_address = contract_address,
            .caller = caller,
            .input = input,
            .gas_limit = gas_limit,
            .depth = depth,
            .is_static = true, // Force static context
        };
    }
};

/// Result of a contract call operation
///
/// Contains the execution result, gas usage, output data, and success status.
///
/// ## Field Ordering Optimization
/// Fields ordered for optimal memory layout:
/// - Gas fields grouped together for better cache locality
/// - Pointer field next
/// - Small bool field last to minimize padding
pub const CallResult = struct {
    /// Gas consumed during execution
    /// Frequently accessed field placed first
    gas_used: u64,

    /// Gas remaining after execution
    /// Grouped with gas_used for cache locality
    gas_left: u64,

    /// Output data returned by the called contract
    output: ?[]const u8,

    /// Whether the call succeeded (true) or reverted (false)
    /// Small bool field placed last to minimize padding
    success: bool,

    /// Create a successful call result
    pub fn success_result(gas_used: u64, gas_left: u64, output: ?[]const u8) CallResult {
        return CallResult{
            .gas_used = gas_used,
            .gas_left = gas_left,
            .output = output,
            .success = true,
        };
    }

    /// Create a failed call result
    pub fn failure_result(gas_used: u64, gas_left: u64, output: ?[]const u8) CallResult {
        return CallResult{
            .gas_used = gas_used,
            .gas_left = gas_left,
            .output = output,
            .success = false,
        };
    }
};

// ============================================================================
// Shared Validation Functions for Call Operations
// ============================================================================

/// Check call depth limit shared by all call operations
/// Returns true if depth limit is exceeded, false otherwise
fn validate_call_depth(frame: *ExecutionContext) bool {
    return frame.depth >= 1024;
}

/// Handle memory expansion for call arguments
/// Returns the arguments slice or empty slice if size is 0
fn get_call_args(frame: *ExecutionContext, args_offset: u256, args_size: u256) ExecutionError.Error![]const u8 {
    if (args_size == 0) return &[_]u8{};

    try check_offset_bounds(args_offset);
    try check_offset_bounds(args_size);

    const args_offset_usize = @as(usize, @intCast(args_offset));
    const args_size_usize = @as(usize, @intCast(args_size));

    _ = try frame.memory.ensure_context_capacity(args_offset_usize + args_size_usize);
    return try frame.memory.get_slice(args_offset_usize, args_size_usize);
}

/// Ensure return memory is available for writing results
fn ensure_return_memory(frame: *ExecutionContext, ret_offset: u256, ret_size: u256) ExecutionError.Error!void {
    if (ret_size == 0) return;

    try check_offset_bounds(ret_offset);
    try check_offset_bounds(ret_size);

    const ret_offset_usize = @as(usize, @intCast(ret_offset));
    const ret_size_usize = @as(usize, @intCast(ret_size));

    _ = try frame.memory.ensure_context_capacity(ret_offset_usize + ret_size_usize);
}

/// Handle address conversion and EIP-2929 access cost
/// Returns the target address
fn handle_address_access(vm: *Vm, frame: *ExecutionContext, to: u256) ExecutionError.Error!primitives.Address.Address {
    const to_address = from_u256(to);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try vm.access_list.access_address(to_address);
    const is_cold = access_cost == AccessList.COLD_ACCOUNT_ACCESS_COST;
    if (is_cold) {
        @branchHint(.unlikely);
        // Cold address access costs more (2600 gas)
        try frame.consume_gas(GasConstants.ColdAccountAccessCost);
    }

    return to_address;
}

/// Calculate gas for call operations using 63/64 rule and value stipend
fn calculate_call_gas_amount(frame: *ExecutionContext, gas: u256, value: u256) u64 {
    var gas_for_call = if (gas > std.math.maxInt(u64)) std.math.maxInt(u64) else @as(u64, @intCast(gas));
    gas_for_call = @min(gas_for_call, frame.gas_remaining - (frame.gas_remaining / GasConstants.CALL_GAS_RETENTION_DIVISOR));

    if (value != 0) {
        gas_for_call += GasConstants.GAS_STIPEND_VALUE_TRANSFER;
    }

    return gas_for_call;
}

/// Write return data to memory if requested and update gas
fn handle_call_result(frame: *ExecutionContext, result: anytype, ret_offset: u256, ret_size: u256, gas_for_call: u64) ExecutionError.Error!void {
    // Update gas remaining
    frame.gas_remaining = frame.gas_remaining - gas_for_call + result.gas_left;

    // Write return data to memory if requested
    if (ret_size > 0 and result.output != null) {
        const ret_offset_usize = @as(usize, @intCast(ret_offset));
        const ret_size_usize = @as(usize, @intCast(ret_size));
        const output = result.output.?;

        const copy_size = @min(ret_size_usize, output.len);
        const memory_slice = frame.memory.slice();
        std.mem.copyForwards(u8, memory_slice[ret_offset_usize .. ret_offset_usize + copy_size], output[0..copy_size]);

        // Zero out remaining bytes if output was smaller than requested
        if (copy_size < ret_size_usize) {
            @branchHint(.unlikely);
            @memset(memory_slice[ret_offset_usize + copy_size .. ret_offset_usize + ret_size_usize], 0);
        }
    }

    // Set return data
    try frame.return_data.set(result.output orelse &[_]u8{});

    // Push success status (bounds checking already done by jump table)
    frame.stack.append_unsafe(if (result.success) 1 else 0);
}

// ============================================================================
// Shared Validation Functions for CREATE Operations
// ============================================================================

/// Check static call restrictions for CREATE operations
fn validate_create_static_context(frame: *ExecutionContext) ExecutionError.Error!void {
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }
}

/// Extract initcode from memory with bounds checking and gas accounting
fn get_initcode_from_memory(frame: *ExecutionContext, vm: *Vm, offset: u256, size: u256) ExecutionError.Error![]const u8 {
    // Check initcode size bounds
    try check_offset_bounds(size);
    const size_usize = @as(usize, @intCast(size));

    // EIP-3860: Check initcode size limit (Shanghai and later)
    if (vm.chain_rules.is_eip3860 and size_usize > GasConstants.MaxInitcodeSize) {
        @branchHint(.unlikely);
        return ExecutionError.Error.MaxCodeSizeExceeded;
    }

    if (size == 0) return &[_]u8{};

    try check_offset_bounds(offset);
    const offset_usize = @as(usize, @intCast(offset));

    // Calculate memory expansion gas cost
    const new_size = offset_usize + size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Ensure memory is available and get the slice
    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);
    return try frame.memory.get_slice(offset_usize, size_usize);
}

/// Calculate and consume gas for CREATE operations
fn consume_create_gas(frame: *ExecutionContext, vm: *Vm, init_code: []const u8) ExecutionError.Error!void {
    const init_code_cost = @as(u64, @intCast(init_code.len)) * GasConstants.CreateDataGas;

    // EIP-3860: Add gas cost for initcode word size (2 gas per 32-byte word) - Shanghai and later
    const initcode_word_cost = if (vm.chain_rules.is_eip3860)
        @as(u64, @intCast(GasConstants.wordCount(init_code.len))) * GasConstants.InitcodeWordGas
    else
        0;

    try frame.consume_gas(init_code_cost + initcode_word_cost);
}

/// Calculate and consume gas for CREATE2 operations (includes hash cost)
fn consume_create2_gas(frame: *ExecutionContext, vm: *Vm, init_code: []const u8) ExecutionError.Error!void {
    const init_code_cost = @as(u64, @intCast(init_code.len)) * GasConstants.CreateDataGas;
    const hash_cost = @as(u64, @intCast(GasConstants.wordCount(init_code.len))) * GasConstants.Keccak256WordGas;

    // EIP-3860: Add gas cost for initcode word size (2 gas per 32-byte word) - Shanghai and later
    const initcode_word_cost = if (vm.chain_rules.is_eip3860)
        @as(u64, @intCast(GasConstants.wordCount(init_code.len))) * GasConstants.InitcodeWordGas
    else
        0;

    try frame.consume_gas(init_code_cost + hash_cost + initcode_word_cost);
}

/// Handle CREATE result with gas updates and return data
fn handle_create_result(frame: *ExecutionContext, vm: *Vm, result: anytype, gas_for_call: u64) ExecutionError.Error!void {
    _ = gas_for_call;
    // Update gas remaining
    frame.gas_remaining = frame.gas_remaining / GasConstants.CALL_GAS_RETENTION_DIVISOR + result.gas_left;

    if (!result.success) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        try frame.return_data.set(result.output orelse &[_]u8{});
        return;
    }

    // EIP-2929: Mark the newly created address as warm
    _ = try vm.access_list.access_address(result.address);
    try frame.stack.append(to_u256(result.address));

    // Clear old return data before setting new data to reduce memory pressure
    frame.return_data.clear();

    // Set return data
    try frame.return_data.set(result.output orelse &[_]u8{});
}

/// Calculate complete gas cost for call operations
///
/// Implements the complete gas calculation as per EVM specification including:
/// - Base call cost (depends on call type)
/// - Account access cost (cold vs warm)
/// - Value transfer cost
/// - Account creation cost
/// - Memory expansion cost
/// - Gas forwarding calculation (63/64th rule)
///
/// @param call_type Type of call operation
/// @param value Value being transferred (0 for non-value calls)
/// @param target_exists Whether target account exists
/// @param is_cold_access Whether this is first access to account (EIP-2929)
/// @param remaining_gas Available gas before operation
/// @param memory_expansion_cost Cost for expanding memory
/// @param local_gas_limit Gas limit specified in call parameters
/// @return Total gas cost including forwarded gas
pub fn calculate_call_gas(
    call_type: CallType,
    value: u256,
    target_exists: bool,
    is_cold_access: bool,
    remaining_gas: u64,
    memory_expansion_cost: u64,
    local_gas_limit: u64,
) u64 {
    var gas_cost: u64 = 0;

    // Base cost for call operation type
    gas_cost += switch (call_type) {
        .Call => if (value > 0) GasConstants.CallValueCost else GasConstants.CallCodeCost,
        .CallCode => GasConstants.CallCodeCost,
        .DelegateCall => GasConstants.DelegateCallCost,
        .StaticCall => GasConstants.StaticCallCost,
    };

    // Account access cost (EIP-2929)
    if (is_cold_access) {
        gas_cost += GasConstants.ColdAccountAccessCost;
    }

    // Memory expansion cost
    gas_cost += memory_expansion_cost;

    // Account creation cost for new accounts with value transfer
    if (!target_exists and call_type == .Call and value > 0) {
        gas_cost += GasConstants.NewAccountCost;
    }

    // Calculate available gas for forwarding after subtracting operation costs
    if (gas_cost >= remaining_gas) {
        return gas_cost; // Out of gas - no forwarding possible
    }

    const gas_after_operation = remaining_gas - gas_cost;

    // Apply 63/64th rule to determine maximum forwardable gas (EIP-150)
    const max_forwardable = (gas_after_operation * (GasConstants.CALL_GAS_RETENTION_DIVISOR - 1)) / GasConstants.CALL_GAS_RETENTION_DIVISOR;

    // Use minimum of requested gas and maximum forwardable
    const gas_to_forward = @min(local_gas_limit, max_forwardable);

    return gas_cost + gas_to_forward;
}

// ============================================================================
// Return Data Opcodes (EIP-211)
// ============================================================================

// Gas opcode handler
pub fn gas_op(context: *ExecutionContext) ExecutionError.Error!void {
    try context.stack.append(@as(u256, @intCast(context.gas_remaining)));
}

// Helper to check if u256 fits in usize
fn check_offset_bounds(value: u256) ExecutionError.Error!void {
    if (value > std.math.maxInt(usize)) {
        @branchHint(.cold);
        return ExecutionError.Error.InvalidOffset;
    }
}

// Snapshot and revert helper functions for opcode-level state management

/// Create a snapshot for opcode-level state management
///
/// This function provides a convenient way for opcodes to create state snapshots
/// before performing operations that might need to be reverted.
///
/// ## Parameters
/// - `vm`: VM instance to create snapshot on
///
/// ## Returns
/// - Success: Snapshot identifier
/// - Error: OutOfMemory if snapshot allocation fails
pub fn create_snapshot(vm: *Vm) std.mem.Allocator.Error!usize {
    Log.debug("system.create_snapshot: Creating state snapshot", .{});
    return try vm.create_snapshot();
}

/// Commit a snapshot, making all changes permanent
///
/// This function commits all state changes made since the snapshot was created.
/// Once committed, the changes cannot be reverted using this snapshot.
///
/// ## Parameters
/// - `vm`: VM instance to commit snapshot on
/// - `snapshot_id`: Identifier of the snapshot to commit
pub fn commit_snapshot(vm: *Vm, snapshot_id: usize) void {
    Log.debug("system.commit_snapshot: Committing snapshot id={}", .{snapshot_id});
    vm.commit_snapshot(snapshot_id);
}

/// Revert to a snapshot, undoing all changes since the snapshot was created
///
/// This function restores the VM state to exactly how it was when the snapshot
/// was created. This is used for opcodes like REVERT and for failed operations.
///
/// ## Parameters
/// - `vm`: VM instance to revert snapshot on
/// - `snapshot_id`: Identifier of the snapshot to revert to
///
/// ## Returns
/// - Success: void
/// - Error: Invalid snapshot ID or reversion failure
pub fn revert_to_snapshot(vm: *Vm, snapshot_id: usize) !void {
    Log.debug("system.revert_to_snapshot: Reverting to snapshot id={}", .{snapshot_id});
    try vm.revert_to_snapshot(snapshot_id);
}

pub fn op_create(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = ctx;

    // TODO: Implementation requires:
    // - vm instance for contract creation
    // - frame.contract.address access
    // - frame.return_data operations
    // - handle_create_result integration
}

/// CREATE2 opcode - Create contract with deterministic address
pub fn op_create2(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = ctx;

    // TODO: Implementation requires:
    // - vm instance for contract creation
    // - frame.contract.address access
    // - frame.return_data operations
    // - handle_create_result integration
}

pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));

    // Pop parameters from stack
    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const value = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    // Validate static context for value transfers
    if (frame.is_static() and value != 0) {
        return ExecutionError.Error.WriteProtection;
    }

    // Get call frame stack (this would need to be passed somehow)
    // For now this is a placeholder - we need to refactor to pass CallFrameStack
    // const call_stack = frame.get_call_stack();

    // Convert to address
    const to_address = from_u256(to);
    _ = to_address;

    // Get call arguments from memory
    const args = try get_call_args(frame, args_offset, args_size);
    _ = args;

    // Ensure return memory is available
    try ensure_return_memory(frame, ret_offset, ret_size);

    // Calculate gas limit
    const gas_limit = calculate_call_gas_amount(frame, gas, value);
    _ = gas_limit;

    // For now, push 0 (failure) since we don't have the full implementation
    // In the full implementation, we would:
    // 1. Create new frame using init_call_frame
    // 2. Execute the frame
    // 3. Handle result and gas updates
    try frame.stack.append(0);
}

pub fn op_callcode(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = ctx;

    // TODO: Implementation requires:
    // - vm instance for callcode operations
    // - frame.contract.address access
    // - frame.is_static checks
    // - frame.return_data operations
    // - handle_call_result integration
}

pub fn op_delegatecall(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));

    // Pop parameters from stack (DELEGATECALL has no value parameter)
    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    // Convert to address
    const to_address = from_u256(to);
    _ = to_address;

    // Get call arguments from memory
    const args = try get_call_args(frame, args_offset, args_size);
    _ = args;

    // Ensure return memory is available
    try ensure_return_memory(frame, ret_offset, ret_size);

    // Calculate gas limit (DELEGATECALL uses no value)
    const gas_limit = calculate_call_gas_amount(frame, gas, 0);
    _ = gas_limit;

    // For now, push 0 (failure) since we don't have the full implementation
    // In the full implementation, we would:
    // 1. Create DELEGATECALL frame that preserves caller and value
    // 2. Execute with shared memory
    // 3. Handle result
    try frame.stack.append(0);
}

pub fn op_staticcall(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));

    // Pop parameters from stack (STATICCALL has no value parameter)
    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    // Convert to address
    const to_address = from_u256(to);
    _ = to_address;

    // Get call arguments from memory
    const args = try get_call_args(frame, args_offset, args_size);
    _ = args;

    // Ensure return memory is available
    try ensure_return_memory(frame, ret_offset, ret_size);

    // Calculate gas limit (STATICCALL uses no value)
    const gas_limit = calculate_call_gas_amount(frame, gas, 0);
    _ = gas_limit;

    // For now, push 0 (failure) since we don't have the full implementation
    // In the full implementation, we would:
    // 1. Create STATICCALL frame with is_static = true
    // 2. Execute with separate memory
    // 3. Handle result
    try frame.stack.append(0);
}

/// SELFDESTRUCT opcode (0xFF): Destroy the current contract and send balance to recipient
///
/// This opcode destroys the current contract, sending its entire balance to a recipient address.
/// The behavior has changed significantly across hardforks:
/// - Frontier: 0 gas cost
/// - Tangerine Whistle (EIP-150): 5000 gas base cost
/// - Spurious Dragon (EIP-161): Additional 25000 gas if creating a new account
/// - London (EIP-3529): Removed gas refunds for selfdestruct
///
/// In static call contexts, SELFDESTRUCT is forbidden and will revert.
/// The contract is only marked for destruction and actual deletion happens at transaction end.
///
/// Stack: [recipient_address] -> []
/// Gas: Variable based on hardfork and account creation
/// Memory: No memory access
/// Storage: Contract marked for destruction
pub fn op_selfdestruct(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));

    // Check static call restriction
    if (frame.is_static()) {
        return ExecutionError.Error.WriteProtection;
    }

    // Pop recipient address from stack
    const recipient = try frame.stack.pop();
    const recipient_address = from_u256(recipient);

    // Record the self-destruct operation in the journal
    try frame.journal.record_selfdestruct(frame.snapshot_id, frame.contract_address, recipient_address);

    // Mark for destruction using the existing self_destruct system if available
    if (frame.self_destruct) |sd| {
        try sd.mark_for_destruction(frame.contract_address, recipient_address);
    }

    // Gas consumption would be handled here based on hardfork rules
    // For now, we consume a basic amount
    try frame.consume_gas(GasConstants.SelfDestructCost);

    // SELFDESTRUCT terminates execution immediately - we would signal this
    // to the execution loop, but for now we'll just return
}

/// EXTCALL opcode (0xF8): External call with EOF validation
/// Not implemented - EOF feature
pub fn op_extcall(context: *anyopaque) ExecutionError.Error!void {
    _ = context;

    // This is an EOF (EVM Object Format) opcode, not yet implemented
    return ExecutionError.Error.EOFNotSupported;
}

/// EXTDELEGATECALL opcode (0xF9): External delegate call with EOF validation
/// Not implemented - EOF feature
pub fn op_extdelegatecall(context: *anyopaque) ExecutionError.Error!void {
    _ = context;

    // This is an EOF (EVM Object Format) opcode, not yet implemented
    return ExecutionError.Error.EOFNotSupported;
}

/// EXTSTATICCALL opcode (0xFB): External static call with EOF validation
/// Not implemented - EOF feature
pub fn op_extstaticcall(context: *anyopaque) ExecutionError.Error!void {
    _ = context;

    // This is an EOF (EVM Object Format) opcode, not yet implemented
    return ExecutionError.Error.EOFNotSupported;
}

// Testing imports and definitions
const testing = std.testing;
const MemoryDatabase = @import("../state/memory_database.zig");
const ReturnData = @import("../evm/return_data.zig");
const ArrayList = std.ArrayList;

const FuzzSystemOperation = struct {
    op_type: SystemOpType,
    gas: u256 = 0,
    to: u256 = 0,
    value: u256 = 0,
    args_offset: u256 = 0,
    args_size: u256 = 0,
    ret_offset: u256 = 0,
    ret_size: u256 = 0,
    salt: u256 = 0,
    init_offset: u256 = 0,
    init_size: u256 = 0,
    gas_limit: u64 = 1000000,
    depth: u32 = 0,
    is_static: bool = false,
    calldata: []const u8 = &.{},
    init_code: []const u8 = &.{},
    expected_error: ?ExecutionError.Error = null,
    expect_success: bool = true,
    target_exists: bool = true,
    target_has_code: bool = false,
};

const SystemOpType = enum {
    gas,
    create,
    create2,
    call,
    callcode,
    delegatecall,
    staticcall,
    selfdestruct,
};

// TODO: Fuzz testing functionality disabled until ExecutionContext integration is complete
// This will need to be rewritten to work with ExecutionContext instead of Frame/Contract
fn fuzz_system_operations(allocator: std.mem.Allocator, operations: []const FuzzSystemOperation) !void {
    _ = allocator;
    _ = operations;
    // Implementation removed - needs rewrite for ExecutionContext
}

// TODO: Validation functionality disabled until ExecutionContext integration is complete
fn validate_system_result(frame: *const ExecutionContext, op: FuzzSystemOperation, result: anyerror!void) !void {
    _ = frame;
    _ = op;
    _ = result;
    // Implementation removed - needs rewrite for ExecutionContext
    // FIXME: Orphaned closing brace commented out
    // }

    // TODO: Test disabled until ExecutionContext integration is complete
    // test "fuzz_system_basic_operations" {
    //     const allocator = std.testing.allocator;
    //
    //     const simple_init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 }; // PUSH1 0 PUSH1 0 RETURN
    //
    //     const operations = [_]FuzzSystemOperation{
    //         // GAS opcode
    //         .{
    //             .op_type = .gas,
    //             .gas_limit = 100000,
    //         },
    //         // Basic CREATE
    //         .{
    //             .op_type = .create,
    //             .value = 0,
    //             .init_offset = 0,
    //             .init_size = simple_init_code.len,
    //             .init_code = &simple_init_code,
    //         },
    //         // Basic CREATE2
    //         .{
    //             .op_type = .create2,
    //             .value = 0,
    //             .init_offset = 0,
    //             .init_size = simple_init_code.len,
    //             .salt = 0x1234,
    //             .init_code = &simple_init_code,
    //         },
    //         // Basic CALL
    //         .{
    //             .op_type = .call,
    //             .gas = 50000,
    //             .to = 0x9999,
    //             .value = 0,
    //             .args_offset = 0,
    //             .args_size = 0,
    //             .ret_offset = 0,
    //             .ret_size = 32,
    //             .target_exists = true,
    //             .target_has_code = true,
    //         },
    //         // Basic DELEGATECALL
    //         .{
    //             .op_type = .delegatecall,
    //             .gas = 50000,
    //             .to = 0x9999,
    //             .args_offset = 0,
    //             .args_size = 0,
    //             .ret_offset = 0,
    //             .ret_size = 32,
    //             .target_exists = true,
    //             .target_has_code = true,
    //         },
    //         // Basic STATICCALL
    //         .{
    //             .op_type = .staticcall,
    //             .gas = 50000,
    //             .to = 0x9999,
    //             .args_offset = 0,
    //             .args_size = 0,
    //             .ret_offset = 0,
    //             .ret_size = 32,
    //             .target_exists = true,
    //             .target_has_code = true,
    //         },
    //     };
    //
    //     try fuzz_system_operations(allocator, &operations);
    // }

    // TODO: Test disabled until ExecutionContext integration is complete
    // test "fuzz_system_static_context" {
    //     const allocator = std.testing.allocator;
    //
    //     const operations = [_]FuzzSystemOperation{
    //         // CREATE in static context (should fail)
    //         .{
    //             .op_type = .create,
    //             .value = 0,
    //             .init_offset = 0,
    //             .init_size = 5,
    //             .is_static = true,
    //             .expected_error = ExecutionError.Error.WriteProtection,
    //         },
    //         // CREATE2 in static context (should fail)
    //         .{
    //             .op_type = .create2,
    //             .value = 0,
    //             .init_offset = 0,
    //             .init_size = 5,
    //             .salt = 0,
    //             .is_static = true,
    //             .expected_error = ExecutionError.Error.WriteProtection,
    //         },
    //         // CALL with value in static context (should fail)
    //         .{
    //             .op_type = .call,
    //             .gas = 50000,
    //             .to = 0x9999,
    //             .value = 100,
    //             .is_static = true,
    //             .expected_error = ExecutionError.Error.WriteProtection,
    //         },
    //         // SELFDESTRUCT in static context (should fail)
    //         .{
    //             .op_type = .selfdestruct,
    //             .to = 0x9999,
    //             .is_static = true,
    //             .expected_error = ExecutionError.Error.WriteProtection,
    //         },
    //     };
    //
    //     try fuzz_system_operations(allocator, &operations);
    // }

    // TODO: Test disabled until ExecutionContext integration is complete
    // test "fuzz_system_depth_limit" {
    //     const allocator = std.testing.allocator;
    //
    //     const operations = [_]FuzzSystemOperation{
    //         // CREATE at max depth
    //         .{
    //             .op_type = .create,
    //             .value = 0,
    //             .init_offset = 0,
    //             .init_size = 5,
    //             .depth = 1024,
    //             .expect_success = false,
    //         },
    //         // CALL at max depth
    //         .{
    //             .op_type = .call,
    //             .gas = 50000,
    //             .to = 0x9999,
    //             .value = 0,
    //             .depth = 1024,
    //             .expect_success = false,
    //         },
    //         // DELEGATECALL at max depth
    //         .{
    //             .op_type = .delegatecall,
    //             .gas = 50000,
    //             .to = 0x9999,
    //             .depth = 1024,
    //             .expect_success = false,
    //         },
    //     };
    //
    //     try fuzz_system_operations(allocator, &operations);
    // }

    // TODO: Test disabled until ExecutionContext integration is complete
    // test "fuzz_system_gas_calculations" {
    //     const allocator = std.testing.allocator;
    //
    //     const large_init_code = [_]u8{0x00} ** 1000; // Large init code for gas testing
    //
    //     const operations = [_]FuzzSystemOperation{
    //         // CREATE with insufficient gas
    //         .{
    //             .op_type = .create,
    //             .value = 0,
    //             .init_offset = 0,
    //             .init_size = large_init_code.len,
    //             .init_code = &large_init_code,
    //             .gas_limit = 1000, // Not enough for large init code
    //             .expected_error = ExecutionError.Error.OutOfGas,
    //         },
    //         // CALL with low gas limit
    //         .{
    //             .op_type = .call,
    //             .gas = 100,
    //             .to = 0x9999,
    //             .value = 0,
    //             .gas_limit = 5000,
    //             .target_exists = true,
    //             .expect_success = false,
    //         },
    //     };
    //
    //     try fuzz_system_operations(allocator, &operations);
    // }

    // TODO: Test disabled until ExecutionContext integration is complete
    // test "fuzz_system_edge_cases" {
    //     const allocator = std.testing.allocator;
    //
    //     const operations = [_]FuzzSystemOperation{
    //         // CREATE with zero size init code
    //         .{
    //             .op_type = .create,
    //             .value = 0,
    //             .init_offset = 0,
    //             .init_size = 0,
    //         },
    //         // CALL to non-existent account
    //         .{
    //             .op_type = .call,
    //             .gas = 50000,
    //             .to = 0xdeadbeef,
    //             .value = 0,
    //             .target_exists = false,
    //             .expect_success = false,
    //         },
    //         // CALL with value to new account
    //         .{
    //             .op_type = .call,
    //             .gas = 50000,
    //             .to = 0xbadbeef,
    //             .value = 1000,
    //             .target_exists = false,
    //             .expect_success = false, // Will fail because we're not handling value transfers in mock
    //         },
    //         // CALLCODE to self
    //         .{
    //             .op_type = .callcode,
    //             .gas = 50000,
    //             .to = 0x1234, // Same as contract address
    //             .value = 0,
    //         },
    //     };
    //
    //     try fuzz_system_operations(allocator, &operations);
    // }

    // TODO: Test disabled until ExecutionContext integration is complete
    // test "fuzz_system_random_operations" {
    //     const allocator = std.testing.allocator;
    //     var prng = std.Random.DefaultPrng.init(42);
    //     const random = prng.random();
    //
    //     var operations = ArrayList(FuzzSystemOperation).init(allocator);
    //     defer operations.deinit();
    //
    //     // Generate random init code
    //     var random_init_code: [64]u8 = undefined;
    //     random.bytes(&random_init_code);
    //
    //     var i: usize = 0;
    //     while (i < 20) : (i += 1) {
    //         const op_type_idx = random.intRangeAtMost(usize, 0, 7);
    //         const op_types = [_]SystemOpType{ .gas, .create, .create2, .call, .callcode, .delegatecall, .staticcall, .selfdestruct };
    //         const op_type = op_types[op_type_idx];
    //
    //         const gas = random.intRangeAtMost(u256, 1000, 100000);
    //         const to = random.int(u256);
    //         const value = random.intRangeAtMost(u256, 0, 1000);
    //         const salt = random.int(u256);
    //         const depth = random.intRangeAtMost(u32, 0, 1025);
    //         const is_static = random.boolean();
    //         const gas_limit = random.intRangeAtMost(u64, 10000, 1000000);
    //
    //         try operations.append(.{
    //             .op_type = op_type,
    //             .gas = gas,
    //             .to = to,
    //             .value = value,
    //             .args_offset = 0,
    //             .args_size = 0,
    //             .ret_offset = 0,
    //             .ret_size = 32,
    //             .salt = salt,
    //             .init_offset = 0,
    //             .init_size = if (op_type == .create or op_type == .create2) 32 else 0,
    //             .gas_limit = gas_limit,
    //             .depth = depth,
    //             .is_static = is_static,
    //             .init_code = &random_init_code,
    //         });
    //     }
    //
    //     try fuzz_system_operations(allocator, operations.items);
    // }

    // FIXME: Comment out test functions that use Frame/Contract until ExecutionContext migration is complete
    // test "calculate_call_gas" {
    // Test basic CALL gas calculation
    {
        const gas = calculate_call_gas(
            .Call,
            0, // no value
            true, // target exists
            false, // warm access
            100000, // remaining gas
            0, // no memory expansion
            50000, // requested gas
        );
        // Base cost (100) + no memory + min(50000, (99900 * 63)/64)
        try testing.expect(gas > 100);
    }

    // Test CALL with value transfer
    {
        const gas = calculate_call_gas(
            .Call,
            100, // with value
            true, // target exists
            false, // warm access
            100000, // remaining gas
            0, // no memory expansion
            50000, // requested gas
        );
        // Base cost (9000 for value) + forwarded gas
        try testing.expect(gas >= 9000);
    }

    // Test CALL with cold access
    {
        const gas = calculate_call_gas(
            .Call,
            0, // no value
            true, // target exists
            true, // cold access
            100000, // remaining gas
            0, // no memory expansion
            50000, // requested gas
        );
        // Base cost + cold access (2600) + forwarded gas
        try testing.expect(gas >= 2700);
    }

    // Test CALL to new account with value
    {
        const gas = calculate_call_gas(
            .Call,
            100, // with value
            false, // target doesn't exist
            true, // cold access
            100000, // remaining gas
            0, // no memory expansion
            50000, // requested gas
        );
        // Base cost (9000) + cold (2600) + new account (25000) + forwarded
        try testing.expect(gas >= 36600);
    }

    // Test insufficient gas scenario
    {
        const gas = calculate_call_gas(
            .Call,
            0, // no value
            true, // target exists
            false, // warm access
            50, // very low remaining gas
            0, // no memory expansion
            50000, // requested gas (more than available)
        );
        // Should return at least base cost even if can't forward
        try testing.expect(gas >= 100);
    }
}
