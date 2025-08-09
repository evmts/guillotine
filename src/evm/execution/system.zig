const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const Vm = Evm; // Alias for compatibility
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;
const Host = @import("../host.zig").Host;
const CallParams = @import("../host.zig").CallParams;
const AccessList = @import("../access_list/access_list.zig");
const Log = @import("../log.zig");

// Define local CallType to decouple from preallocated call frame stack
const CallType = enum { Call, CallCode, DelegateCall, StaticCall };

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
fn validate_call_depth(frame: *Frame) bool {
    return frame.hot_flags.depth >= 1024;
}

/// Handle memory expansion for call arguments
/// Returns the arguments slice or empty slice if size is 0
fn get_call_args(frame: *Frame, args_offset: u256, args_size: u256) ExecutionError.Error![]const u8 {
    if (args_size == 0) return &[_]u8{};

    try check_offset_bounds(args_offset);
    try check_offset_bounds(args_size);

    const args_offset_usize = @as(usize, @intCast(args_offset));
    const args_size_usize = @as(usize, @intCast(args_size));

    // Calculate and charge memory expansion gas cost
    const new_size = args_offset_usize + args_size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    _ = try frame.memory.ensure_context_capacity(new_size);
    return try frame.memory.get_slice(args_offset_usize, args_size_usize);
}

/// Ensure return memory is available for writing results
fn ensure_return_memory(frame: *Frame, ret_offset: u256, ret_size: u256) ExecutionError.Error!void {
    if (ret_size == 0) return;

    try check_offset_bounds(ret_offset);
    try check_offset_bounds(ret_size);

    const ret_offset_usize = @as(usize, @intCast(ret_offset));
    const ret_size_usize = @as(usize, @intCast(ret_size));

    // Calculate and charge memory expansion gas cost
    const new_size = ret_offset_usize + ret_size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    _ = try frame.memory.ensure_context_capacity(new_size);
}

