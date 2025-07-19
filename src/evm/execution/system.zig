const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const Contract = @import("../frame/contract.zig");
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const gas_constants = @import("../constants/gas_constants.zig");
const AccessList = @import("../access_list/access_list.zig").AccessList;
const Log = @import("../log.zig");

// ============================================================================
// Call Operation Types and Gas Calculation
// ============================================================================

/// Call operation types for gas calculation
pub const CallType = enum {
    Call,
    CallCode,
    DelegateCall,
    StaticCall,
};



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
        .Call => if (value > 0) gas_constants.CallValueCost else gas_constants.CallCodeCost,
        .CallCode => gas_constants.CallCodeCost,
        .DelegateCall => gas_constants.DelegateCallCost,
        .StaticCall => gas_constants.StaticCallCost,
    };

    // Account access cost (EIP-2929)
    if (is_cold_access) {
        gas_cost += gas_constants.ColdAccountAccessCost;
    }

    // Memory expansion cost
    gas_cost += memory_expansion_cost;

    // Account creation cost for new accounts with value transfer
    if (!target_exists and call_type == .Call and value > 0) {
        gas_cost += gas_constants.NewAccountCost;
    }

    // Calculate available gas for forwarding after subtracting operation costs
    if (gas_cost >= remaining_gas) {
        return gas_cost; // Out of gas - no forwarding possible
    }

    const gas_after_operation = remaining_gas - gas_cost;

    // Apply 63/64th rule to determine maximum forwardable gas (EIP-150)
    const max_forwardable = (gas_after_operation * 63) / 64;

    // Use minimum of requested gas and maximum forwardable
    const gas_to_forward = @min(local_gas_limit, max_forwardable);

    return gas_cost + gas_to_forward;
}

// ============================================================================
// Return Data Opcodes (EIP-211)
// ============================================================================

// Gas opcode handler
pub fn gas_op(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    try frame.stack.append(@as(u256, @intCast(frame.gas_remaining)));

    return Operation.ExecutionResult{};
}

// Helper to check if u256 fits in usize
fn check_offset_bounds(value: u256) ExecutionError.Error!void {
    if (value > std.math.maxInt(usize)) {
        @branchHint(.cold);
        return ExecutionError.Error.InvalidOffset;
    }
}

/// Get call arguments from memory, handling memory expansion
fn get_call_arguments(frame: *Frame, offset: u256, size: u256) ExecutionError.Error![]const u8 {
    var args: []const u8 = &[_]u8{};
    if (size > 0) {
        try check_offset_bounds(offset);
        try check_offset_bounds(size);

        const offset_usize = @as(usize, @intCast(offset));
        const size_usize = @as(usize, @intCast(size));

        _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);
        args = try frame.memory.get_slice(offset_usize, size_usize);
    }
    return args;
}

/// Prepare return memory for writing call results
fn prepare_return_memory(frame: *Frame, ret_offset: u256, ret_size: u256) ExecutionError.Error!void {
    if (ret_size > 0) {
        try check_offset_bounds(ret_offset);
        try check_offset_bounds(ret_size);

        const ret_offset_usize = @as(usize, @intCast(ret_offset));
        const ret_size_usize = @as(usize, @intCast(ret_size));

        _ = try frame.memory.ensure_context_capacity(ret_offset_usize + ret_size_usize);
    }
}

/// Write return data to memory after call execution
fn write_return_data(frame: *Frame, output: ?[]const u8, ret_offset: u256, ret_size: u256) void {
    if (ret_size > 0 and output != null) {
        const ret_offset_usize = @as(usize, @intCast(ret_offset));
        const ret_size_usize = @as(usize, @intCast(ret_size));
        const output_data = output.?;

        const copy_size = @min(ret_size_usize, output_data.len);
        const memory_slice = frame.memory.slice();
        std.mem.copyForwards(u8, memory_slice[ret_offset_usize .. ret_offset_usize + copy_size], output_data[0..copy_size]);

        // Zero out remaining bytes if output was smaller than requested
        if (copy_size < ret_size_usize) {
            @branchHint(.unlikely);
            @memset(memory_slice[ret_offset_usize + copy_size .. ret_offset_usize + ret_size_usize], 0);
        }
    }
}

/// Handle EIP-2929 cold access checking
fn handle_cold_access(vm: *Vm, frame: *Frame, address: primitives.Address.Address) ExecutionError.Error!void {
    const access_cost = try vm.access_list.access_address(address);
    const is_cold = access_cost == AccessList.COLD_ACCOUNT_ACCESS_COST;
    if (is_cold) {
        @branchHint(.unlikely);
        try frame.consume_gas(gas_constants.ColdAccountAccessCost);
    }
}

