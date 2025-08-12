const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;
const log = std.log.scoped(.default);

pub fn op_address(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // Push contract address as u256
    const addr = to_u256(frame.contract_address);
    try frame.stack.append(addr);
}

pub fn op_balance(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.peek();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get balance from state database
    const balance = try frame.state.get_balance(address);
    try frame.stack.set_top(balance);
}

pub fn op_origin(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need tx_origin field in ExecutionContext
    // Push transaction origin address
    // const origin = to_u256(frame.tx_origin);
    // try frame.stack.append(origin);

    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

pub fn op_caller(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const caller = to_u256(frame.caller);
    try frame.stack.append(caller);
}

pub fn op_callvalue(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    try frame.stack.append(frame.value);
}

pub fn op_gasprice(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need gas_price field in ExecutionContext
    // Push gas price from transaction context
    // try frame.stack.append(frame.gas_price);

    // Placeholder implementation - push zero for now
    try frame.stack.append(0);
}

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

pub fn op_extcodecopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // EVM stack order (top -> bottom): address, destOffset, offset, length
    // So we pop in reverse: length, offset, destOffset, address
    const address_u256 = try frame.stack.pop();
    const mem_offset = try frame.stack.pop();
    const code_offset = try frame.stack.pop();
    const size = try frame.stack.pop();

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

pub fn op_extcodehash(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const address_u256 = try frame.stack.pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try frame.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code from state database and compute hash
    const exists = frame.state.account_exists(address);
    if (!exists) {
        // Non-existent account per EIP-1052 returns 0
        try frame.stack.append(0);
        return;
    }

    const code = try frame.state.get_code_by_address(address);
    if (code.len == 0) {
        // Existing account with empty code returns keccak256("") constant
        const empty_hash_u256: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        try frame.stack.append(empty_hash_u256);
        return;
    }

    // Compute keccak256 hash of the code
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

    // Convert hash to u256 using std.mem for efficiency
    const hash_u256 = std.mem.readInt(u256, &hash, .big);
    try frame.stack.append(hash_u256);
}

pub fn op_selfbalance(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // Get balance of current executing contract
    const self_address = frame.contract_address;
    const balance = try frame.state.get_balance(self_address);
    try frame.stack.append(balance);
}

pub fn op_chainid(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Need chain_id field in ExecutionContext
    // Push chain ID from transaction context
    // try frame.stack.append(frame.chain_id);

    // Placeholder implementation - push mainnet chain ID
    try frame.stack.append(1);
}

pub fn op_calldatasize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    try frame.stack.append(@as(u256, @intCast(frame.input.len)));
}

pub fn op_codesize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // Push size of current contract's code
    try frame.stack.append(@as(u256, @intCast(frame.analysis.code_len)));
}

pub fn op_calldataload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const offset = try frame.stack.pop();
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
        return;
    }
    const offset_usize: usize = @intCast(offset);
    const calldata = frame.input;
    if (offset_usize >= calldata.len) {
        try frame.stack.append(0);
        return;
    }
    var buf: [32]u8 = [_]u8{0} ** 32;
    const available = @min(@as(usize, 32), calldata.len - offset_usize);
    // Copy contiguous bytes starting at offset into the start of the buffer
    @memcpy(buf[0..available], calldata[offset_usize .. offset_usize + available]);
    const word = std.mem.readInt(u256, &buf, .big);
    try frame.stack.append(word);
}

pub fn op_calldatacopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // Stack (top -> bottom): mem_offset, data_offset, size
    // EVM pops top-first
    const mem_offset = try frame.stack.pop();
    const data_offset = try frame.stack.pop();
    const size = try frame.stack.pop();

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
    try frame.memory.set_data_bounded(mem_offset_usize, frame.input, data_offset_usize, size_usize);
}

pub fn op_codecopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // Stack (top -> bottom): mem_offset, code_offset, size
    // EVM pops top-first
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
/// RETURNDATALOAD opcode (0xF7): Loads a 32-byte word from return data
/// This is an EOF opcode that allows reading from the return data buffer
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
