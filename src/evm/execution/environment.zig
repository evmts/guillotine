const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../execution_context.zig").ExecutionContext;
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;

pub fn op_address(context: *ExecutionContext) ExecutionError.Error!void {
    // Push contract address as u256
    const addr = to_u256(context.contract_address);
    try context.stack.append(addr);
}

pub fn op_balance(context: *ExecutionContext) ExecutionError.Error!void {
    const address_u256 = try context.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try context.access_list.access_address(address);
    try context.consume_gas(access_cost);

    // Get balance from state database
    const balance = context.state.get_balance(address);
    try context.stack.append(balance);
}

pub fn op_origin(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need tx_origin field in ExecutionContext
    // Push transaction origin address
    // const origin = to_u256(context.tx_origin);
    // try context.stack.append(origin);
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_caller(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need caller field in ExecutionContext
    // Push caller address
    // const caller = to_u256(context.caller);
    // try context.stack.append(caller);
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_callvalue(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need call_value field in ExecutionContext
    // Push call value
    // try context.stack.append(context.call_value);
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_gasprice(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need gas_price field in ExecutionContext
    // Push gas price from transaction context
    // try context.stack.append(context.gas_price);
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_extcodesize(context: *ExecutionContext) ExecutionError.Error!void {
    const address_u256 = try context.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try context.access_list.access_address(address);
    try context.consume_gas(access_cost);

    // Get code size from state database
    const code = context.state.get_code(address);
    try context.stack.append(@as(u256, @intCast(code.len)));
}

pub fn op_extcodecopy(context: *ExecutionContext) ExecutionError.Error!void {
    const address_u256 = try context.stack.pop();
    const mem_offset = try context.stack.pop();
    const code_offset = try context.stack.pop();
    const size = try context.stack.pop();

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
    const access_cost = try context.access_list.access_address(address);
    try context.consume_gas(access_cost);

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = context.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try context.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try context.consume_gas(GasConstants.CopyGas * word_size);

    // Get external code from state database
    const code = context.state.get_code(address);

    // Use set_data_bounded to copy the code to memory
    // This handles partial copies and zero-padding automatically
    try context.memory.set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize);
}

pub fn op_extcodehash(context: *ExecutionContext) ExecutionError.Error!void {
    const address_u256 = try context.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try context.access_list.access_address(address);
    try context.consume_gas(access_cost);

    // Get code from state database and compute hash
    const code = context.state.get_code(address);
    if (code.len == 0) {
        @branchHint(.unlikely);
        // Empty account - return zero
        try context.stack.append(0);
    } else {
        // Compute keccak256 hash of the code
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

        // Convert hash to u256 using std.mem for efficiency
        const hash_u256 = std.mem.readInt(u256, &hash, .big);
        try context.stack.append(hash_u256);
    }
}

pub fn op_selfbalance(context: *ExecutionContext) ExecutionError.Error!void {
    // Get balance of current executing contract
    const self_address = context.contract_address;
    const balance = context.state.get_balance(self_address);
    try context.stack.append(balance);
}

pub fn op_chainid(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need chain_id field in ExecutionContext
    // Push chain ID from transaction context
    // try context.stack.append(context.chain_id);
    
    // Placeholder implementation - push mainnet chain ID
    try context.stack.append(1);
}

pub fn op_calldatasize(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need input/calldata field in ExecutionContext
    // Push size of calldata
    // try context.stack.append(@as(u256, @intCast(context.input.len)));
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_codesize(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need contract_code field in ExecutionContext
    // Push size of current contract's code
    // try context.stack.append(@as(u256, @intCast(context.contract_code.len)));
    
    // Placeholder implementation - push zero for now
    try context.stack.append(0);
}

pub fn op_calldataload(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need input/calldata field in ExecutionContext
    // Pop offset from stack
    const offset = try context.stack.pop();

    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        // Offset too large, push zero
        try context.stack.append(0);
        return;
    }

    
    // TODO: Implement calldataload with ExecutionContext
    // const offset_usize = @as(usize, @intCast(offset));
    // const calldata = context.input;
    // ... load logic ...
    
    try context.stack.append(0);
}

pub fn op_calldatacopy(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need input/calldata field in ExecutionContext
    // Pop memory offset, data offset, and size
    const mem_offset = try context.stack.pop();
    const data_offset = try context.stack.pop();
    const size = try context.stack.pop();

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
    // const memory_gas = context.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    // try context.consume_gas(memory_gas);
    //
    // // Dynamic gas for copy operation (VERYLOW * word_count)
    // const word_size = (size_usize + 31) / 32;
    // try context.consume_gas(GasConstants.CopyGas * word_size);
    //
    // // Copy from calldata to memory
    // const calldata = context.input;
    // try context.memory.set_data_bounded(mem_offset_usize, calldata, data_offset_usize, size_usize);
}

pub fn op_codecopy(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need contract_code field in ExecutionContext
    // Pop memory offset, code offset, and size
    const mem_offset = try context.stack.pop();
    const code_offset = try context.stack.pop();
    const size = try context.stack.pop();

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
    // const memory_gas = context.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    // try context.consume_gas(memory_gas);
    //
    // // Dynamic gas for copy operation
    // const word_size = (size_usize + 31) / 32;
    // try context.consume_gas(GasConstants.CopyGas * word_size);
    //
    // // Copy current contract code to memory
    // const code = context.contract_code;
    // try context.memory.set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize);
}
/// RETURNDATALOAD opcode (0xF7): Loads a 32-byte word from return data
/// This is an EOF opcode that allows reading from the return data buffer
pub fn op_returndataload(context: *ExecutionContext) ExecutionError.Error!void {
    // TODO: Need return_data field in ExecutionContext
    // Pop offset from stack
    const offset = try context.stack.pop();

    // Check if offset is within bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    
    // TODO: Implement returndataload with ExecutionContext
    // const offset_usize = @as(usize, @intCast(offset));
    // const return_data = context.return_data;
    // ... load logic ...
    
    try context.stack.append(0);
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