/// Calculate gas for call and apply 63/64 forwarding rule
fn calculate_call_gas_forward(frame: *Frame, gas_requested: u256, value: u256) u64 {
    var gas_for_call = if (gas_requested > std.math.maxInt(u64)) std.math.maxInt(u64) else @as(u64, @intCast(gas_requested));
    gas_for_call = @min(gas_for_call, (frame.gas_remaining * 63) / 64);
    
    if (value != 0) {
        gas_for_call += 2300; // Stipend for value transfers
    }
    
    return gas_for_call;
}

/// Unified call execution for all call types
fn execute_call_operation(
    vm: *Vm,
    frame: *Frame,
    call_type: CallType,
    gas: u256,
    to: u256,
    value: u256,
    args_offset: u256,
    args_size: u256,
    ret_offset: u256,
    ret_size: u256
) ExecutionError.Error!Operation.ExecutionResult {
    // Check static call value restrictions
    if (frame.is_static and value != 0) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Check depth limit
    if (frame.depth >= 1024) {
        @branchHint(.cold);
        try frame.stack.append(0);
        return Operation.ExecutionResult{};
    }

    // Get call arguments from memory
    const args = try get_call_arguments(frame, args_offset, args_size);

    // Prepare return memory
    try prepare_return_memory(frame, ret_offset, ret_size);

    // Convert to address
    const to_address = from_u256(to);

    // Handle EIP-2929 cold access checking
    try handle_cold_access(vm, frame, to_address);

    // Calculate gas for the call
    const gas_for_call = calculate_call_gas_forward(frame, gas, value);

    // Execute the appropriate call type
    const result = switch (call_type) {
        .Call => try vm.call_contract(frame.contract.address, to_address, value, args, gas_for_call, frame.is_static),
        .CallCode => try vm.callcode_contract(frame.contract.address, to_address, value, args, gas_for_call, frame.is_static),
        .DelegateCall => try vm.delegatecall_contract(frame.contract.address, to_address, frame.contract.caller, frame.contract.value, args, gas_for_call, frame.is_static),
        .StaticCall => try vm.staticcall_contract(frame.contract.address, to_address, args, gas_for_call),
    };
    defer if (result.output) |output| vm.allocator.free(output);

    // Update gas remaining
    frame.gas_remaining = frame.gas_remaining - gas_for_call + result.gas_left;

    // Write return data to memory if requested
    write_return_data(frame, result.output, ret_offset, ret_size);

    // Set return data
    try frame.return_data.set(result.output orelse &[_]u8{});

    // Push success status (bounds checking already done by jump table)
    frame.stack.append_unsafe(if (result.success) 1 else 0);

    return Operation.ExecutionResult{};
}

/// Unified CREATE operation for both CREATE and CREATE2
fn execute_create_operation(
    vm: *Vm,
    frame: *Frame,
    is_create2: bool,
    value: u256,
    offset: u256,
    size: u256,
    salt: u256
) ExecutionError.Error!Operation.ExecutionResult {
    // Check if we're in a static call
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Check depth
    if (frame.depth >= 1024) {
        @branchHint(.cold);
        try frame.stack.append(0);
        return Operation.ExecutionResult{};
    }

    // EIP-3860: Check initcode size limit FIRST (Shanghai and later)
    try check_offset_bounds(size);
    const size_usize = @as(usize, @intCast(size));
    if (vm.chain_rules.is_eip3860 and size_usize > gas_constants.MaxInitcodeSize) {
        @branchHint(.unlikely);
        return ExecutionError.Error.MaxCodeSizeExceeded;
    }

    // Get init code from memory
    var init_code: []const u8 = &[_]u8{};
    if (size > 0) {
        try check_offset_bounds(offset);

        const offset_usize = @as(usize, @intCast(offset));

        // Calculate memory expansion gas cost
        const current_size = frame.memory.total_size();
        const new_size = offset_usize + size_usize;
        const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);
        try frame.consume_gas(memory_gas);

        // Ensure memory is available and get the slice
        _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);
        init_code = try frame.memory.get_slice(offset_usize, size_usize);
    }

    // Calculate gas for creation
    const init_code_cost = @as(u64, @intCast(init_code.len)) * gas_constants.CreateDataGas;
    
    // CREATE2 specific hash cost
    const hash_cost = if (is_create2) 
        @as(u64, @intCast(gas_constants.wordCount(init_code.len))) * gas_constants.Keccak256WordGas
    else 
        0;

    // EIP-3860: Add gas cost for initcode word size (2 gas per 32-byte word) - Shanghai and later
    const initcode_word_cost = if (vm.chain_rules.is_eip3860)
        @as(u64, @intCast(gas_constants.wordCount(init_code.len))) * gas_constants.InitcodeWordGas
    else
        0;
    
    try frame.consume_gas(init_code_cost + hash_cost + initcode_word_cost);

    // Calculate gas to give to the new contract (EIP-150: 63/64 forwarding rule)
    const gas_for_call = (frame.gas_remaining * 63) / 64;

    // Create the contract
    const result = if (is_create2)
        try vm.create2_contract(frame.contract.address, value, init_code, salt, gas_for_call)
    else
        try vm.create_contract(frame.contract.address, value, init_code, gas_for_call);

    // Update gas remaining (1/64 kept + unused gas from call)
    frame.gas_remaining = frame.gas_remaining - gas_for_call + result.gas_left;

    if (!result.success) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        try frame.return_data.set(result.output orelse &[_]u8{});
        return Operation.ExecutionResult{};
    }

    // EIP-2929: Mark the newly created address as warm
    _ = try vm.access_list.access_address(result.address);
    try frame.stack.append(to_u256(result.address));

    // Set return data
    try frame.return_data.set(result.output orelse &[_]u8{});

    return Operation.ExecutionResult{};
}