/// Handle address conversion and EIP-2929 access cost
/// Returns the target address
fn handle_address_access(vm: *Vm, frame: Frame, to: u256) ExecutionError.Error!primitives.Address.Address {
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

/// Calculate gas for call operations implementing EIP-150 semantics
///
/// EIP-150 introduces the all-but-one-64th rule where the calling contract
/// retains at least 1/64th of its remaining gas. Additionally, calls with
/// value transfers receive a 2300 gas stipend to ensure basic operations.
///
/// ## Gas Forwarding Rules:
/// 1. Calculate max forwardable: gas_remaining - floor(gas_remaining/64)
/// 2. Use minimum of requested gas and max forwardable
/// 3. If value > 0, add 2300 gas stipend (not taken from caller's gas)
///
/// ## Parameters
/// - `frame`: Current execution frame
/// - `gas`: Requested gas amount from stack
/// - `value`: ETH value being transferred (0 for non-value calls)
/// - `already_consumed`: Gas already consumed for the call operation
///
/// ## Returns
/// - Actual gas amount to forward to the called contract
fn calculate_call_gas_amount(frame: *Frame, gas: u256, value: u256, already_consumed: u64) u64 {
    // Convert requested gas to u64, capping at max
    const gas_requested = if (gas > std.math.maxInt(u64))
        std.math.maxInt(u64)
    else
        @as(u64, @intCast(gas));

    // EIP-150: All but one 64th rule
    // Caller must retain at least 1/64 of remaining gas
    const gas_available = frame.gas_remaining - already_consumed;
    const one_64th = gas_available / GasConstants.CALL_GAS_RETENTION_DIVISOR;
    const max_gas_to_forward = gas_available - one_64th;

    // Take minimum of requested and maximum forwardable
    var gas_for_call = @min(gas_requested, max_gas_to_forward);

    // EIP-150: Add stipend for value transfers
    // The stipend is ADDED to the gas, not taken from the caller
    if (value != 0) {
        // For value transfers, ensure at least the stipend amount
        // This gas is given "for free" to the callee
        gas_for_call += GasConstants.GAS_STIPEND_VALUE_TRANSFER;
    }

    return gas_for_call;
}

/// Write return data to memory if requested and update gas
fn handle_call_result(frame: Frame, result: anytype, ret_offset: u256, ret_size: u256, gas_for_call: u64) ExecutionError.Error!void {
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
fn validate_create_static_context(frame: Frame) ExecutionError.Error!void {
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }
}

/// Extract initcode from memory with bounds checking and gas accounting
fn get_initcode_from_memory(frame: Frame, vm: *Vm, offset: u256, size: u256) ExecutionError.Error![]const u8 {
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
fn consume_create_gas(frame: Frame, vm: *Vm, init_code: []const u8) ExecutionError.Error!void {
    const init_code_cost = @as(u64, @intCast(init_code.len)) * GasConstants.CreateDataGas;

    // EIP-3860: Add gas cost for initcode word size (2 gas per 32-byte word) - Shanghai and later
    const initcode_word_cost = if (vm.chain_rules.is_eip3860)
        @as(u64, @intCast(GasConstants.wordCount(init_code.len))) * GasConstants.InitcodeWordGas
    else
        0;

    try frame.consume_gas(init_code_cost + initcode_word_cost);
}

/// Calculate and consume gas for CREATE2 operations (includes hash cost)
fn consume_create2_gas(frame: Frame, vm: *Vm, init_code: []const u8) ExecutionError.Error!void {
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
fn handle_create_result(frame: Frame, vm: *Vm, result: anytype, gas_for_call: u64) ExecutionError.Error!void {
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
pub fn gas_op(context: *Frame) ExecutionError.Error!void {
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
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

    // Pop parameters from stack
    const value = try frame.stack.pop();
    const init_offset = try frame.stack.pop();
    const init_size = try frame.stack.pop();

    // Check if in static context (CREATE not allowed)
    if (frame.hot_flags.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.StaticStateChange;
    }

    // Check call depth limit
    if (frame.hot_flags.depth >= 1024) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        return;
    }

    // CRITICAL FIX: Calculate memory expansion costs BEFORE expanding memory
    const init_end = if (init_size > 0) blk: {
        try check_offset_bounds(init_offset);
        try check_offset_bounds(init_size);
        const init_offset_usize = @as(usize, @intCast(init_offset));
        const init_size_usize = @as(usize, @intCast(init_size));
        const end = init_offset_usize + init_size_usize;
        if (end < init_offset_usize) return ExecutionError.Error.GasUintOverflow;
        break :blk end;
    } else 0;

    const memory_expansion_cost = frame.memory.get_expansion_cost(init_end);

    // Base gas cost for CREATE (32000 gas)
    const base_gas = GasConstants.CreateGas;

    // EIP-3860: Charge for init code size (2 gas per 32-byte word)
    const init_code_words = (init_size + 31) / 32;
    const init_code_cost = init_code_words * 2;

    const total_gas_cost = base_gas + memory_expansion_cost + @as(u64, @intCast(init_code_cost));

    // Consume gas before proceeding
    try frame.consume_gas(total_gas_cost);

    // EIP-3860: Check init code size limit (49,152 bytes max)
    if (init_size > 49152) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        return;
    }

    // Now expand memory and get init code after charging for it
    const init_code = if (init_size > 0) blk: {
        const init_offset_usize = @as(usize, @intCast(init_offset));
        const init_size_usize = @as(usize, @intCast(init_size));
        _ = try frame.memory.ensure_context_capacity(init_offset_usize + init_size_usize);
        break :blk try frame.memory.get_slice(init_offset_usize, init_size_usize);
    } else &[_]u8{};

    // EIP-150: Apply 63/64 gas forwarding rule
    const remaining_gas = frame.gas_remaining;
    const gas_reserved = remaining_gas / 64;
    const gas_for_create = remaining_gas - gas_reserved;

    // CREATE uses sender address + nonce for address calculation
    const call_params = CallParams{
        .create = .{
            .caller = frame.contract_address,
            .value = value,
            .init_code = init_code,
            .gas = gas_for_create,
        },
    };

    // Create a journal snapshot before contract creation
    // This allows us to revert all state changes if creation fails
    const snapshot = frame.journal.create_snapshot();

    // Execute the CREATE through the host
    const call_result = frame.host.call(call_params) catch {
        // On error, revert the snapshot and push 0 (failure)
        frame.journal.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };

    // Handle result based on success/failure
    if (call_result.success) {
        // Commit the snapshot on success (no-op in current implementation)
        // The journal entries persist for transaction-level revert capability

        // Handle gas accounting after CREATE
        frame.gas_remaining = gas_reserved + call_result.gas_left;

        // The host should return the created address in the output
        if (call_result.output) |address_bytes| {
            if (address_bytes.len == 20) {
                // Convert address bytes to u256 and push
                var address_u256: u256 = 0;
                for (address_bytes, 0..) |byte, i| {
                    address_u256 |= @as(u256, byte) << @intCast((19 - i) * 8);
                }

                // EIP-6780: Track created contract for SELFDESTRUCT restriction
                if (frame.created_contracts) |created| {
                    var contract_address: primitives.Address.Address = undefined;
                    @memcpy(&contract_address, address_bytes);
                    created.mark_created(contract_address) catch {};
                }

                // EIP-2929: Mark newly created address as warm
                var contract_address: primitives.Address.Address = undefined;
                @memcpy(&contract_address, address_bytes);
                _ = try frame.access_list.access_address(contract_address);

                try frame.stack.append(address_u256);
            } else {
                try frame.stack.append(0);
            }
        } else {
            try frame.stack.append(0);
        }
    } else {
        // Revert the snapshot on failure
        frame.journal.revert_to_snapshot(snapshot);

        // Handle gas accounting after failed CREATE
        frame.gas_remaining = gas_reserved + call_result.gas_left;

        try frame.stack.append(0);
    }
}

/// CREATE2 opcode - Create contract with deterministic address
pub fn op_create2(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

    // Pop parameters from stack
    const value = try frame.stack.pop();
    const init_offset = try frame.stack.pop();
    const init_size = try frame.stack.pop();
    const salt = try frame.stack.pop();

    // Check if in static context (CREATE2 not allowed)
    if (frame.hot_flags.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.StaticStateChange;
    }

    // Check call depth limit
    if (frame.hot_flags.depth >= 1024) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        return;
    }

    // CRITICAL FIX: Calculate memory expansion costs BEFORE expanding memory
    const init_end = if (init_size > 0) blk: {
        try check_offset_bounds(init_offset);
        try check_offset_bounds(init_size);
        const init_offset_usize = @as(usize, @intCast(init_offset));
        const init_size_usize = @as(usize, @intCast(init_size));
        const end = init_offset_usize + init_size_usize;
        if (end < init_offset_usize) return ExecutionError.Error.GasUintOverflow;
        break :blk end;
    } else 0;

    const memory_expansion_cost = frame.memory.get_expansion_cost(init_end);

    // Base gas cost for CREATE2 (32000 gas)
    const base_gas = GasConstants.CreateGas;

    // EIP-3860: Charge for init code size (2 gas per 32-byte word)
    const init_code_words = (init_size + 31) / 32;
    const init_code_cost = init_code_words * 2;

    // CREATE2 has additional cost for hashing (6 gas per 32-byte word)
    const hash_cost = init_code_words * 6;

    const total_gas_cost = base_gas + memory_expansion_cost + @as(u64, @intCast(init_code_cost)) + @as(u64, @intCast(hash_cost));

    // Consume gas before proceeding
    try frame.consume_gas(total_gas_cost);

    // EIP-3860: Check init code size limit (49,152 bytes max)
    if (init_size > 49152) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        return;
    }

    // Now expand memory and get init code after charging for it
    const init_code = if (init_size > 0) blk: {
        const init_offset_usize = @as(usize, @intCast(init_offset));
        const init_size_usize = @as(usize, @intCast(init_size));
        _ = try frame.memory.ensure_context_capacity(init_offset_usize + init_size_usize);
        break :blk try frame.memory.get_slice(init_offset_usize, init_size_usize);
    } else &[_]u8{};

    // EIP-150: Apply 63/64 gas forwarding rule
    const remaining_gas = frame.gas_remaining;
    const gas_reserved = remaining_gas / 64;
    const gas_for_create = remaining_gas - gas_reserved;

    // CREATE2 uses salt for deterministic address calculation
    const call_params = CallParams{
        .create2 = .{
            .caller = frame.contract_address,
            .value = value,
            .init_code = init_code,
            .salt = salt,
            .gas = gas_for_create,
        },
    };

    // Create a journal snapshot before contract creation
    // This allows us to revert all state changes if creation fails
    const snapshot = frame.journal.create_snapshot();

    // Execute the CREATE2 through the host
    const call_result = frame.host.call(call_params) catch {
        // On error, revert the snapshot and push 0 (failure)
        frame.journal.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };

    // Handle result based on success/failure
    if (call_result.success) {
        // Commit the snapshot on success (no-op in current implementation)
        // The journal entries persist for transaction-level revert capability

        // Handle gas accounting after CREATE2
        frame.gas_remaining = gas_reserved + call_result.gas_left;

        // The host should return the created address in the output
        if (call_result.output) |address_bytes| {
            if (address_bytes.len == 20) {
                // Convert address bytes to u256 and push
                var address_u256: u256 = 0;
                for (address_bytes, 0..) |byte, i| {
                    address_u256 |= @as(u256, byte) << @intCast((19 - i) * 8);
                }

                // EIP-6780: Track created contract for SELFDESTRUCT restriction
                if (frame.created_contracts) |created| {
                    var contract_address: primitives.Address.Address = undefined;
                    @memcpy(&contract_address, address_bytes);
                    created.mark_created(contract_address) catch {};
                }

                // EIP-2929: Mark newly created address as warm
                var contract_address: primitives.Address.Address = undefined;
                @memcpy(&contract_address, address_bytes);
                _ = try frame.access_list.access_address(contract_address);

                try frame.stack.append(address_u256);
            } else {
                try frame.stack.append(0);
            }
        } else {
            try frame.stack.append(0);
        }
    } else {
        // Revert the snapshot on failure
        frame.journal.revert_to_snapshot(snapshot);

        // Handle gas accounting after failed CREATE2
        frame.gas_remaining = gas_reserved + call_result.gas_left;

        try frame.stack.append(0);
    }
}

pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

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

    // Check depth limit
    if (validate_call_depth(frame)) {
        // Depth limit exceeded, push failure
        try frame.stack.append(0);
        return;
    }

    // Convert to address
    const to_address = from_u256(to);

    // Calculate memory expansion costs BEFORE expanding memory
    const args_end = if (args_size == 0) 0 else blk: {
        if (args_offset > std.math.maxInt(u64) or args_size > std.math.maxInt(u64)) {
            return ExecutionError.Error.InvalidOffset;
        }
        const offset = @as(u64, @intCast(args_offset));
        const size = @as(u64, @intCast(args_size));
        if (offset > std.math.maxInt(u64) - size) {
            return ExecutionError.Error.GasUintOverflow;
        }
        break :blk offset + size;
    };

    const ret_end = if (ret_size == 0) 0 else blk: {
        if (ret_offset > std.math.maxInt(u64) or ret_size > std.math.maxInt(u64)) {
            return ExecutionError.Error.InvalidOffset;
        }
        const offset = @as(u64, @intCast(ret_offset));
        const size = @as(u64, @intCast(ret_size));
        if (offset > std.math.maxInt(u64) - size) {
            return ExecutionError.Error.GasUintOverflow;
        }
        break :blk offset + size;
    };

    // Find the maximum memory size needed
    const max_memory_size = @max(args_end, ret_end);

    // Calculate memory expansion cost
    const memory_expansion_cost = if (max_memory_size > 0) blk: {
        const expansion_cost = frame.memory.get_expansion_cost(max_memory_size);
        break :blk expansion_cost;
    } else 0;

    // Base gas cost for CALL opcode
    const base_gas = GasConstants.CallGas;
    // Additional gas costs
    var total_gas_cost = base_gas + memory_expansion_cost;

    // EIP-2929: Check if address is cold and add extra gas cost
    if (frame.is_at_least(.BERLIN)) {
        const access_cost = try frame.access_list.get_call_cost(to_address);
        total_gas_cost += access_cost;
    }

    // Add value transfer cost if applicable
    if (value > 0) {
        total_gas_cost += GasConstants.CallValueTransferGas;

        // EIP-150: Check if account is new (doesn't exist) and add creation cost
        // Account creation only happens with value transfer to non-existent account
        // We need to query the host to check if account exists
        const account_exists = frame.host.account_exists(to_address);
        if (!account_exists) {
            total_gas_cost += GasConstants.NewAccountCost;
        }
    }

    // Consume the gas for the CALL operation itself
    try frame.consume_gas(total_gas_cost);

    // Get call arguments from memory (this expands memory if needed)
    const args = try get_call_args(frame, args_offset, args_size);

    // Ensure return memory is available (this expands memory if needed)
    try ensure_return_memory(frame, ret_offset, ret_size);

    // Calculate gas limit for the called contract
    // Pass the gas already consumed for memory expansion and base costs
    const gas_limit = calculate_call_gas_amount(frame, gas, value, total_gas_cost);

    // Deduct the forwarded gas from remaining (but not the stipend)
    // The stipend is added "for free" and not deducted from caller
    const gas_to_deduct = if (value != 0)
        gas_limit - GasConstants.CallStipend
    else
        gas_limit;
    try frame.consume_gas(gas_to_deduct);

    // Create a journal snapshot before entering child frame
    // This allows us to revert all state changes if the call fails
    const snapshot = frame.journal.create_snapshot();

    // Access the VM through the host interface
    const host = frame.host;

    // Create call parameters
    const call_params = CallParams{ .call = .{
        .caller = frame.contract_address,
        .to = to_address,
        .value = value,
        .input = args,
        .gas = gas_limit,
    } };

    // Perform the call using the host's call method
    const call_result = host.call(call_params) catch {
        // On error, revert the snapshot and push 0 (failure)
        frame.journal.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };

    // Handle result based on success/failure
    if (call_result.success) {
        // Commit the snapshot on success (no-op in current implementation)
        // The journal entries persist for transaction-level revert capability
    } else {
        // Revert the snapshot on failure
        frame.journal.revert_to_snapshot(snapshot);
    }

    // Update gas remaining - return unused gas to caller
    // The gas_left from the call should be added back
    frame.gas_remaining += call_result.gas_left;

    // Write return data if successful and there's output
    if (call_result.success and call_result.output != null and ret_size > 0) {
        const output = call_result.output.?;
        const ret_offset_usize = @as(usize, @intCast(ret_offset));
        const ret_size_usize = @as(usize, @intCast(ret_size));
        const copy_size = @min(output.len, ret_size_usize);

        // Copy output to return memory area
        if (copy_size > 0) {
            try frame.memory.set_data_bounded(ret_offset_usize, output, 0, copy_size);
        }
    }

    // Push result (1 for success, 0 for failure)
    try frame.stack.append(if (call_result.success) 1 else 0);
}

