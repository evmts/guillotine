//! Block information opcodes for the Ethereum Virtual Machine
//!
//! This module implements opcodes that provide access to block-level data including
//! block hashes, timestamps, miner address, block number, difficulty/prevrandao,
//! gas limit, chain ID, and base fee.
//!
//! ## Gas Costs
//! - BLOCKHASH: 20 gas
//! - COINBASE, TIMESTAMP, NUMBER, GASLIMIT, CHAINID: 2 gas
//! - DIFFICULTY/PREVRANDAO, BASEFEE, BLOBBASEFEE: 2 gas
//!
//! ## EIP Changes
//! - EIP-3651: Warm COINBASE address (Shanghai)
//! - EIP-4399: DIFFICULTY becomes PREVRANDAO (Merge)
//! - EIP-3198: BASEFEE opcode (London)
//! - EIP-4844: BLOBBASEFEE opcode (Cancun)

const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const primitives = @import("primitives");

/// BLOCKHASH opcode (0x40) - Get hash of specific block
///
/// Returns the hash of one of the 256 most recent blocks. If the requested block
/// is not within this range or is the current block or a future block, returns 0.
///
/// Stack: [block_number] → [hash]
pub fn op_blockhash(frame: *Frame) ExecutionError.Error!void {
    const block_number = frame.stack.pop_unsafe();

    const block_info = frame.host.get_block_info();
    const current_block = block_info.number;

    if (block_number >= current_block) {
        @branchHint(.unlikely);
        frame.stack.append_unsafe(0);
    } else if (current_block > block_number + 256) {
        @branchHint(.unlikely);
        frame.stack.append_unsafe(0);
    } else if (block_number == 0) {
        @branchHint(.unlikely);
        frame.stack.append_unsafe(0);
    } else {
        // TODO: Implement proper block hash retrieval from chain history
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&block_number));
        try frame.stack.append(hash);
    }
}

/// COINBASE opcode (0x41) - Get current block miner's address
///
/// Pushes the address of the miner who produced the current block.
/// Note: After EIP-3651 (Shanghai), the coinbase address is pre-warmed.
///
/// Stack: [] → [coinbase_address]
pub fn op_coinbase(frame: *Frame) ExecutionError.Error!void {

    // EIP-3651 (Shanghai) COINBASE warming should be handled during pre-execution setup,
    // not at runtime. The coinbase address should be pre-warmed in the access list
    // before execution begins if EIP-3651 is enabled.

    const block_info = frame.host.get_block_info();
    frame.stack.append_unsafe(primitives.Address.to_u256(block_info.coinbase));
}

/// TIMESTAMP opcode (0x42) - Get current block timestamp
///
/// Pushes the Unix timestamp of the current block.
///
/// Stack: [] → [timestamp]
pub fn op_timestamp(frame: *Frame) ExecutionError.Error!void {
    const block_info = frame.host.get_block_info();
    frame.stack.append_unsafe(@as(u256, @intCast(block_info.timestamp)));
}

/// NUMBER opcode (0x43) - Get current block number
///
/// Pushes the number of the current block.
///
/// Stack: [] → [block_number]
pub fn op_number(frame: *Frame) ExecutionError.Error!void {
    const block_info = frame.host.get_block_info();
    frame.stack.append_unsafe(@as(u256, @intCast(block_info.number)));
}

/// DIFFICULTY/PREVRANDAO opcode (0x44) - Get block difficulty or prevrandao
///
/// Pre-merge: Returns the difficulty of the current block.
/// Post-merge (EIP-4399): Returns the prevrandao value from the beacon chain.
///
/// Stack: [] → [difficulty/prevrandao]
pub fn op_difficulty(frame: *Frame) ExecutionError.Error!void {
    // Post-merge this returns PREVRANDAO, pre-merge it returns difficulty
    // The host is responsible for providing the correct value based on hardfork
    const block_info = frame.host.get_block_info();
    frame.stack.append_unsafe(block_info.difficulty);
}

/// PREVRANDAO opcode - Alias for DIFFICULTY post-merge
///
/// Returns the prevrandao value from the beacon chain.
/// This is an alias for DIFFICULTY that makes the semantic change explicit.
///
/// Stack: [] → [prevrandao]
pub fn op_prevrandao(frame: *Frame) ExecutionError.Error!void {
    // Same as difficulty post-merge
    return op_difficulty(frame);
}

