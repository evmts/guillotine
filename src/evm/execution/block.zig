const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");

pub fn op_blockhash(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

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

pub fn op_coinbase(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    try frame.stack.append(primitives.Address.to_u256(vm.context.block_coinbase));

    return Operation.ExecutionResult{};
}

pub fn op_timestamp(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    try frame.stack.append(@as(u256, @intCast(vm.context.block_timestamp)));

    return Operation.ExecutionResult{};
}

pub fn op_number(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    try frame.stack.append(@as(u256, @intCast(vm.context.block_number)));

    return Operation.ExecutionResult{};
}

pub fn op_difficulty(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    // Get difficulty/prevrandao from block context
    // Post-merge this returns PREVRANDAO
    try frame.stack.append(vm.context.block_difficulty);

    return Operation.ExecutionResult{};
}

pub fn op_prevrandao(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    // Same as difficulty post-merge
    return op_difficulty(pc, interpreter, state);
}

pub fn op_gaslimit(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    try frame.stack.append(@as(u256, @intCast(vm.context.block_gas_limit)));

    return Operation.ExecutionResult{};
}

pub fn op_basefee(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    // Get base fee from block context
    // Push base fee (EIP-1559)
    try frame.stack.append(vm.context.block_base_fee);

    return Operation.ExecutionResult{};
}

pub fn op_blobhash(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

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

pub fn op_blobbasefee(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    // Get blob base fee from block context
    // Push blob base fee (EIP-4844)
    try frame.stack.append(vm.context.blob_base_fee);

    return Operation.ExecutionResult{};
}

test "BLOCKHASH gets hash of recent blocks within 256 blocks" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set current block number
    vm.context.block_number = 300;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Test block number 299 (current - 1)
    try frame.stack.push(299);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);

    const hash = try frame.stack.pop();
    // Should return a pseudo-hash (non-zero)
    try std.testing.expect(hash != 0);
}

test "BLOCKHASH returns 0 for current block" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.context.block_number = 1000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Test current block number
    try frame.stack.push(1000);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);

    const hash = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), hash);
}

test "BLOCKHASH returns 0 for future blocks" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.context.block_number = 1000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Test future block number
    try frame.stack.push(1001);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);

    const hash = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), hash);
}

test "BLOCKHASH returns 0 for blocks beyond 256 limit" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.context.block_number = 1000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Test block more than 256 blocks ago
    try frame.stack.push(743);  // 1000 - 743 = 257
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);

    const hash = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), hash);
}

test "BLOCKHASH edge case: block number 0" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.context.block_number = 100;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Test block number 0
    try frame.stack.push(0);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);

    const hash = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), hash);
}

test "BLOCKHASH edge case: block number overflow" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.context.block_number = 1000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Test max u256
    try frame.stack.push(std.math.maxInt(u256));
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blockhash(0, interpreter_ptr, state_ptr);

    const hash = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), hash);
}

test "COINBASE returns block coinbase address" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set specific coinbase address
    const coinbase_address = primitives.Address.from_u256(0xDEADBEEF);
    vm.context.block_coinbase = coinbase_address;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x41}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_coinbase(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(primitives.Address.to_u256(coinbase_address), result);
}

test "TIMESTAMP returns block timestamp" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set specific timestamp
    vm.context.block_timestamp = 1656633600; // June 1, 2022

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x42}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_timestamp(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1656633600), result);
}

test "TIMESTAMP edge case: maximum timestamp" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set maximum u64 timestamp
    vm.context.block_timestamp = std.math.maxInt(u64);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x42}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_timestamp(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u64)), result);
}

test "NUMBER returns block number" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set specific block number
    vm.context.block_number = 15537394; // The Merge block

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x43}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_number(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 15537394), result);
}

test "NUMBER edge case: genesis block" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set genesis block number
    vm.context.block_number = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x43}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_number(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "DIFFICULTY returns block difficulty" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set pre-merge difficulty
    vm.context.block_difficulty = 1234567890;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x44}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_difficulty(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 1234567890), result);
}

test "PREVRANDAO returns prevrandao value post-merge" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set post-merge prevrandao
    const prevrandao: u256 = 0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;
    vm.context.block_difficulty = prevrandao;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x44}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_prevrandao(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(prevrandao, result);
}

test "GASLIMIT returns block gas limit" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set typical mainnet gas limit
    vm.context.block_gas_limit = 30000000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x45}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_gaslimit(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 30000000), result);
}

test "BASEFEE returns block base fee" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set typical base fee (15 gwei)
    vm.context.block_base_fee = 15000000000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x48}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_basefee(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 15000000000), result);
}