pub fn op_callcode(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*Frame, @ptrCast(@alignCast(context)));
    _ = ctx;

    // TODO: Implementation requires:
    // - vm instance for callcode operations
    // - frame.contract.address access
    // - frame.is_static checks
    // - frame.return_data operations
    // - handle_call_result integration
}

pub fn op_delegatecall(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

    // Pop parameters from stack (DELEGATECALL has no value parameter)
    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    // CRITICAL FIX: Calculate memory expansion costs BEFORE expanding memory
    const args_end = if (args_size > 0) blk: {
        try check_offset_bounds(args_offset);
        try check_offset_bounds(args_size);
        const args_offset_usize = @as(usize, @intCast(args_offset));
        const args_size_usize = @as(usize, @intCast(args_size));
        const end = args_offset_usize + args_size_usize;
        if (end < args_offset_usize) return ExecutionError.Error.GasUintOverflow;
        break :blk end;
    } else 0;

    const ret_end = if (ret_size > 0) blk: {
        try check_offset_bounds(ret_offset);
        try check_offset_bounds(ret_size);
        const ret_offset_usize = @as(usize, @intCast(ret_offset));
        const ret_size_usize = @as(usize, @intCast(ret_size));
        const end = ret_offset_usize + ret_size_usize;
        if (end < ret_offset_usize) return ExecutionError.Error.GasUintOverflow;
        break :blk end;
    } else 0;

    const max_memory_size = @max(args_end, ret_end);
    const memory_expansion_cost = frame.memory.get_expansion_cost(max_memory_size);

    // Base gas cost for DELEGATECALL (700 gas)
    const base_gas = GasConstants.CALL_BASE_COST; // Same as CALL
    var total_gas_cost = base_gas + memory_expansion_cost;

    // Convert to address for warm/cold check
    const to_address = from_u256(to);

    // EIP-2929: Check if address is cold and add extra gas cost
    if (frame.is_at_least(.BERLIN)) {
        const access_cost = try frame.access_list.get_call_cost(to_address);
        total_gas_cost += access_cost;
    }

    // Consume gas before proceeding
    try frame.consume_gas(total_gas_cost);

    // Check call depth limit
    if (frame.hot_flags.depth >= 1024) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        return;
    }

    // Now expand memory after charging for it
    const args = try get_call_args(frame, args_offset, args_size);
    try ensure_return_memory(frame, ret_offset, ret_size);

    // Calculate gas to forward (63/64 rule)
    // DELEGATECALL never transfers value, so no stipend
    const gas_limit = calculate_call_gas_amount(frame, gas, 0, total_gas_cost);

    // Deduct the forwarded gas from remaining
    try frame.consume_gas(gas_limit);

    // Create a journal snapshot before entering child frame
    // This allows us to revert all state changes if the call fails
    const snapshot = frame.journal.create_snapshot();

    // DELEGATECALL preserves the original caller and value from parent context
    // This is critical for proxy patterns and library calls
    const call_params = CallParams{
        .delegatecall = .{
            .caller = frame.caller, // Preserve original caller, not current contract
            .to = to_address,
            .input = args,
            .gas = gas_limit,
        },
    };

    // Execute the delegatecall through the host
    const call_result = frame.host.call(call_params) catch {
        // On error, revert the snapshot and push 0 (failure)
        frame.journal.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };

    // Handle result based on success/failure
    if (call_result.success) {
        // Commit the snapshot on success (no-op in current implementation)
        // The journal entries persist for transaction-level revert capability
    } else {
        // Revert the snapshot on failure
        frame.journal.revert_to_snapshot(snapshot);
    }

    // Store return data if any
    if (call_result.output) |output| {
        if (ret_size > 0) {
            const ret_offset_usize = @as(usize, @intCast(ret_offset));
            const ret_size_usize = @as(usize, @intCast(ret_size));
            const copy_size = @min(ret_size_usize, output.len);
            try frame.memory.set_data_bounded(ret_offset_usize, output, 0, copy_size);
        }
    }

    // Push success flag (1 for success, 0 for failure)
    try frame.stack.append(if (call_result.success) 1 else 0);
}

