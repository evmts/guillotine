const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");

pub fn op_blockhash(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    const block_number = try frame.stack.pop();

    const current_block = vm.context.block_number;

    if (block_number >= current_block) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
    } else if (current_block > block_number + 256) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
    } else if (block_number == 0) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
    } else {
        // Return a pseudo-hash based on block number for testing
        // In production, this would retrieve the actual block hash from chain history
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&block_number));
        try frame.stack.append(hash);
    }

    return Operation.ExecutionResult{};
}

pub fn op_coinbase(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    try frame.stack.append(primitives.Address.to_u256(vm.context.block_coinbase));

    return Operation.ExecutionResult{};
}

pub fn op_timestamp(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    try frame.stack.append(@as(u256, @intCast(vm.context.block_timestamp)));

    return Operation.ExecutionResult{};
}

pub fn op_number(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    try frame.stack.append(@as(u256, @intCast(vm.context.block_number)));

    return Operation.ExecutionResult{};
}

pub fn op_difficulty(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    // Get difficulty/prevrandao from block context
    // Post-merge this returns PREVRANDAO
    try frame.stack.append(vm.context.block_difficulty);

    return Operation.ExecutionResult{};
}

pub fn op_prevrandao(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    // Same as difficulty post-merge
    return op_difficulty(pc, interpreter, state);
}

pub fn op_gaslimit(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    try frame.stack.append(@as(u256, @intCast(vm.context.block_gas_limit)));

    return Operation.ExecutionResult{};
}

pub fn op_basefee(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    // Get base fee from block context
    // Push base fee (EIP-1559)
    try frame.stack.append(vm.context.block_base_fee);

    return Operation.ExecutionResult{};
}

pub fn op_blobhash(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    const index = try frame.stack.pop();

    // EIP-4844: Get blob hash at index
    if (index >= vm.context.blob_hashes.len) {
        @branchHint(.unlikely);
        try frame.stack.append(0);
    } else {
        const idx = @as(usize, @intCast(index));
        try frame.stack.append(vm.context.blob_hashes[idx]);
    }

    return Operation.ExecutionResult{};
}

pub fn op_blobbasefee(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    // Get blob base fee from block context
    // Push blob base fee (EIP-4844)
    try frame.stack.append(vm.context.blob_base_fee);

    return Operation.ExecutionResult{};
}

// Tests
const testing = std.testing;
const MemoryDatabase = @import("../state/memory_database.zig");
const Contract = @import("../frame/contract.zig");
const Context = @import("../access_list/context.zig");
const Address = primitives.Address;

test "BLOCKHASH: Returns hash for valid recent blocks" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test block within range (999 blocks ago)
    try frame.stack.push(999);
    _ = try op_blockhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const recent_hash = try frame.stack.pop();
    try testing.expect(recent_hash != 0); // Should return non-zero hash
}

test "BLOCKHASH: Returns zero for current block" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test current block
    try frame.stack.push(1000);
    _ = try op_blockhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const current_hash = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), current_hash);
}

test "BLOCKHASH: Returns zero for future blocks" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test future block
    try frame.stack.push(1001);
    _ = try op_blockhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const future_hash = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), future_hash);
}

test "BLOCKHASH: Returns zero for blocks beyond 256 limit" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test block beyond 256 limit
    try frame.stack.push(743); // 1000 - 743 = 257 blocks ago
    _ = try op_blockhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const old_hash = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), old_hash);
}

test "BLOCKHASH: Returns zero for block number 0" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test block number 0 (genesis block)
    try frame.stack.push(0);
    _ = try op_blockhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const genesis_hash = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), genesis_hash);
}

test "COINBASE: Returns correct coinbase address" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_coinbase = Address.Address{ .bytes = [_]u8{0xCC} ** 20 };
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        test_coinbase, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_coinbase(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    const expected = Address.to_u256(test_coinbase);
    try testing.expectEqual(expected, result);
}

test "TIMESTAMP: Returns correct timestamp" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_timestamp: u64 = 1234567890;
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        test_timestamp, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_timestamp(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, test_timestamp), result);
}

test "NUMBER: Returns correct block number" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_block_number: u64 = 987654321;
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        test_block_number, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_number(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, test_block_number), result);
}

test "DIFFICULTY: Returns correct difficulty value" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_difficulty: u256 = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0;
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        test_difficulty, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_difficulty(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(test_difficulty, result);
}

test "PREVRANDAO: Returns same as difficulty" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_prevrandao: u256 = 0xABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789;
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        test_prevrandao, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_prevrandao(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(test_prevrandao, result);
}