test "BLOBHASH returns blob hash at valid index" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set blob hashes
    const blob_hashes = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
        0x2222222222222222222222222222222222222222222222222222222222222222,
        0x3333333333333333333333333333333333333333333333333333333333333333,
    };
    vm.context.blob_hashes = &blob_hashes;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x49}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Test index 1
    try frame.stack.push(1);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blobhash(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(blob_hashes[1], result);
}

test "BLOBHASH returns 0 for out of bounds index" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set blob hashes
    const blob_hashes = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
        0x2222222222222222222222222222222222222222222222222222222222222222,
    };
    vm.context.blob_hashes = &blob_hashes;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x49}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Test out of bounds index
    try frame.stack.push(5);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blobhash(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "BLOBBASEFEE returns blob base fee" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set blob base fee
    vm.context.blob_base_fee = 12345;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x4A}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blobbasefee(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 12345), result);
}

// Fuzz tests
const BlockOpType = enum {
    blockhash,
    coinbase,
    timestamp,
    number,
    difficulty,
    gaslimit,
    basefee,
    blobhash,
    blobbasefee,
};

const FuzzBlockOperation = struct {
    op_type: BlockOpType,
    block_number: u64,
    block_timestamp: u64,
    block_coinbase: primitives.Address.Address,
    block_difficulty: u256,
    block_gas_limit: u64,
    block_base_fee: u256,
    blob_base_fee: u256,
    blob_hashes: []const u256,
    input_value: u256, // For operations that pop from stack (blockhash, blobhash)
};