pub fn op_staticcall(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

    // Pop parameters from stack (STATICCALL has no value parameter)
    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    // CRITICAL FIX: Calculate memory expansion costs BEFORE expanding memory
    const args_end = if (args_size > 0) blk: {
        try check_offset_bounds(args_offset);
        try check_offset_bounds(args_size);
        const args_offset_usize = @as(usize, @intCast(args_offset));
        const args_size_usize = @as(usize, @intCast(args_size));
        const end = args_offset_usize + args_size_usize;
        if (end < args_offset_usize) return ExecutionError.Error.GasUintOverflow;
        break :blk end;
    } else 0;

    const ret_end = if (ret_size > 0) blk: {
        try check_offset_bounds(ret_offset);
        try check_offset_bounds(ret_size);
        const ret_offset_usize = @as(usize, @intCast(ret_offset));
        const ret_size_usize = @as(usize, @intCast(ret_size));
        const end = ret_offset_usize + ret_size_usize;
        if (end < ret_offset_usize) return ExecutionError.Error.GasUintOverflow;
        break :blk end;
    } else 0;

    const max_memory_size = @max(args_end, ret_end);
    const memory_expansion_cost = frame.memory.get_expansion_cost(max_memory_size);

    // Base gas cost for STATICCALL (700 gas)
    const base_gas = GasConstants.CALL_BASE_COST; // Same as CALL/DELEGATECALL
    var total_gas_cost = base_gas + memory_expansion_cost;

    // Convert to address for warm/cold check
    const to_address = from_u256(to);

    // EIP-2929: Check if address is cold and add extra gas cost
    if (frame.is_at_least(.BERLIN)) {
        const access_cost = try frame.access_list.get_call_cost(to_address);
        total_gas_cost += access_cost;
    }

    // Consume gas before proceeding
    try frame.consume_gas(total_gas_cost);

    // Check call depth limit
    if (frame.hot_flags.depth >= 1024) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        return;
    }

    // Now expand memory after charging for it
    const args = try get_call_args(frame, args_offset, args_size);
    try ensure_return_memory(frame, ret_offset, ret_size);

    // Calculate gas to forward (63/64 rule)
    // STATICCALL never transfers value, so no stipend
    const gas_limit = calculate_call_gas_amount(frame, gas, 0, total_gas_cost);

    // Deduct the forwarded gas from remaining
    try frame.consume_gas(gas_limit);

    // Create a journal snapshot before entering child frame
    // Even though STATICCALL is read-only, we still snapshot for consistency
    // and to handle any edge cases (e.g., gas accounting, access lists)
    const snapshot = frame.journal.create_snapshot();

    // STATICCALL enforces read-only context - no state changes allowed
    const call_params = CallParams{
        .staticcall = .{
            .caller = frame.contract_address,
            .to = to_address,
            .input = args,
            .gas = gas_limit,
        },
    };

    // Execute the staticcall through the host
    const call_result = frame.host.call(call_params) catch {
        // On error, revert the snapshot and push 0 (failure)
        frame.journal.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };

    // Handle result based on success/failure
    if (call_result.success) {
        // Commit the snapshot on success (no-op in current implementation)
        // The journal entries persist for transaction-level revert capability
    } else {
        // Revert the snapshot on failure (shouldn't have state changes, but be consistent)
        frame.journal.revert_to_snapshot(snapshot);
    }

    // Store return data if any
    if (call_result.output) |output| {
        if (ret_size > 0) {
            const ret_offset_usize = @as(usize, @intCast(ret_offset));
            const ret_size_usize = @as(usize, @intCast(ret_size));
            const copy_size = @min(ret_size_usize, output.len);
            try frame.memory.set_data_bounded(ret_offset_usize, output, 0, copy_size);
        }
    }

    // Push success flag (1 for success, 0 for failure)
    try frame.stack.append(if (call_result.success) 1 else 0);
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
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

    // Check static call restriction
    if (frame.is_static()) {
        return ExecutionError.Error.WriteProtection;
    }

    // Pop recipient address from stack
    const recipient = try frame.stack.pop();
    const recipient_address = from_u256(recipient);

    // Calculate gas cost
    var gas_cost = GasConstants.SelfDestructCost;

    // EIP-2929: Check if recipient is cold and add extra gas cost
    if (frame.is_at_least(.BERLIN)) {
        const access_cost = try frame.access_list.get_call_cost(recipient_address);
        gas_cost += access_cost;
    }

    // Consume gas
    try frame.consume_gas(gas_cost);

    // Record the self-destruct operation in the journal
    try frame.journal.record_selfdestruct(frame.snapshot_id, frame.contract_address, recipient_address);

    // Mark for destruction using the existing self_destruct system if available
    if (frame.self_destruct) |sd| {
        try sd.mark_for_destruction(frame.contract_address, recipient_address);
    }

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
fn validate_system_result(frame: *const Frame, op: FuzzSystemOperation, result: anyerror!void) !void {
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

test "CALL with value guarantees 2300 gas stipend added to forwarded gas" {
    // Test with simple frame struct that has only what calculate_call_gas_amount needs
    var frame = struct {
        gas_remaining: u64,
    }{
        .gas_remaining = 10000, // Sufficient gas remaining
    };

    // Test 1: With value transfer, stipend is ADDED to forwarded gas
    {
        const gas_requested: primitives.u256 = 1000; // Request 1000 gas
        const value: primitives.u256 = 1; // Non-zero value triggers stipend
        const already_consumed: u64 = 100; // Some gas already consumed

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available after consumed: 10000 - 100 = 9900
        // Max forwardable: 9900 - (9900/64) = 9900 - 154 = 9746
        // Requested: 1000 (less than max)
        // With stipend: 1000 + 2300 = 3300
        try testing.expectEqual(@as(u64, 1000 + GasConstants.GAS_STIPEND_VALUE_TRANSFER), gas_for_call);
    }

    // Test 2: EIP-150 63/64 rule limits gas forwarding
    {
        frame.gas_remaining = 6400; // Specific amount for easy calculation
        const gas_requested: primitives.u256 = 10000; // Request more than available
        const value: primitives.u256 = 0; // No value, no stipend
        const already_consumed: u64 = 0;

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available: 6400
        // One 64th: 6400 / 64 = 100
        // Max forwardable: 6400 - 100 = 6300
        // No stipend since value = 0
        try testing.expectEqual(@as(u64, 6300), gas_for_call);
    }

    // Test 3: Stipend is added even when gas is limited by 63/64 rule
    {
        frame.gas_remaining = 640; // Low gas
        const gas_requested: primitives.u256 = 1000; // Request more than available
        const value: primitives.u256 = 1; // Non-zero value
        const already_consumed: u64 = 0;

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available: 640
        // One 64th: 640 / 64 = 10
        // Max forwardable: 640 - 10 = 630
        // With stipend: 630 + 2300 = 2930
        try testing.expectEqual(@as(u64, 630 + GasConstants.GAS_STIPEND_VALUE_TRANSFER), gas_for_call);
    }
}

test "CALL without value respects gas limit without stipend" {
    // Test with simple frame struct that has only what calculate_call_gas_amount needs
    var frame = struct {
        gas_remaining: u64,
    }{
        .gas_remaining = 1000,
    };

    // Test: Without value transfer, no stipend should be applied
    {
        const gas_requested: primitives.u256 = 50; // Request only 50 gas
        const value: primitives.u256 = 0; // Zero value - no stipend
        const already_consumed: u64 = 0;

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available: 1000
        // One 64th: 1000 / 64 = 15
        // Max forwardable: 1000 - 15 = 985
        // Requested: 50 (less than max)
        // No stipend since value = 0
        try testing.expectEqual(@as(u64, 50), gas_for_call);
        try testing.expect(gas_for_call < GasConstants.GAS_STIPEND_VALUE_TRANSFER);
    }
}

test "EIP-150 gas calculations for nested calls" {
    // Test nested call gas calculations following EIP-150 semantics
    var frame = struct {
        gas_remaining: u64,
    }{
        .gas_remaining = 100000,
    };

    // Test 1: First level call gets 63/64 of available gas
    {
        const gas_requested: primitives.u256 = std.math.maxInt(u64); // Request all gas
        const value: primitives.u256 = 0;
        const already_consumed: u64 = 1000; // Some overhead

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available after consumed: 100000 - 1000 = 99000
        // One 64th: 99000 / 64 = 1546
        // Max forwardable: 99000 - 1546 = 97454
        const expected = (100000 - 1000) - ((100000 - 1000) / 64);
        try testing.expectEqual(expected, gas_for_call);
    }

    // Test 2: Simulate second level call (from within first call)
    {
        frame.gas_remaining = 97454; // Gas forwarded to first call
        const gas_requested: primitives.u256 = std.math.maxInt(u64);
        const value: primitives.u256 = 0;
        const already_consumed: u64 = 500; // Some overhead in nested call

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available after consumed: 97454 - 500 = 96954
        // One 64th: 96954 / 64 = 1514
        // Max forwardable: 96954 - 1514 = 95440
        const expected = (97454 - 500) - ((97454 - 500) / 64);
        try testing.expectEqual(expected, gas_for_call);
    }
}

test "EIP-150 minimum gas retention" {
    // Test that caller always retains at least 1/64 of gas
    var frame = struct {
        gas_remaining: u64,
    }{
        .gas_remaining = 64, // Exactly 64 gas
    };

    // Caller should retain exactly 1 gas (64/64 = 1)
    {
        const gas_requested: primitives.u256 = 100; // Request more than available
        const value: primitives.u256 = 0;
        const already_consumed: u64 = 0;

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available: 64
        // One 64th: 64 / 64 = 1
        // Max forwardable: 64 - 1 = 63
        try testing.expectEqual(@as(u64, 63), gas_for_call);
    }

    // Test with very low gas (less than 64)
    frame.gas_remaining = 32;
    {
        const gas_requested: primitives.u256 = 100;
        const value: primitives.u256 = 0;
        const already_consumed: u64 = 0;

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available: 32
        // One 64th: 32 / 64 = 0 (integer division)
        // Max forwardable: 32 - 0 = 32 (all gas can be forwarded)
        try testing.expectEqual(@as(u64, 32), gas_for_call);
    }
}

test "EIP-150 stipend edge cases" {
    // Test edge cases around the 2300 gas stipend
    var frame = struct {
        gas_remaining: u64,
    }{
        .gas_remaining = 100, // Very low gas
    };

    // Test 1: Stipend is added even when caller has very low gas
    {
        const gas_requested: primitives.u256 = 10;
        const value: primitives.u256 = 1; // Value transfer
        const already_consumed: u64 = 0;

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Available: 100
        // One 64th: 100 / 64 = 1
        // Max forwardable: 100 - 1 = 99
        // Requested: 10 (less than max)
        // With stipend: 10 + 2300 = 2310
        try testing.expectEqual(@as(u64, 10 + GasConstants.GAS_STIPEND_VALUE_TRANSFER), gas_for_call);
    }

    // Test 2: Stipend with zero gas requested
    {
        const gas_requested: primitives.u256 = 0; // Request zero gas
        const value: primitives.u256 = 1; // Value transfer
        const already_consumed: u64 = 0;

        const gas_for_call = calculate_call_gas_amount(&frame, gas_requested, value, already_consumed);

        // Even with 0 gas requested, stipend ensures 2300 gas
        try testing.expectEqual(@as(u64, GasConstants.GAS_STIPEND_VALUE_TRANSFER), gas_for_call);
    }
}
