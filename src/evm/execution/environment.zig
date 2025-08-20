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
const Frame = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;
const log = std.log.scoped(.default);

/// ADDRESS opcode (0x30) - Get address of currently executing account
///
/// Pushes the address of the currently executing contract.
/// Stack: [] → [address]
pub fn op_address(frame: *Frame) ExecutionError.Error!void {
    const addr = to_u256(frame.contract_address);
    frame.stack.append_unsafe(addr);
}

/// BALANCE opcode (0x31) - Get balance of an account
///
/// Pops an address and pushes the balance of that account in wei.
/// Subject to EIP-2929 gas costs for cold account access.
/// Stack: [address] → [balance]
pub fn op_balance(frame: *Frame) ExecutionError.Error!void {
    const address_u256 = frame.stack.peek_unsafe();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get balance from state database
    const balance = try frame.state.get_balance(address);
    frame.stack.set_top_unsafe(balance);
}

/// ORIGIN opcode (0x32) - Get execution origination address
///
/// Pushes the address of the account that initiated the transaction.
/// Stack: [] → [origin]
pub fn op_origin(frame: *Frame) ExecutionError.Error!void {
    // TODO: Need tx_origin field in ExecutionContext
    // const origin = to_u256(frame.tx_origin);
    // try frame.stack.append(origin);

    // Placeholder implementation - push zero for now
    frame.stack.append_unsafe(0);
}

/// CALLER opcode (0x33) - Get caller address
///
/// Pushes the address of the account that directly called this contract.
/// Stack: [] → [caller]
pub fn op_caller(frame: *Frame) ExecutionError.Error!void {
    const caller = to_u256(frame.caller);
    frame.stack.append_unsafe(caller);
}

/// CALLVALUE opcode (0x34) - Get deposited value by instruction/transaction
///
/// Pushes the value in wei sent with the current call.
/// Stack: [] → [value]
pub fn op_callvalue(frame: *Frame) ExecutionError.Error!void {
    frame.stack.append_unsafe(frame.value);
}

/// GASPRICE opcode (0x3A) - Get price of gas in current transaction
///
/// Pushes the gas price of the current transaction.
/// Stack: [] → [gas_price]
pub fn op_gasprice(frame: *Frame) ExecutionError.Error!void {
    // TODO: Need gas_price field in ExecutionContext
    // try frame.stack.append(frame.gas_price);

    // Placeholder implementation - push zero for now
    frame.stack.append_unsafe(0);
}

/// EXTCODESIZE opcode (0x3B) - Get size of account's code
///
/// Pops an address and pushes the size of that account's code in bytes.
/// Subject to EIP-2929 gas costs for cold account access.
/// Stack: [address] → [size]
pub fn op_extcodesize(frame: *Frame) ExecutionError.Error!void {
    const address_u256 = frame.stack.pop_unsafe();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code size from state database
    const code = try frame.state.get_code_by_address(address);
    frame.stack.append_unsafe(@as(u256, @intCast(code.len)));
}

/// EXTCODECOPY opcode (0x3C) - Copy account's code to memory
///
/// Copies code from an external account to memory.
/// Subject to EIP-2929 gas costs for cold account access.
/// Stack: [address, mem_offset, code_offset, size] → []
pub fn op_extcodecopy(frame: *Frame) ExecutionError.Error!void {
    // EVM stack order (top -> bottom): address, destOffset, offset, length
    // So we pop in reverse: length, offset, destOffset, address
    const address_u256 = frame.stack.pop_unsafe();
    const mem_offset = frame.stack.pop_unsafe();
    const code_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    log.debug("EXTCODECOPY: address={x}, mem_offset={}, code_offset={}, size={}", .{ address_u256, mem_offset, code_offset, size });

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or code_offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        log.debug("EXTCODECOPY OutOfOffset: mem_offset={}, code_offset={}, size={}, maxInt={}", .{ mem_offset, code_offset, size, std.math.maxInt(usize) });
        return ExecutionError.Error.OutOfOffset;
    }

    const address = from_u256(address_u256);
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const code_offset_usize = @as(usize, @intCast(code_offset));
    const size_usize = @as(usize, @intCast(size));

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    if (size == 0) {
        @branchHint(.unlikely);
        return;
    }

    // Charge gas and ensure memory is available
    const new_size = mem_offset_usize + size_usize;
    try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(new_size)));

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
pub fn op_extcodehash(frame: *Frame) ExecutionError.Error!void {
    const address_u256 = frame.stack.pop_unsafe();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code from state database and compute hash
    const exists = frame.state.account_exists(address);
    if (!exists) {
        // Non-existent account per EIP-1052 returns 0
        frame.stack.append_unsafe(0);
        return;
    }

    const code = try frame.state.get_code_by_address(address);
    if (code.len == 0) {
        // Existing account with empty code returns keccak256("") constant
        const empty_hash_u256: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        frame.stack.append_unsafe(empty_hash_u256);
        return;
    }

    // Compute keccak256 hash of the code
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

    // Convert hash to u256 using std.mem for efficiency
    const hash_u256 = std.mem.readInt(u256, &hash, .big);
    frame.stack.append_unsafe(hash_u256);
}