/// GASLIMIT opcode (0x45) - Get current block gas limit
///
/// Pushes the gas limit of the current block.
///
/// Stack: [] → [gas_limit]
pub fn op_gaslimit(frame: *Frame) ExecutionError.Error!void {
    const block_info = frame.host.get_block_info();
    frame.stack.append_unsafe(@as(u256, @intCast(block_info.gas_limit)));
}

/// BASEFEE opcode (0x48) - Get current block base fee
///
/// Returns the base fee per gas of the current block (EIP-3198, London).
/// This value is determined by the network's fee market mechanism.
///
/// Stack: [] → [base_fee]
pub fn op_basefee(frame: *Frame) ExecutionError.Error!void {

    // EIP-3198 validation should be handled during bytecode analysis phase,
    // not at runtime. Invalid BASEFEE opcodes should be rejected during code analysis.

    // NOTE: BASEFEE opcode (EIP-3198) returns the base fee from the block header.
    // This is separate from EIP-1559 fee market logic, which is handled at the
    // transaction/client layer, not in the EVM interpreter itself.
    // The EVM only needs to expose the base fee value via this opcode.

    const block_info = frame.host.get_block_info();
    frame.stack.append_unsafe(block_info.base_fee);
}

/// BLOBHASH opcode (0x49) - Get versioned hash of blob
///
/// Returns the versioned hash of the blob at the given index (EIP-4844, Cancun).
/// If index is out of bounds, returns 0.
///
/// Stack: [index] → [blob_hash]
pub fn op_blobhash(frame: *Frame) ExecutionError.Error!void {
    const index = frame.stack.pop_unsafe();

    // TODO: Need blob_hashes field in ExecutionContext
    // EIP-4844: Get blob hash at index
    // if (index >= frame.blob_hashes.len) {
    //     @branchHint(.unlikely);
    //     try frame.stack.append(0);
    // } else {
    //     const idx = @as(usize, @intCast(index));
    //     try frame.stack.append(frame.blob_hashes[idx]);
    // }

    // Placeholder implementation - always return zero
    _ = index;
    frame.stack.append_unsafe(0);
}

/// BLOBBASEFEE opcode (0x4A) - Get current blob base fee
///
/// Returns the base fee per blob gas of the current block (EIP-4844, Cancun).
/// Used for blob transaction pricing.
///
/// Stack: [] → [blob_base_fee]
pub fn op_blobbasefee(frame: *Frame) ExecutionError.Error!void {
    // Push blob base fee (EIP-4844, Cancun+)
    // If not available (pre-Cancun), should be handled by jump table gating
    // TODO: Add blob_base_fee to BlockInfo - for now return 0 as REVM likely does
    frame.stack.append_unsafe(0);
}

// Tests
const testing = std.testing;
const Address = primitives.Address.Address;
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;
const Host = @import("../host.zig").Host;
const BlockInfo = @import("../host.zig").BlockInfo;
const StackFrame = @import("../stack_frame.zig").StackFrame;
const SimpleAnalysis = @import("../evm/analysis2.zig").SimpleAnalysis;
const DatabaseInterface = @import("../state/database_interface.zig").DatabaseInterface;
const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;