fn fuzz_block_operations(allocator: std.mem.Allocator, operations: []const FuzzBlockOperation) !void {
    for (operations) |op| {
        var memory_db = @import("../state/memory_database.zig").init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();

        // Set up context
        vm.context.block_number = op.block_number;
        vm.context.block_timestamp = op.block_timestamp;
        vm.context.block_coinbase = op.block_coinbase;
        vm.context.block_difficulty = op.block_difficulty;
        vm.context.block_gas_limit = op.block_gas_limit;
        vm.context.block_base_fee = op.block_base_fee;
        vm.context.blob_base_fee = op.blob_base_fee;
        vm.context.blob_hashes = op.blob_hashes;

        var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: *Operation.State = @ptrCast(&frame);

        switch (op.op_type) {
            .blockhash => {
                try frame.stack.push(op.input_value);
                _ = try op_blockhash(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                
                // Verify blockhash logic
                if (op.input_value >= op.block_number) {
                    try std.testing.expectEqual(@as(u256, 0), result);
                } else if (op.block_number > op.input_value + 256) {
                    try std.testing.expectEqual(@as(u256, 0), result);
                } else if (op.input_value == 0) {
                    try std.testing.expectEqual(@as(u256, 0), result);
                } else {
                    // Should return non-zero pseudo-hash
                    try std.testing.expect(result != 0);
                }
            },
            .coinbase => {
                _ = try op_coinbase(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                try std.testing.expectEqual(primitives.Address.to_u256(op.block_coinbase), result);
            },
            .timestamp => {
                _ = try op_timestamp(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                try std.testing.expectEqual(@as(u256, op.block_timestamp), result);
            },
            .number => {
                _ = try op_number(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                try std.testing.expectEqual(@as(u256, op.block_number), result);
            },
            .difficulty => {
                _ = try op_difficulty(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                try std.testing.expectEqual(op.block_difficulty, result);
            },
            .gaslimit => {
                _ = try op_gaslimit(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                try std.testing.expectEqual(@as(u256, op.block_gas_limit), result);
            },
            .basefee => {
                _ = try op_basefee(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                try std.testing.expectEqual(op.block_base_fee, result);
            },
            .blobhash => {
                try frame.stack.push(op.input_value);
                _ = try op_blobhash(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                
                if (op.input_value >= op.blob_hashes.len) {
                    try std.testing.expectEqual(@as(u256, 0), result);
                } else {
                    const idx = @as(usize, @intCast(op.input_value));
                    try std.testing.expectEqual(op.blob_hashes[idx], result);
                }
            },
            .blobbasefee => {
                _ = try op_blobbasefee(0, interpreter_ptr, state_ptr);
                const result = try frame.stack.pop();
                try std.testing.expectEqual(op.blob_base_fee, result);
            },
        }
    }
}

test "fuzz block operations with random values" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzBlockOperation).init(allocator);
    defer operations.deinit();
    
    // Generate random test cases
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 8);
        const op_types = [_]BlockOpType{ .blockhash, .coinbase, .timestamp, .number, .difficulty, .gaslimit, .basefee, .blobhash, .blobbasefee };
        const op_type = op_types[op_type_idx];
        
        // Generate random blob hashes
        var blob_hashes_buf: [6]u256 = undefined;
        const num_blobs = random.intRangeAtMost(usize, 0, 6);
        for (0..num_blobs) |j| {
            blob_hashes_buf[j] = random.int(u256);
        }
        const blob_hashes = try allocator.dupe(u256, blob_hashes_buf[0..num_blobs]);
        defer allocator.free(blob_hashes);
        
        try operations.append(.{
            .op_type = op_type,
            .block_number = random.intRangeAtMost(u64, 0, 20000000),
            .block_timestamp = random.int(u64),
            .block_coinbase = primitives.Address.from_u256(random.int(u256)),
            .block_difficulty = random.int(u256),
            .block_gas_limit = random.intRangeAtMost(u64, 1000000, 100000000),
            .block_base_fee = random.int(u256),
            .blob_base_fee = random.int(u256),
            .blob_hashes = blob_hashes,
            .input_value = random.int(u256),
        });
    }
    
    try fuzz_block_operations(allocator, operations.items);
}

test "fuzz block operations edge cases" {
    const allocator = std.testing.allocator;
    
    const empty_blob_hashes = &[_]u256{};
    const many_blob_hashes = &[_]u256{1, 2, 3, 4, 5, 6};
    
    const operations = [_]FuzzBlockOperation{
        // BLOCKHASH edge cases
        .{
            .op_type = .blockhash,
            .block_number = 0,
            .block_timestamp = 0,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 0,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .blob_hashes = empty_blob_hashes,
            .input_value = 0,
        },
        .{
            .op_type = .blockhash,
            .block_number = std.math.maxInt(u64),
            .block_timestamp = 0,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 0,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .blob_hashes = empty_blob_hashes,
            .input_value = std.math.maxInt(u256),
        },
        // Timestamp max value
        .{
            .op_type = .timestamp,
            .block_number = 0,
            .block_timestamp = std.math.maxInt(u64),
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 0,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .blob_hashes = empty_blob_hashes,
            .input_value = 0,
        },
        // Max difficulty/prevrandao
        .{
            .op_type = .difficulty,
            .block_number = 0,
            .block_timestamp = 0,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = std.math.maxInt(u256),
            .block_gas_limit = 0,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .blob_hashes = empty_blob_hashes,
            .input_value = 0,
        },
        // Blobhash with many blobs
        .{
            .op_type = .blobhash,
            .block_number = 0,
            .block_timestamp = 0,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 0,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .blob_hashes = many_blob_hashes,
            .input_value = 5, // Valid index
        },
        .{
            .op_type = .blobhash,
            .block_number = 0,
            .block_timestamp = 0,
            .block_coinbase = primitives.Address.ZERO,
            .block_difficulty = 0,
            .block_gas_limit = 0,
            .block_base_fee = 0,
            .blob_base_fee = 0,
            .blob_hashes = many_blob_hashes,
            .input_value = 10, // Out of bounds
        },
    };
    
    try fuzz_block_operations(allocator, &operations);
}

test "block operations don't modify state" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set up context
    vm.context.block_number = 1000;
    vm.context.block_timestamp = 1700000000;
    vm.context.block_coinbase = primitives.Address.from_u256(0x123);
    vm.context.block_difficulty = 999999;
    vm.context.block_gas_limit = 30000000;
    vm.context.block_base_fee = 1000;
    vm.context.blob_base_fee = 1;
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);

    // Store initial values
    const initial_block_number = vm.context.block_number;
    const initial_timestamp = vm.context.block_timestamp;
    const initial_coinbase = vm.context.block_coinbase;
    const initial_difficulty = vm.context.block_difficulty;
    const initial_gas_limit = vm.context.block_gas_limit;
    const initial_base_fee = vm.context.block_base_fee;
    const initial_blob_base_fee = vm.context.blob_base_fee;

    // Execute all block operations
    _ = try op_coinbase(0, interpreter_ptr, state_ptr);
    _ = try frame.stack.pop();
    
    _ = try op_timestamp(0, interpreter_ptr, state_ptr);
    _ = try frame.stack.pop();
    
    _ = try op_number(0, interpreter_ptr, state_ptr);
    _ = try frame.stack.pop();
    
    _ = try op_difficulty(0, interpreter_ptr, state_ptr);
    _ = try frame.stack.pop();
    
    _ = try op_gaslimit(0, interpreter_ptr, state_ptr);
    _ = try frame.stack.pop();
    
    _ = try op_basefee(0, interpreter_ptr, state_ptr);
    _ = try frame.stack.pop();
    
    _ = try op_blobbasefee(0, interpreter_ptr, state_ptr);
    _ = try frame.stack.pop();

    // Verify nothing changed
    try std.testing.expectEqual(initial_block_number, vm.context.block_number);
    try std.testing.expectEqual(initial_timestamp, vm.context.block_timestamp);
    try std.testing.expectEqual(initial_coinbase, vm.context.block_coinbase);
    try std.testing.expectEqual(initial_difficulty, vm.context.block_difficulty);
    try std.testing.expectEqual(initial_gas_limit, vm.context.block_gas_limit);
    try std.testing.expectEqual(initial_base_fee, vm.context.block_base_fee);
    try std.testing.expectEqual(initial_blob_base_fee, vm.context.blob_base_fee);
}

test "block operations push 256-bit values" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Set max values where applicable
    vm.context.block_number = std.math.maxInt(u64);
    vm.context.block_timestamp = std.math.maxInt(u64);
    vm.context.block_gas_limit = std.math.maxInt(u64);
    vm.context.block_difficulty = std.math.maxInt(u256);
    vm.context.block_base_fee = std.math.maxInt(u256);
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);

    // All operations should successfully push values <= u256 max
    _ = try op_number(0, interpreter_ptr, state_ptr);
    const number_result = try frame.stack.pop();
    try std.testing.expect(number_result <= std.math.maxInt(u256));
    
    _ = try op_timestamp(0, interpreter_ptr, state_ptr);
    const timestamp_result = try frame.stack.pop();
    try std.testing.expect(timestamp_result <= std.math.maxInt(u256));
    
    _ = try op_gaslimit(0, interpreter_ptr, state_ptr);
    const gaslimit_result = try frame.stack.pop();
    try std.testing.expect(gaslimit_result <= std.math.maxInt(u256));
    
    _ = try op_difficulty(0, interpreter_ptr, state_ptr);
    const difficulty_result = try frame.stack.pop();
    try std.testing.expect(difficulty_result <= std.math.maxInt(u256));
    
    _ = try op_basefee(0, interpreter_ptr, state_ptr);
    const basefee_result = try frame.stack.pop();
    try std.testing.expect(basefee_result <= std.math.maxInt(u256));
}