pub fn op_create(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    const value = try frame.stack.pop();
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    return execute_create_operation(vm, frame, false, value, offset, size, 0);
}

/// CREATE2 opcode - Create contract with deterministic address
pub fn op_create2(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    const value = try frame.stack.pop();
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();
    const salt = try frame.stack.pop();

    return execute_create_operation(vm, frame, true, value, offset, size, salt);
}

pub fn op_call(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const value = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    return execute_call_operation(vm, frame, .Call, gas, to, value, args_offset, args_size, ret_offset, ret_size);
}

pub fn op_callcode(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const value = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    return execute_call_operation(vm, frame, .CallCode, gas, to, value, args_offset, args_size, ret_offset, ret_size);
}

pub fn op_delegatecall(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    // DELEGATECALL takes 6 parameters (no value parameter)
    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    return execute_call_operation(vm, frame, .DelegateCall, gas, to, 0, args_offset, args_size, ret_offset, ret_size);
}

pub fn op_staticcall(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    // STATICCALL takes 6 parameters (no value parameter)
    const gas = try frame.stack.pop();
    const to = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();

    return execute_call_operation(vm, frame, .StaticCall, gas, to, 0, args_offset, args_size, ret_offset, ret_size);
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
pub fn op_selfdestruct(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const vm: *Vm = @ptrCast(interpreter);
    const frame: *Frame = @ptrCast(state);

    // Static call protection - SELFDESTRUCT forbidden in static context
    if (frame.is_static) {
        @branchHint(.cold);
        return ExecutionError.Error.WriteProtection;
    }

    // Pop recipient address from stack (bounds checking already done by jump table)
    const recipient_u256 = frame.stack.pop_unsafe();
    const recipient_address = from_u256(recipient_u256);

    // Get hardfork rules for gas calculation
    const chain_rules = vm.chain_rules;
    var gas_cost: u64 = 0;

    // Calculate base gas cost based on hardfork
    if (chain_rules.is_eip150) {
        gas_cost += gas_constants.SelfdestructGas; // 5000 gas
    }
    // Before Tangerine Whistle: 0 gas cost

    // EIP-161: Account creation cost if transferring to a non-existent account
    if (chain_rules.is_eip158) {
        @branchHint(.likely);

        // Check if the recipient account exists and is empty
        const recipient_exists = vm.state.account_exists(recipient_address);
        if (!recipient_exists) {
            @branchHint(.cold);
            gas_cost += gas_constants.CallNewAccountGas; // 25000 gas
        }
    }

    // Account for access list gas costs (EIP-2929)
    if (chain_rules.is_berlin) {
        @branchHint(.likely);

        // Warm up recipient address access
        const access_cost = vm.state.warm_account_access(recipient_address);
        gas_cost += access_cost;
    }

    // Check if we have enough gas
    if (gas_cost > frame.gas_remaining) {
        @branchHint(.cold);
        return ExecutionError.Error.OutOfGas;
    }

    // Consume gas
    frame.gas_remaining -= gas_cost;

    // Mark contract for destruction with recipient
    vm.state.mark_for_destruction(frame.contract.address, recipient_address);

    // SELFDESTRUCT halts execution immediately
    return ExecutionError.Error.STOP;
}

/// EXTCALL opcode (0xF8): External call with EOF validation
/// Not implemented - EOF feature
pub fn op_extcall(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    _ = state;

    // This is an EOF (EVM Object Format) opcode, not yet implemented
    return ExecutionError.Error.EOFNotSupported;
}

/// EXTDELEGATECALL opcode (0xF9): External delegate call with EOF validation
/// Not implemented - EOF feature
pub fn op_extdelegatecall(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    _ = state;

    // This is an EOF (EVM Object Format) opcode, not yet implemented
    return ExecutionError.Error.EOFNotSupported;
}

/// EXTSTATICCALL opcode (0xFB): External static call with EOF validation
/// Not implemented - EOF feature
pub fn op_extstaticcall(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    _ = state;

    // This is an EOF (EVM Object Format) opcode, not yet implemented
    return ExecutionError.Error.EOFNotSupported;
}