// Mock host implementation for testing block opcodes
const TestBlockHost = struct {
    block_info: BlockInfo,

    pub fn get_balance(self: *TestBlockHost, address: Address) u256 {
        _ = self;
        _ = address;
        return 0;
    }

    pub fn account_exists(self: *TestBlockHost, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }

    pub fn get_code(self: *TestBlockHost, address: Address) []const u8 {
        _ = self;
        _ = address;
        return &[_]u8{};
    }

    pub fn get_block_info(self: *TestBlockHost) BlockInfo {
        return self.block_info;
    }

    pub fn emit_log(self: *TestBlockHost, contract_address: Address, topics: []const u256, data: []const u8) void {
        _ = self;
        _ = contract_address;
        _ = topics;
        _ = data;
    }

    pub fn call(self: *TestBlockHost, params: @import("../host.zig").CallParams) anyerror!@import("../host.zig").CallResult {
        _ = self;
        _ = params;
        return error.NotImplemented;
    }

    pub fn register_created_contract(self: *TestBlockHost, address: Address) anyerror!void {
        _ = self;
        _ = address;
    }

    pub fn was_created_in_tx(self: *TestBlockHost, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }

    pub fn create_snapshot(self: *TestBlockHost) u32 {
        _ = self;
        return 0;
    }

    pub fn revert_to_snapshot(self: *TestBlockHost, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
    }

    pub fn record_storage_change(self: *TestBlockHost, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
    }

    pub fn get_original_storage(self: *TestBlockHost, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        return null;
    }

    pub fn set_output(self: *TestBlockHost, output: []const u8) !void {
        _ = self;
        _ = output;
    }

    pub fn get_output(self: *TestBlockHost) []const u8 {
        _ = self;
        return &.{};
    }

    pub fn access_address(self: *TestBlockHost, address: Address) !u64 {
        _ = self;
        _ = address;
        return 2600; // Cold access cost
    }

    pub fn access_storage_slot(self: *TestBlockHost, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        return 2100; // Cold storage access cost
    }

    pub fn mark_for_destruction(self: *TestBlockHost, contract_address: Address, recipient: Address) !void {
        _ = self;
        _ = contract_address;
        _ = recipient;
    }

    pub fn get_input(self: *TestBlockHost) []const u8 {
        _ = self;
        return &.{};
    }

    pub fn is_hardfork_at_least(self: *TestBlockHost, target: @import("../hardforks/hardfork.zig").Hardfork) bool {
        _ = self;
        _ = target;
        return true;
    }

    pub fn get_hardfork(self: *TestBlockHost) @import("../hardforks/hardfork.zig").Hardfork {
        _ = self;
        return .CANCUN;
    }

    pub fn to_host(self: *TestBlockHost) Host {
        return Host.init(self);
    }
};