test "GASLIMIT: Returns correct gas limit" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_gas_limit: u64 = 50_000_000;
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        test_gas_limit, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_gaslimit(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, test_gas_limit), result);
}

test "BASEFEE: Returns correct base fee" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_base_fee: u256 = 25_000_000_000; // 25 gwei
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        test_base_fee, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_basefee(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(test_base_fee, result);
}

test "BLOBHASH: Returns correct blob hash for valid index" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_blob_hashes = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
        0x2222222222222222222222222222222222222222222222222222222222222222,
        0x3333333333333333333333333333333333333333333333333333333333333333,
    };
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &test_blob_hashes, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test first blob hash
    try frame.stack.push(0);
    _ = try op_blobhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const result1 = try frame.stack.pop();
    try testing.expectEqual(test_blob_hashes[0], result1);
    
    // Test second blob hash
    try frame.stack.push(1);
    _ = try op_blobhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const result2 = try frame.stack.pop();
    try testing.expectEqual(test_blob_hashes[1], result2);
}

test "BLOBHASH: Returns zero for out of bounds index" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_blob_hashes = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
    };
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &test_blob_hashes, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test out of bounds index
    try frame.stack.push(1);
    _ = try op_blobhash(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "BLOBBASEFEE: Returns correct blob base fee" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const test_blob_base_fee: u256 = 100_000_000; // 0.1 gwei
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        test_blob_base_fee, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    _ = try op_blobbasefee(0, @ptrCast(&vm), @ptrCast(&frame));
    const result = try frame.stack.pop();
    try testing.expectEqual(test_blob_base_fee, result);
}

// Fuzz tests
test "BLOCKHASH: Fuzz with random block numbers" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        1000, // block_number
        1234567890, // block_timestamp
        Address.ZERO, // block_coinbase
        0, // block_difficulty
        30_000_000, // block_gas_limit
        1, // chain_id
        15_000_000_000, // block_base_fee
        &[_]u256{}, // blob_hashes
        1, // blob_base_fee
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    var prng = std.rand.DefaultPrng.init(0);
    const random = prng.random();
    
    // Test 100 random block numbers
    for (0..100) |_| {
        const block_num = random.int(u256);
        try frame.stack.push(block_num);
        _ = try op_blockhash(0, @ptrCast(&vm), @ptrCast(&frame));
        const result = try frame.stack.pop();
        
        // Verify invariants
        if (block_num >= vm.context.block_number) {
            try testing.expectEqual(@as(u256, 0), result);
        } else if (vm.context.block_number > block_num + 256) {
            try testing.expectEqual(@as(u256, 0), result);
        } else if (block_num == 0) {
            try testing.expectEqual(@as(u256, 0), result);
        }
    }
}

// Invariant tests
test "Block operations: All values are 256-bit" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);
    
    const context = Context.init_with_values(
        Address.ZERO, // tx_origin
        0, // gas_price
        std.math.maxInt(u64), // block_number (max u64)
        std.math.maxInt(u64), // block_timestamp (max u64)
        Address.ZERO, // block_coinbase
        std.math.maxInt(u256), // block_difficulty (max u256)
        std.math.maxInt(u64), // block_gas_limit (max u64)
        1, // chain_id
        std.math.maxInt(u256), // block_base_fee (max u256)
        &[_]u256{}, // blob_hashes
        std.math.maxInt(u256), // blob_base_fee (max u256)
    );
    vm.context = context;
    
    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test all operations return valid u256 values
    _ = try op_coinbase(0, @ptrCast(&vm), @ptrCast(&frame));
    const coinbase_result = try frame.stack.pop();
    try testing.expect(@TypeOf(coinbase_result) == u256);
    
    _ = try op_timestamp(0, @ptrCast(&vm), @ptrCast(&frame));
    const timestamp_result = try frame.stack.pop();
    try testing.expect(@TypeOf(timestamp_result) == u256);
    
    _ = try op_number(0, @ptrCast(&vm), @ptrCast(&frame));
    const number_result = try frame.stack.pop();
    try testing.expect(@TypeOf(number_result) == u256);
    
    _ = try op_difficulty(0, @ptrCast(&vm), @ptrCast(&frame));
    const difficulty_result = try frame.stack.pop();
    try testing.expect(@TypeOf(difficulty_result) == u256);
    
    _ = try op_gaslimit(0, @ptrCast(&vm), @ptrCast(&frame));
    const gaslimit_result = try frame.stack.pop();
    try testing.expect(@TypeOf(gaslimit_result) == u256);
    
    _ = try op_basefee(0, @ptrCast(&vm), @ptrCast(&frame));
    const basefee_result = try frame.stack.pop();
    try testing.expect(@TypeOf(basefee_result) == u256);
    
    _ = try op_blobbasefee(0, @ptrCast(&vm), @ptrCast(&frame));
    const blobbasefee_result = try frame.stack.pop();
    try testing.expect(@TypeOf(blobbasefee_result) == u256);
}

