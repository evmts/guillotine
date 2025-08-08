const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const primitives = @import("primitives");

pub fn op_blockhash(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    const block_number = try context.stack.pop();

    const current_block = context.block_number;

    if (block_number >= current_block) {
        @branchHint(.unlikely);
        try context.stack.append(0);
    } else if (current_block > block_number + 256) {
        @branchHint(.unlikely);
        try context.stack.append(0);
    } else if (block_number == 0) {
        @branchHint(.unlikely);
        try context.stack.append(0);
    } else {
        // TODO: In production, this would retrieve the actual block hash from chain history
        // For now, return a pseudo-hash based on block number for testing
        const hash = std.hash.Wyhash.hash(0, std.mem.asBytes(&block_number));
        try context.stack.append(hash);
    }
}

pub fn op_coinbase(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    
    // EIP-3651 (Shanghai) COINBASE warming should be handled during pre-execution setup,
    // not at runtime. The coinbase address should be pre-warmed in the access list
    // before execution begins if EIP-3651 is enabled.
    
    try context.stack.append(primitives.Address.to_u256(context.block_coinbase));
}

pub fn op_timestamp(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    try context.stack.append(@as(u256, @intCast(context.block_timestamp)));
}

pub fn op_number(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    try context.stack.append(@as(u256, @intCast(context.block_number)));
}

pub fn op_difficulty(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    // Post-merge this returns PREVRANDAO, pre-merge it returns difficulty
    // The host is responsible for providing the correct value based on hardfork
    try context.stack.append(context.block_difficulty);
}

pub fn op_prevrandao(context_ptr: *anyopaque) ExecutionError.Error!void {
    // Same as difficulty post-merge
    return op_difficulty(context_ptr);
}

pub fn op_gaslimit(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    try context.stack.append(@as(u256, @intCast(context.block_gas_limit)));
}

pub fn op_basefee(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    
    // EIP-3198 validation should be handled during bytecode analysis phase,
    // not at runtime. Invalid BASEFEE opcodes should be rejected during code analysis.
    
    // NOTE: BASEFEE opcode (EIP-3198) returns the base fee from the block header.
    // This is separate from EIP-1559 fee market logic, which is handled at the 
    // transaction/client layer, not in the EVM interpreter itself.
    // The EVM only needs to expose the base fee value via this opcode.
    
    try context.stack.append(context.block_base_fee);
}

pub fn op_blobhash(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    const index = try context.stack.pop();

    // TODO: Need blob_hashes field in ExecutionContext
    // EIP-4844: Get blob hash at index
    // if (index >= context.blob_hashes.len) {
    //     @branchHint(.unlikely);
    //     try context.stack.append(0);
    // } else {
    //     const idx = @as(usize, @intCast(index));
    //     try context.stack.append(context.blob_hashes[idx]);
    // }
    
    // Placeholder implementation - always return zero
    _ = index;
    try context.stack.append(0);
}

pub fn op_blobbasefee(context_ptr: *anyopaque) ExecutionError.Error!void {
    const context: *ExecutionContext = @ptrCast(@alignCast(context_ptr));
    // Push blob base fee (EIP-4844, Cancun+)
    // If not available (pre-Cancun), should be handled by jump table gating
    const blob_base_fee = context.block_blob_base_fee orelse 0;
    try context.stack.append(blob_base_fee);
}

// Tests
const testing = std.testing;
const Address = primitives.Address;
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;

test "COINBASE returns block coinbase address" {
    // Create a minimal test context with only required fields
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    const test_coinbase = Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_coinbase: Address.Address,
    }{
        .stack = &stack,
        .block_coinbase = test_coinbase,
    };
    
    // Execute COINBASE opcode
    try op_coinbase(&context);
    
    // Verify coinbase address was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(Address.to_u256(test_coinbase), result);
}

