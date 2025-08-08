const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;

pub fn op_address(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // Push contract address as u256
    const addr = to_u256(frame.contract_address);
    try frame.stack.append(addr);
}

pub fn op_balance(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Get balance from state database
    const balance = frame.state.get_balance(address);
    try frame.stack.append(balance);
}

pub fn op_origin(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need tx_origin field in ExecutionContext
    // Push transaction origin address
    // const origin = to_u256(frame.tx_origin);
    // try frame.stack.append(origin);
    
    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

pub fn op_caller(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need caller field in ExecutionContext
    // Push caller address
    // const caller = to_u256(frame.caller);
    // try frame.stack.append(caller);
    
    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

pub fn op_callvalue(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need call_value field in ExecutionContext
    // Push call value
    // try frame.stack.append(frame.call_value);
    
    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

pub fn op_gasprice(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need gas_price field in ExecutionContext
    // Push gas price from transaction context
    // try frame.stack.append(frame.gas_price);
    
    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

pub fn op_extcodesize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code size from state database
    const code = frame.state.get_code(address);
    try frame.stack.append(@as(u256, @intCast(code.len)));
}

pub fn op_extcodecopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const mem_offset = try frame.stack.pop();
    const code_offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    if (size == 0) {
        @branchHint(.unlikely);
        return;
    }

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or code_offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const address = from_u256(address_u256);
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const code_offset_usize = @as(usize, @intCast(code_offset));
    const size_usize = @as(usize, @intCast(size));

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Get external code from state database
    const code = frame.state.get_code(address);

    // Use set_data_bounded to copy the code to memory
    // This handles partial copies and zero-padding automatically
    try frame.memory.set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize);
}

pub fn op_extcodehash(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code from state database and compute hash
    const code = frame.state.get_code(address);
    if (code.len == 0) {
        @branchHint(.unlikely);
        // Empty account - return zero
        try frame.stack.append(0);
    } else {
        // Compute keccak256 hash of the code
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

        // Convert hash to u256 using std.mem for efficiency
        const hash_u256 = std.mem.readInt(u256, &hash, .big);
        try frame.stack.append(hash_u256);
    }
}

pub fn op_selfbalance(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // Get balance of current executing contract
    const self_address = frame.contract_address;
    const balance = frame.state.get_balance(self_address);
    try frame.stack.append(balance);
}

pub fn op_chainid(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need chain_id field in ExecutionContext
    // Push chain ID from transaction context
    // try frame.stack.append(frame.chain_id);
    
    // Placeholder implementation - push mainnet chain ID
    try frame.stack.append(1);
}

pub fn op_calldatasize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need input/calldata field in ExecutionContext
    // Push size of calldata
    // try frame.stack.append(@as(u256, @intCast(frame.input.len)));
    
    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

pub fn op_codesize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need contract_code field in ExecutionContext
    // Push size of current contract's code
    // try frame.stack.append(@as(u256, @intCast(frame.contract_code.len)));
    
    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

pub fn op_calldataload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need input/calldata field in ExecutionContext
    // Pop offset from stack
    const offset = try frame.stack.pop();

    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        // Offset too large, push zero
        try frame.stack.append(0);
        return;
    }

    
    // TODO: Implement calldataload with ExecutionContext
    // const offset_usize = @as(usize, @intCast(offset));
    // const calldata = frame.input;
    // ... load logic ...
    
    try frame.stack.append(0);
}

pub fn op_calldatacopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need input/calldata field in ExecutionContext
    // Pop memory offset, data offset, and size
    const mem_offset = try frame.stack.pop();
    const data_offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    if (size == 0) {
        @branchHint(.unlikely);
        return;
    }

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize)) return ExecutionError.Error.OutOfOffset;
    
    // TODO: Implement calldatacopy with ExecutionContext
    // const mem_offset_usize = @as(usize, @intCast(mem_offset));
    // const data_offset_usize = @as(usize, @intCast(data_offset));
    // const size_usize = @as(usize, @intCast(size));
    //
    // // Calculate memory expansion gas cost
    // const new_size = mem_offset_usize + size_usize;
    // const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    // try frame.consume_gas(memory_gas);
    //
    // // Dynamic gas for copy operation (VERYLOW * word_count)
    // const word_size = (size_usize + 31) / 32;
    // try frame.consume_gas(GasConstants.CopyGas * word_size);
    //
    // // Copy from calldata to memory
    // const calldata = frame.input;
    // try frame.memory.set_data_bounded(mem_offset_usize, calldata, data_offset_usize, size_usize);
}

pub fn op_codecopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need contract_code field in ExecutionContext
    // Pop memory offset, code offset, and size
    const mem_offset = try frame.stack.pop();
    const code_offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    if (size == 0) {
        @branchHint(.unlikely);
        return;
    }

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or code_offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    
    // TODO: Implement codecopy with ExecutionContext
    // const mem_offset_usize = @as(usize, @intCast(mem_offset));
    // const code_offset_usize = @as(usize, @intCast(code_offset));
    // const size_usize = @as(usize, @intCast(size));
    //
    // // Calculate memory expansion gas cost
    // const new_size = mem_offset_usize + size_usize;
    // const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    // try frame.consume_gas(memory_gas);
    //
    // // Dynamic gas for copy operation
    // const word_size = (size_usize + 31) / 32;
    // try frame.consume_gas(GasConstants.CopyGas * word_size);
    //
    // // Copy current contract code to memory
    // const code = frame.contract_code;
    // try frame.memory.set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize);
}
/// RETURNDATALOAD opcode (0xF7): Loads a 32-byte word from return data
/// This is an EOF opcode that allows reading from the return data buffer
pub fn op_returndataload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    // TODO: Need return_data field in ExecutionContext
    // Pop offset from stack
    const offset = try frame.stack.pop();

    // Check if offset is within bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    
    // TODO: Implement returndataload with ExecutionContext
    // const offset_usize = @as(usize, @intCast(offset));
    // const return_data = frame.return_data;
    // ... load logic ...
    
    try frame.stack.append(0);
}

// TODO: Update fuzz testing functions for new ExecutionContext pattern
// The old fuzz testing functions have been removed because they used the old function signatures.
// They need to be rewritten to work with the new ExecutionContext-based functions.

// TODO: Restore FuzzEnvironmentOperation and EnvironmentOpType structs
// when fuzz testing is updated for ExecutionContext pattern

// TODO: Restore validate_environment_result function
// when fuzz testing is updated for ExecutionContext pattern

// TODO: Restore test "fuzz_environment_basic_operations"
// when fuzz testing is updated for ExecutionContext pattern

// TODO: Restore test "fuzz_environment_edge_cases"
// when fuzz testing is updated for ExecutionContext pattern

// TODO: Restore test "fuzz_environment_random_operations"
// when fuzz testing is updated for ExecutionContext pattern

// TODO: Restore test "fuzz_environment_data_operations"
// when fuzz testing is updated for ExecutionContext pattern