/// SELFBALANCE opcode (0x47) - Get balance of current account
///
/// Pushes the balance of the currently executing contract (EIP-1884).
/// More efficient than using BALANCE with ADDRESS.
/// Stack: [] → [balance]
pub fn op_selfbalance(frame: *Frame) ExecutionError.Error!void {
    // Get balance of current executing contract
    const self_address = frame.contract_address;
    const balance = try frame.state.get_balance(self_address);
    frame.stack.append_unsafe(balance);
}

/// CHAINID opcode (0x46) - Get chain ID
///
/// Pushes the chain ID of the current blockchain (EIP-1344).
/// Stack: [] → [chain_id]
pub fn op_chainid(frame: *Frame) ExecutionError.Error!void {
    // TODO: Need chain_id field in ExecutionContext
    // Push chain ID from transaction context
    // try frame.stack.append(frame.chain_id);

    // Placeholder implementation - push mainnet chain ID
    frame.stack.append_unsafe(1);
}

/// CALLDATASIZE opcode (0x36) - Get size of input data
///
/// Pushes the size of the calldata in bytes.
/// Stack: [] → [size]
pub fn op_calldatasize(frame: *Frame) ExecutionError.Error!void {
    frame.stack.append_unsafe(@as(u256, @intCast(frame.host.get_input().len)));
}

/// CODESIZE opcode (0x38) - Get size of code
///
/// Pushes the size of the currently executing contract's code in bytes.
/// Stack: [] → [size]
pub fn op_codesize(frame: *Frame) ExecutionError.Error!void {
    // Push size of current contract's code
    const code_len = frame.analysis.bytecode.len;
    frame.stack.append_unsafe(@as(u256, @intCast(code_len)));
}

/// CALLDATALOAD opcode (0x35) - Load input data
///
/// Loads 32 bytes from calldata at the given offset. Zero-pads if reading
/// past the end of calldata.
/// Stack: [offset] → [data]
pub fn op_calldataload(frame: *Frame) ExecutionError.Error!void {
    const offset = frame.stack.pop_unsafe();
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        frame.stack.append_unsafe(0);
        return;
    }
    const offset_usize: usize = @intCast(offset);
    const calldata = frame.host.get_input();
    if (offset_usize >= calldata.len) {
        frame.stack.append_unsafe(0);
        return;
    }
    var buf: [32]u8 = [_]u8{0} ** 32;
    const available = @min(@as(usize, 32), calldata.len - offset_usize);
    // Copy contiguous bytes starting at offset into the start of the buffer
    @memcpy(buf[0..available], calldata[offset_usize .. offset_usize + available]);
    const word = std.mem.readInt(u256, &buf, .big);

    // Debug: log selector extraction for small calldata to diagnose dispatcher issues
    if (offset_usize == 0 and calldata.len >= 4) {
        const selector: u256 = (word >> 224) & 0xffffffff;
        @import("../log.zig").debug("[CALLDATALOAD] offset={}, len={}, selector=0x{x:0>8}, full_word=0x{x:0>64}", .{ offset_usize, calldata.len, selector, word });
    }
    frame.stack.append_unsafe(word);
}