test "TIMESTAMP returns block timestamp" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    const test_timestamp: u64 = 1234567890;
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_timestamp: u64,
    }{
        .stack = &stack,
        .block_timestamp = test_timestamp,
    };
    
    // Execute TIMESTAMP opcode
    try op_timestamp(&context);
    
    // Verify timestamp was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(@as(primitives.u256, test_timestamp), result);
}

test "NUMBER returns block number" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    const test_block_number: u64 = 15537393;
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_number: u64,
    }{
        .stack = &stack,
        .block_number = test_block_number,
    };
    
    // Execute NUMBER opcode
    try op_number(&context);
    
    // Verify block number was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(@as(primitives.u256, test_block_number), result);
}

test "DIFFICULTY returns block difficulty/prevrandao" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    const test_difficulty: primitives.u256 = 0x123456789ABCDEF;
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_difficulty: primitives.u256,
    }{
        .stack = &stack,
        .block_difficulty = test_difficulty,
    };
    
    // Execute DIFFICULTY opcode
    try op_difficulty(&context);
    
    // Verify difficulty was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(test_difficulty, result);
}

test "GASLIMIT returns block gas limit" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    const test_gas_limit: u64 = 30_000_000;
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_gas_limit: u64,
    }{
        .stack = &stack,
        .block_gas_limit = test_gas_limit,
    };
    
    // Execute GASLIMIT opcode
    try op_gaslimit(&context);
    
    // Verify gas limit was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(@as(primitives.u256, test_gas_limit), result);
}

test "BASEFEE returns block base fee" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    const test_base_fee: primitives.u256 = 1_000_000_000; // 1 gwei
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_base_fee: primitives.u256,
    }{
        .stack = &stack,
        .block_base_fee = test_base_fee,
    };
    
    // Execute BASEFEE opcode
    try op_basefee(&context);
    
    // Verify base fee was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(test_base_fee, result);
}

test "BLOBBASEFEE returns blob base fee when available" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    const test_blob_base_fee: primitives.u256 = 100_000_000; // 0.1 gwei
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_blob_base_fee: ?u256,
    }{
        .stack = &stack,
        .block_blob_base_fee = test_blob_base_fee,
    };
    
    // Execute BLOBBASEFEE opcode
    try op_blobbasefee(&context);
    
    // Verify blob base fee was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(test_blob_base_fee, result);
}

test "BLOBBASEFEE returns 0 when not available (pre-Cancun)" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_blob_base_fee: ?u256,
    }{
        .stack = &stack,
        .block_blob_base_fee = null, // Pre-Cancun, no blob base fee
    };
    
    // Execute BLOBBASEFEE opcode
    try op_blobbasefee(&context);
    
    // Verify 0 was pushed to stack
    const result = try stack.pop();
    try testing.expectEqual(@as(primitives.u256, 0), result);
}

test "BLOCKHASH returns 0 for future blocks" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_number: u64,
    }{
        .stack = &stack,
        .block_number = 1000,
    };
    
    // Push future block number
    try stack.append(1001);
    
    // Execute BLOCKHASH opcode
    try op_blockhash(&context);
    
    // Verify 0 was pushed for future block
    const result = try stack.pop();
    try testing.expectEqual(@as(primitives.u256, 0), result);
}

test "BLOCKHASH returns 0 for blocks too far in past" {
    var stack = @import("../stack/stack.zig").init();
    defer stack.deinit();
    
    var context = struct {
        stack: *@TypeOf(stack),
        block_number: u64,
    }{
        .stack = &stack,
        .block_number = 1000,
    };
    
    // Push block number more than 256 blocks in past
    try stack.append(700);
    
    // Execute BLOCKHASH opcode
    try op_blockhash(&context);
    
    // Verify 0 was pushed for old block
    const result = try stack.pop();
    try testing.expectEqual(@as(primitives.u256, 0), result);
}

// TODO: Convert all tests to ExecutionContext after VM refactor complete
// All block opcode tests have been temporarily disabled due to Frame/Contract refactor