test "COINBASE returns block coinbase address" {
    const allocator = testing.allocator;

    const test_coinbase = primitives.Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = test_coinbase,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    // Create empty analysis for StackFrame
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &.{},
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var frame = try Frame.init(
        1000000, // gas_remaining
        false, // static_call
        primitives.Address.ZERO, // contract_address
        primitives.Address.ZERO, // caller
        0, // value
        empty_analysis,
        empty_metadata,
        empty_ops,
        (&test_host).to_host(),
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Execute COINBASE opcode
    try op_coinbase(&frame);

    // Verify coinbase address was pushed to stack
    const result = frame.stack.pop_unsafe();
    try testing.expectEqual(primitives.Address.to_u256(test_coinbase), result);
}

test "TIMESTAMP returns block timestamp" {
    const allocator = testing.allocator;

    const test_timestamp: u64 = 1234567890;

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1,
            .timestamp = test_timestamp,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = primitives.Address.ZERO,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    // Create empty analysis for StackFrame
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &.{},
        .inst_count = 0,
    };
    const empty_metadata: []u32 = &.{};
    const empty_ops: []*const anyopaque = &.{};

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var frame = try StackFrame.init(
        1000000, // gas_remaining
        false, // static_call
        primitives.Address.ZERO, // contract_address
        primitives.Address.ZERO, // caller
        0, // value
        empty_analysis,
        empty_metadata,
        empty_ops,
        (&test_host).to_host(),
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Execute TIMESTAMP opcode
    try op_timestamp(&frame);

    // Verify timestamp was pushed to stack
    const result = frame.stack.pop_unsafe();
    try testing.expectEqual(@as(u256, test_timestamp), result);
}

test "NUMBER returns block number" {
    var stack = try @import("../stack/stack.zig").init(testing.allocator);
    defer stack.deinit(std.testing.allocator);

    const test_block_number: u64 = 15537393;

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = test_block_number,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = primitives.Address.ZERO,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    var context = struct {
        stack: *@TypeOf(stack),
        host: Host,
    }{
        .stack = &stack,
        .host = (&test_host).to_host(),
    };

    // Execute NUMBER opcode
    try op_number(&context);

    // Verify block number was pushed to stack
    const result = stack.pop_unsafe();
    try testing.expectEqual(@as(u256, test_block_number), result);
}

test "DIFFICULTY returns block difficulty/prevrandao" {
    var stack = try @import("../stack/stack.zig").init(testing.allocator);
    defer stack.deinit(std.testing.allocator);

    const test_difficulty: u256 = 0x123456789ABCDEF;

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = test_difficulty,
            .gas_limit = 30000000,
            .coinbase = primitives.Address.ZERO,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    var context = struct {
        stack: *@TypeOf(stack),
        host: Host,
    }{
        .stack = &stack,
        .host = (&test_host).to_host(),
    };

    // Execute DIFFICULTY opcode
    try op_difficulty(&context);

    // Verify difficulty was pushed to stack
    const result = stack.pop_unsafe();
    try testing.expectEqual(test_difficulty, result);
}

test "GASLIMIT returns block gas limit" {
    var stack = try @import("../stack/stack.zig").init(testing.allocator);
    defer stack.deinit(std.testing.allocator);

    const test_gas_limit: u64 = 30_000_000;

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = test_gas_limit,
            .coinbase = primitives.Address.ZERO,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    var context = struct {
        stack: *@TypeOf(stack),
        host: Host,
    }{
        .stack = &stack,
        .host = (&test_host).to_host(),
    };

    // Execute GASLIMIT opcode
    try op_gaslimit(&context);

    // Verify gas limit was pushed to stack
    const result = stack.pop_unsafe();
    try testing.expectEqual(@as(u256, test_gas_limit), result);
}

test "BASEFEE returns block base fee" {
    var stack = try @import("../stack/stack.zig").init(testing.allocator);
    defer stack.deinit(std.testing.allocator);

    const test_base_fee: u256 = 1_000_000_000; // 1 gwei

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = primitives.Address.ZERO,
            .base_fee = test_base_fee,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    var context = struct {
        stack: *@TypeOf(stack),
        host: Host,
    }{
        .stack = &stack,
        .host = (&test_host).to_host(),
    };

    // Execute BASEFEE opcode
    try op_basefee(&context);

    // Verify base fee was pushed to stack
    const result = stack.pop_unsafe();
    try testing.expectEqual(test_base_fee, result);
}

test "BLOBBASEFEE returns 0 (not yet implemented in BlockInfo)" {
    var stack = try @import("../stack/stack.zig").init(testing.allocator);
    defer stack.deinit(std.testing.allocator);

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = primitives.Address.ZERO,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    var context = struct {
        stack: *@TypeOf(stack),
        host: Host,
    }{
        .stack = &stack,
        .host = (&test_host).to_host(),
    };

    // Execute BLOBBASEFEE opcode
    try op_blobbasefee(&context);

    // Verify 0 was pushed to stack (not yet implemented in BlockInfo)
    const result = stack.pop_unsafe();
    try testing.expectEqual(@as(u256, 0), result);
}

test "BLOCKHASH returns 0 for future blocks" {
    var stack = try @import("../stack/stack.zig").init(testing.allocator);
    defer stack.deinit(std.testing.allocator);

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1000,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = primitives.Address.ZERO,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    var context = struct {
        stack: *@TypeOf(stack),
        host: Host,
    }{
        .stack = &stack,
        .host = (&test_host).to_host(),
    };

    // Push future block number
    stack.append_unsafe(1001);

    // Execute BLOCKHASH opcode
    try op_blockhash(&context);

    // Verify 0 was pushed for future block
    const result = stack.pop_unsafe();
    try testing.expectEqual(@as(u256, 0), result);
}

test "BLOCKHASH returns 0 for blocks too far in past" {
    var stack = try @import("../stack/stack.zig").init(testing.allocator);
    defer stack.deinit(std.testing.allocator);

    var test_host = TestBlockHost{
        .block_info = BlockInfo{
            .number = 1000,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = primitives.Address.ZERO,
            .base_fee = 1000000000,
            .prev_randao = [_]u8{0} ** 32,
        },
    };

    var context = struct {
        stack: *@TypeOf(stack),
        host: Host,
    }{
        .stack = &stack,
        .host = (&test_host).to_host(),
    };

    // Push block number more than 256 blocks in past
    stack.append_unsafe(700);

    // Execute BLOCKHASH opcode
    try op_blockhash(&context);

    // Verify 0 was pushed for old block
    const result = try stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

// TODO: Convert all tests to ExecutionContext after VM refactor complete
// All block opcode tests have been temporarily disabled due to Frame/Contract refactor