/// CALLDATACOPY opcode (0x37) - Copy input data to memory
///
/// Copies data from calldata to memory. Zero-pads if reading past the end.
/// Stack: [mem_offset, data_offset, size] → []
pub fn op_calldatacopy(frame: *Frame) ExecutionError.Error!void {
    // Stack (top -> bottom): mem_offset, data_offset, size
    // EVM pops top-first
    const mem_offset = frame.stack.pop_unsafe();
    const data_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    if (size == 0) {
        @branchHint(.unlikely);
        return;
    }

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize)) return ExecutionError.Error.OutOfOffset;

    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const data_offset_usize = @as(usize, @intCast(data_offset));
    const size_usize = @as(usize, @intCast(size));

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation (VERYLOW * word_count)
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Copy from calldata to memory with zero-fill as needed
    try frame.memory.set_data_bounded(mem_offset_usize, frame.host.get_input(), data_offset_usize, size_usize);
}

/// CODECOPY opcode (0x39) - Copy code to memory
///
/// Copies the currently executing contract's code to memory.
/// Stack: [mem_offset, code_offset, size] → []
pub fn op_codecopy(frame: *Frame) ExecutionError.Error!void {
    // Stack (top -> bottom): mem_offset, code_offset, size
    // EVM pops top-first
    const mem_offset = frame.stack.pop_unsafe();
    const code_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

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

    // Charge gas and ensure memory is available
    const new_size = mem_offset_usize + size_usize;
    try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(new_size)));

    // Dynamic gas for copy operation (VERYLOW * word_count)
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Copy from current contract bytecode (from analysis or frame)
    const code = frame.analysis.bytecode;
    const Log = @import("../log.zig");
    Log.debug("CODECOPY: mem_offset={}, code_offset={}, size={}, code.len={}", .{ mem_offset_usize, code_offset_usize, size_usize, code.len });
    if (code.len > 0 and size_usize > 0) {
        const copy_size = @min(size_usize, if (code_offset_usize < code.len) code.len - code_offset_usize else 0);
        if (copy_size > 0) {
            Log.debug("CODECOPY: First few bytes of code: {x}", .{std.fmt.fmtSliceHexLower(code[0..@min(8, code.len)])});
        }
    }
    try frame.memory.set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize);
}
/// RETURNDATASIZE opcode (0x3D) - Get size of return data
///
/// Pushes the size of the return data from the previous call.
/// Stack: [] → [size]
pub fn op_returndatasize(frame: *Frame) ExecutionError.Error!void {
    // TODO: Need return_data field in ExecutionContext
    // Push size of return data from last call
    // const size = frame.return_data.len;
    // frame.stack.append_unsafe(@as(u256, @intCast(size)));
    
    // Placeholder implementation - push zero for now
    frame.stack.append_unsafe(0);
}

/// RETURNDATACOPY opcode (0x3E) - Copy return data to memory
///
/// Copies data from the return data buffer to memory.
/// Stack: [mem_offset, data_offset, size] → []
pub fn op_returndatacopy(frame: *Frame) ExecutionError.Error!void {
    // Stack (top -> bottom): mem_offset, data_offset, size
    const mem_offset = frame.stack.pop_unsafe();
    const data_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();
    
    if (size == 0) {
        @branchHint(.unlikely);
        return;
    }
    
    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const data_offset_usize = @as(usize, @intCast(data_offset));
    const size_usize = @as(usize, @intCast(size));
    
    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);
    
    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);
    
    // TODO: Need return_data field in ExecutionContext
    // For now, just zero-fill the memory
    const zero_data = &[_]u8{};
    try frame.memory.set_data_bounded(mem_offset_usize, zero_data, data_offset_usize, size_usize);
}

/// RETURNDATALOAD opcode (0xF7) - Load return data
///
/// Loads 32 bytes from the return data buffer at the given offset (EOF opcode).
/// Reverts if offset + 32 exceeds return data size.
/// Stack: [offset] → [data]
pub fn op_returndataload(frame: *Frame) ExecutionError.Error!void {
    // TODO: Need return_data field in ExecutionContext
    // Pop offset from stack
    const offset = frame.stack.pop_unsafe();

    // Check if offset is within bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    // TODO: Implement returndataload with ExecutionContext
    // const offset_usize = @as(usize, @intCast(offset));
    // const return_data = frame.return_data;
    // ... load logic ...

    frame.stack.append_unsafe(0);
}
