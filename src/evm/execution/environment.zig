//! Environment information opcodes for the Ethereum Virtual Machine
//!
//! This module implements opcodes that provide access to execution environment
//! data including addresses, balances, gas information, and transaction details.
//!
//! ## Gas Costs
//! - ADDRESS, ORIGIN, CALLER, CALLVALUE, CALLDATASIZE, CODESIZE, GASPRICE: 2 gas
//! - BALANCE, EXTCODESIZE, EXTCODEHASH: 100 gas (warm) or 2600 gas (cold)
//! - CALLDATALOAD, CALLDATACOPY, CODECOPY, EXTCODECOPY: 3 gas + copy costs
//! - RETURNDATASIZE: 2 gas
//! - RETURNDATACOPY: 3 gas + copy costs
//! - GAS: 2 gas
//! - SELFBALANCE: 5 gas
//! - CHAINID: 2 gas
//!
//! ## EIP Changes
//! - EIP-2929: Gas cost changes for cold account access
//! - EIP-3198: BASEFEE opcode
//! - EIP-1884: SELFBALANCE opcode

const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;

/// ADDRESS opcode (0x30) - Get address of currently executing account
///
/// Pushes the address of the currently executing contract.
/// Stack: [] → [address]
pub fn op_address(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const addr = to_u256(frame.contract_address);
    try frame.stack.append(addr);
}

/// BALANCE opcode (0x31) - Get balance of an account
///
/// Pops an address and pushes the balance of that account in wei.
/// Subject to EIP-2929 gas costs for cold account access.
/// Stack: [address] → [balance]
pub fn op_balance(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get balance from state database
    const balance = try frame.state.get_balance(address);
    try frame.stack.append(balance);
}

/// ORIGIN opcode (0x32) - Get execution origination address
///
/// Pushes the address of the account that initiated the transaction.
/// Stack: [] → [origin]
pub fn op_origin(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need tx_origin field in ExecutionContext
    // const origin = to_u256(frame.tx_origin);
    // try frame.stack.append(origin);

    // Placeholder implementation
    try frame.stack.append(0);
}

/// CALLER opcode (0x33) - Get caller address
///
/// Pushes the address of the account that directly called this contract.
/// Stack: [] → [caller]
pub fn op_caller(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need caller field in ExecutionContext
    // const caller = to_u256(frame.caller);
    // try frame.stack.append(caller);

    // Placeholder implementation
    try frame.stack.append(0);
}

/// CALLVALUE opcode (0x34) - Get deposited value by instruction/transaction
///
/// Pushes the value in wei sent with the current call.
/// Stack: [] → [value]
pub fn op_callvalue(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need call_value field in ExecutionContext
    // try frame.stack.append(frame.call_value);

    // Placeholder implementation
    try frame.stack.append(0);
}

/// GASPRICE opcode (0x3A) - Get price of gas in current transaction
///
/// Pushes the gas price of the current transaction.
/// Stack: [] → [gas_price]
pub fn op_gasprice(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need gas_price field in ExecutionContext
    // try frame.stack.append(frame.gas_price);

    // Placeholder implementation
    try frame.stack.append(0);
}

/// EXTCODESIZE opcode (0x3B) - Get size of account's code
///
/// Pops an address and pushes the size of that account's code in bytes.
/// Subject to EIP-2929 gas costs for cold account access.
/// Stack: [address] → [size]
pub fn op_extcodesize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code size from state database
    const code = try frame.state.get_code_by_address(address);
    try frame.stack.append(@as(u256, @intCast(code.len)));
}

/// EXTCODECOPY opcode (0x3C) - Copy account's code to memory
///
/// Copies code from an external account to memory.
/// Subject to EIP-2929 gas costs for cold account access.
/// Stack: [address, mem_offset, code_offset, size] → []
pub fn op_extcodecopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
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
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Get external code from state database
    const code = try frame.state.get_code_by_address(address);

    // Use set_data_bounded to copy the code to memory
    // This handles partial copies and zero-padding automatically
    try frame.memory.set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize);
}

/// EXTCODEHASH opcode (0x3F) - Get hash of account's code
///
/// Pops an address and pushes the keccak256 hash of that account's code.
/// Returns 0 for empty accounts. Subject to EIP-2929 gas costs.
/// Stack: [address] → [hash]
pub fn op_extcodehash(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code from state database and compute hash
    const code = try frame.state.get_code_by_address(address);
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

/// SELFBALANCE opcode (0x47) - Get balance of current account
///
/// Pushes the balance of the currently executing contract (EIP-1884).
/// More efficient than using BALANCE with ADDRESS.
/// Stack: [] → [balance]
pub fn op_selfbalance(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // Get balance of current executing contract
    const self_address = frame.contract_address;
    const balance = try frame.state.get_balance(self_address);
    try frame.stack.append(balance);
}

/// CHAINID opcode (0x46) - Get chain ID
///
/// Pushes the chain ID of the current blockchain (EIP-1344).
/// Stack: [] → [chain_id]
pub fn op_chainid(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need chain_id field in ExecutionContext
    // Push chain ID from transaction context
    // try frame.stack.append(frame.chain_id);

    // Placeholder implementation - push mainnet chain ID
    try frame.stack.append(1);
}

/// CALLDATASIZE opcode (0x36) - Get size of input data
///
/// Pushes the size of the calldata in bytes.
/// Stack: [] → [size]
pub fn op_calldatasize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need input/calldata field in ExecutionContext
    // Push size of calldata
    // try frame.stack.append(@as(u256, @intCast(frame.input.len)));

    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

/// CODESIZE opcode (0x38) - Get size of code
///
/// Pushes the size of the currently executing contract's code in bytes.
/// Stack: [] → [size]
pub fn op_codesize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // Push size of current contract's code
    try frame.stack.append(@as(u256, @intCast(frame.analysis.code_len)));
}

/// CALLDATALOAD opcode (0x35) - Load input data
///
/// Loads 32 bytes from calldata at the given offset. Zero-pads if reading
/// past the end of calldata.
/// Stack: [offset] → [data]
pub fn op_calldataload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
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

/// CALLDATACOPY opcode (0x37) - Copy input data to memory
///
/// Copies data from calldata to memory. Zero-pads if reading past the end.
/// Stack: [mem_offset, data_offset, size] → []
pub fn op_calldatacopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need input/calldata field in ExecutionContext
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

/// CODECOPY opcode (0x39) - Copy code to memory
///
/// Copies the currently executing contract's code to memory.
/// Stack: [mem_offset, code_offset, size] → []
pub fn op_codecopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
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

    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const code_offset_usize = @as(usize, @intCast(code_offset));
    const size_usize = @as(usize, @intCast(size));

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation (VERYLOW * word_count)
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Copy from current contract bytecode (from analysis)
    const code = frame.analysis.code;
    try frame.memory.set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize);
}
/// RETURNDATALOAD opcode (0xF7) - Load return data
///
/// Loads 32 bytes from the return data buffer at the given offset (EOF opcode).
/// Reverts if offset + 32 exceeds return data size.
/// Stack: [offset] → [data]
pub fn op_returndataload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
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
