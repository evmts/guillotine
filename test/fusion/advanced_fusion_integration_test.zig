const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm_mod = @import("evm");
const log = evm_mod.log;

// Test integration of advanced fusion patterns with actual EVM execution

test "integration: constant folding executes correctly" {
    const allocator = testing.allocator;
    
    // Bytecode that uses constant folding and returns the result
    // PUSH1 5, PUSH1 3, ADD (should fold to 8)
    // PUSH1 0, MSTORE (store 8 at memory[0])
    // PUSH1 32, PUSH1 0, RETURN (return memory[0:32])
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3  
        0x01,       // ADD (should be folded to PUSH 8)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Create a simple database
    const Database = evm_mod.Database;
    const BlockInfo = evm_mod.BlockInfo;
    const TransactionContext = evm_mod.TransactionContext;
    const DefaultEvm = evm_mod.DefaultEvm;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    // Set up block and transaction context
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .blob_base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create EVM instance
    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();
    
    // Deploy contract with our bytecode
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &bytecode,
            .gas = 100000,
        },
    };
    
    const result = evm.call(create_params);
    defer if (result.output.len > 0) allocator.free(result.output);
    
    // Verify the result is 8 (5 + 3)
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Check the returned value is 8
    var expected = [_]u8{0} ** 32;
    expected[31] = 8;
    try testing.expectEqualSlices(u8, &expected, result.output);
    
    log.info("Constant folding integration test passed: 5 + 3 = 8", .{});
}

test "integration: multi-PUSH executes correctly" {
    const allocator = testing.allocator;
    
    // Bytecode that uses multi-PUSH pattern
    // PUSH1 5, PUSH1 3 (should fuse to MULTI_PUSH_2)
    // ADD
    // PUSH1 0, MSTORE
    // PUSH1 32, PUSH1 0, RETURN
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3 (multi-push fusion)
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const Database = evm_mod.Database;
    const BlockInfo = evm_mod.BlockInfo;
    const TransactionContext = evm_mod.TransactionContext;
    const DefaultEvm = evm_mod.DefaultEvm;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .blob_base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();
    
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &bytecode,
            .gas = 100000,
        },
    };
    
    const result = evm.call(create_params);
    defer if (result.output.len > 0) allocator.free(result.output);
    
    // Verify the result is 8 (5 + 3)
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    var expected = [_]u8{0} ** 32;
    expected[31] = 8;
    try testing.expectEqualSlices(u8, &expected, result.output);
    
    log.info("Multi-PUSH integration test passed", .{});
}

test "integration: multi-POP executes correctly" {
    const allocator = testing.allocator;
    
    // Bytecode that uses multi-POP pattern
    // PUSH1 10, PUSH1 20, PUSH1 30, PUSH1 5
    // POP, POP (should fuse to MULTI_POP_2)
    // ADD (20 + 10 = 30)
    // PUSH1 0, MSTORE
    // PUSH1 32, PUSH1 0, RETURN
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x14, // PUSH1 20
        0x60, 0x1E, // PUSH1 30
        0x60, 0x05, // PUSH1 5
        0x50,       // POP
        0x50,       // POP (multi-pop fusion)
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const Database = evm_mod.Database;
    const BlockInfo = evm_mod.BlockInfo;
    const TransactionContext = evm_mod.TransactionContext;
    const DefaultEvm = evm_mod.DefaultEvm;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .blob_base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();
    
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &bytecode,
            .gas = 100000,
        },
    };
    
    const result = evm.call(create_params);
    defer if (result.output.len > 0) allocator.free(result.output);
    
    // After popping 5 and 30, we have 20 and 10, so 20 + 10 = 30
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    var expected = [_]u8{0} ** 32;
    expected[31] = 30;
    try testing.expectEqualSlices(u8, &expected, result.output);
    
    log.info("Multi-POP integration test passed", .{});
}

test "integration: ISZERO-JUMPI fusion executes correctly" {
    const allocator = testing.allocator;
    
    // Bytecode that uses ISZERO-JUMPI pattern
    // PUSH1 0 (push zero)
    // ISZERO, PUSH1 target, JUMPI (should fuse)
    // PUSH1 1 (not executed)
    // PUSH1 0, MSTORE
    // PUSH1 32, PUSH1 0, RETURN
    // target: JUMPDEST
    // PUSH1 42 (executed)
    // PUSH1 0, MSTORE
    // PUSH1 32, PUSH1 0, RETURN
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x15,       // ISZERO
        0x60, 0x0E, // PUSH1 14 (jump target)
        0x57,       // JUMPI (should be fused with ISZERO)
        0x60, 0x01, // PUSH1 1 (not executed)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
        0x5B,       // JUMPDEST (offset 14)
        0x60, 0x2A, // PUSH1 42 (executed)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const Database = evm_mod.Database;
    const BlockInfo = evm_mod.BlockInfo;
    const TransactionContext = evm_mod.TransactionContext;
    const DefaultEvm = evm_mod.DefaultEvm;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .blob_base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();
    
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &bytecode,
            .gas = 100000,
        },
    };
    
    const result = evm.call(create_params);
    defer if (result.output.len > 0) allocator.free(result.output);
    
    // Should jump and return 42
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    var expected = [_]u8{0} ** 32;
    expected[31] = 42;
    try testing.expectEqualSlices(u8, &expected, result.output);
    
    log.info("ISZERO-JUMPI fusion integration test passed", .{});
}

test "integration: complex pattern with SHL executes correctly" {
    const allocator = testing.allocator;
    
    // Bytecode for: 4 - (2 << 3) = 4 - 16 = -12 (wrapping)
    // PUSH1 4, PUSH1 2, PUSH1 3, SHL, SUB (should fold)
    // The result should wrap to a large positive number
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x1B,       // SHL
        0x03,       // SUB (entire sequence should be constant folded)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    const Database = evm_mod.Database;
    const BlockInfo = evm_mod.BlockInfo;
    const TransactionContext = evm_mod.TransactionContext;
    const DefaultEvm = evm_mod.DefaultEvm;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .blob_base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS, .CANCUN);
    defer evm.deinit();
    
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &bytecode,
            .gas = 100000,
        },
    };
    
    const result = evm.call(create_params);
    defer if (result.output.len > 0) allocator.free(result.output);
    
    // 4 - 16 with wrapping = large positive number (2^256 - 12)
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // The expected value is 2^256 - 12 in little-endian format
    var expected = [_]u8{0xFF} ** 32;
    expected[31] = 0xF4; // -12 in two's complement = 0xFFFFFFF...FF4
    try testing.expectEqualSlices(u8, &expected, result.output);
    
    log.info("Complex SHL pattern integration test passed", .{});
}