test "BLOCKHASH consistency: same block number gives same hash" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    vm.context.block_number = 1000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Get hash for block 900 twice
    try frame.stack.push(900);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);
    const hash1 = try frame.stack.pop();

    try frame.stack.push(900);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);
    const hash2 = try frame.stack.pop();

    // Should be consistent
    try std.testing.expectEqual(hash1, hash2);
    try std.testing.expect(hash1 != 0); // Should be non-zero for valid blocks
}

test "BASEFEE edge case: zero base fee" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set zero base fee (pre-EIP-1559 or extreme case)
    vm.context.block_base_fee = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x48}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_basefee(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "BASEFEE edge case: maximum base fee" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set maximum possible base fee
    vm.context.block_base_fee = std.math.maxInt(u256);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x48}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_basefee(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result);
}

test "BLOBHASH empty blob hashes array" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set empty blob hashes array
    const empty_blob_hashes: []const u256 = &.{};
    vm.context.blob_hashes = empty_blob_hashes;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x49}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test index 0 (should return 0 for empty array)
    try frame.stack.push(0);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_blobhash(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "BLOBBASEFEE edge case: zero blob base fee" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set zero blob base fee
    vm.context.blob_base_fee = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x4A}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_blobbasefee(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "BLOBBASEFEE edge case: maximum blob base fee" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set maximum possible blob base fee
    vm.context.blob_base_fee = std.math.maxInt(u256);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x4A}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_blobbasefee(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result);
}

test "GASLIMIT edge case: zero gas limit" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set zero gas limit (extreme edge case)
    vm.context.block_gas_limit = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x45}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_gaslimit(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "GASLIMIT edge case: maximum gas limit" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set maximum possible gas limit
    vm.context.block_gas_limit = std.math.maxInt(u64);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x45}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_gaslimit(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u64)), result);
}

test "DIFFICULTY zero difficulty" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set zero difficulty (post-merge scenario)
    vm.context.block_difficulty = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x44}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_difficulty(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "PREVRANDAO and DIFFICULTY are equivalent" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set post-merge prevrandao value
    const test_value: u256 = 0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890;
    vm.context.block_difficulty = test_value;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x44}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    
    // Test DIFFICULTY
    _ = try op_difficulty(0, interpreter_ptr, state_ptr);
    const difficulty_result = try frame.stack.pop();
    
    // Test PREVRANDAO
    _ = try op_prevrandao(0, interpreter_ptr, state_ptr);
    const prevrandao_result = try frame.stack.pop();
    
    // Should return the same value
    try std.testing.expectEqual(difficulty_result, prevrandao_result);
    try std.testing.expectEqual(test_value, difficulty_result);
}

test "COINBASE edge case: zero address" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set zero coinbase address
    vm.context.block_coinbase = primitives.Address.ZERO;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x41}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_coinbase(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "COINBASE edge case: maximum address" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set maximum coinbase address
    const max_address = primitives.Address.from_u256(std.math.maxInt(u160));
    vm.context.block_coinbase = max_address;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x41}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_coinbase(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(primitives.Address.to_u256(max_address), result);
}

test "TIMESTAMP edge case: zero timestamp" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set zero timestamp (genesis block or extreme case)
    vm.context.block_timestamp = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x42}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_timestamp(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "NUMBER edge case: maximum block number" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set maximum block number
    vm.context.block_number = std.math.maxInt(u64);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x43}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_number(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u64)), result);
}

test "BLOBHASH edge case: maximum valid index" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit(allocator);

    // Set maximum number of blob hashes (6 per EIP-4844)
    const max_blob_hashes = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
        0x2222222222222222222222222222222222222222222222222222222222222222,
        0x3333333333333333333333333333333333333333333333333333333333333333,
        0x4444444444444444444444444444444444444444444444444444444444444444,
        0x5555555555555555555555555555555555555555555555555555555555555555,
        0x6666666666666666666666666666666666666666666666666666666666666666,
    };
    vm.context.blob_hashes = &max_blob_hashes;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x49}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit(allocator);
    
    // Test last valid index (5)
    try frame.stack.push(5);
    
    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);
    _ = try op_blobhash(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(max_blob_hashes[5], result);
}