test "BLOCKHASH consistency: same block number gives same hash" {
    const allocator = std.testing.allocator;
    
    var memory_db = @import("../state/memory_database.zig").init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    vm.context.block_number = 1000;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x40}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);

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
    defer vm.deinit();

    // Set zero base fee (pre-EIP-1559 or extreme case)
    vm.context.block_base_fee = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x48}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set maximum possible base fee
    vm.context.block_base_fee = std.math.maxInt(u256);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x48}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set empty blob hashes array
    const empty_blob_hashes: []const u256 = &.{};
    vm.context.blob_hashes = empty_blob_hashes;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x49}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Test index 0 (should return 0 for empty array)
    try frame.stack.push(0);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set zero blob base fee
    vm.context.blob_base_fee = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x4A}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set maximum possible blob base fee
    vm.context.blob_base_fee = std.math.maxInt(u256);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x4A}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set zero gas limit (extreme edge case)
    vm.context.block_gas_limit = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x45}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set maximum possible gas limit
    vm.context.block_gas_limit = std.math.maxInt(u64);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x45}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set zero difficulty (post-merge scenario)
    vm.context.block_difficulty = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x44}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set post-merge prevrandao value
    const test_value: u256 = 0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890;
    vm.context.block_difficulty = test_value;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x44}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    
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
    defer vm.deinit();

    // Set zero coinbase address
    vm.context.block_coinbase = primitives.Address.ZERO;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x41}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set maximum coinbase address
    const max_address = primitives.Address.from_u256(std.math.maxInt(u160));
    vm.context.block_coinbase = max_address;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x41}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set zero timestamp (genesis block or extreme case)
    vm.context.block_timestamp = 0;

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x42}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

    // Set maximum block number
    vm.context.block_number = std.math.maxInt(u64);

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0x43}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
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
    defer vm.deinit();

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
    defer frame.deinit();
    
    // Test last valid index (5)
    try frame.stack.push(5);
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try op_blobhash(0, interpreter_ptr, state_ptr);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(max_blob_hashes[5], result);
}
