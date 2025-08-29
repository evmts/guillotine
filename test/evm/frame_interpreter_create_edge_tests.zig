const std = @import("std");
const frame_interpreter = @import("frame_interpreter.zig");
const evm = @import("evm.zig");
const database_interface = @import("database_interface.zig");
const memory_database = @import("memory_database.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const block_info = @import("block_info.zig");
const transaction_context = @import("transaction_context.zig");

// ============================================================================
// Edge Case Tests for CREATE Opcode
// ============================================================================

test "CREATE edge case - maximum init code size (48KB)" {
    const allocator = std.testing.allocator;
    
    // Create database
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 10_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    // Create 48KB of init code (maximum allowed)
    const max_init_size = 49152; // 48KB
    var init_code = try allocator.alloc(u8, max_init_size);
    defer allocator.free(init_code);
    
    // Fill with valid opcodes (PUSH1 0x00)
    for (init_code, 0..) |*byte, i| {
        byte.* = if (i % 2 == 0) 0x60 else 0x00;
    }
    // End with RETURN to deploy empty contract
    init_code[max_init_size - 3] = 0x60; // PUSH1
    init_code[max_init_size - 2] = 0x00; // 0
    init_code[max_init_size - 1] = 0xF3; // RETURN
    
    // Bytecode: Store init code in memory, then CREATE
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // PUSH32 <size>
    try bytecode.append(0x7F);
    const size_bytes = std.mem.toBytes(@as(u256, max_init_size));
    try bytecode.appendSlice(&size_bytes);
    
    // PUSH1 0 (offset)
    try bytecode.append(0x60);
    try bytecode.append(0x00);
    
    // PUSH1 0 (value)
    try bytecode.append(0x60);
    try bytecode.append(0x00);
    
    // CREATE
    try bytecode.append(0xF0);
    
    // STOP
    try bytecode.append(0x00);
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 15_000_000, db_interface, null);
    defer interpreter.deinit(allocator);
    
    // Pre-store the init code in memory
    try interpreter.frame.memory.ensure_capacity(max_init_size);
    try interpreter.frame.memory.set_data(0, init_code);
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute - should succeed at exactly 48KB
    try interpreter.interpret();
    
    // Verify contract was created
    const created_address = interpreter.frame.stack.peek_unsafe();
    try std.testing.expect(created_address != 0);
}

test "CREATE edge case - init code size exceeds 48KB" {
    const allocator = std.testing.allocator;
    
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 10_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    // Bytecode: PUSH32 49153 (1 byte over limit), PUSH1 0, PUSH1 0, CREATE
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // PUSH32 49153 (size - 1 byte over 48KB limit)
    try bytecode.append(0x7F);
    const size_bytes = std.mem.toBytes(@as(u256, 49153));
    try bytecode.appendSlice(&size_bytes);
    
    // PUSH1 0 (offset)
    try bytecode.append(0x60);
    try bytecode.append(0x00);
    
    // PUSH1 0 (value)
    try bytecode.append(0x60);
    try bytecode.append(0x00);
    
    // CREATE
    try bytecode.append(0xF0);
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 10_000_000, db_interface, null);
    defer interpreter.deinit(allocator);
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute - should fail due to BytecodeTooLarge error
    const result = interpreter.interpret();
    try std.testing.expectError(frame_interpreter.FrameInterpreter(.{ .has_database = true }).Error.BytecodeTooLarge, result);
}

test "CREATE edge case - insufficient gas for init code" {
    const allocator = std.testing.allocator;
    
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Bytecode: PUSH2 1000 (size), PUSH1 0, PUSH1 0, CREATE
    const bytecode = [_]u8{
        0x61, 0x03, 0xE8, // PUSH2 1000
        0x60, 0x00,       // PUSH1 0
        0x60, 0x00,       // PUSH1 0
        0xF0,             // CREATE
        0x00,             // STOP
    };
    
    // Calculate required gas:
    // - Base CREATE cost: 32000
    // - Init code cost: 1000 * 200 = 200000
    // - Total: 232000
    // Give less than required
    const insufficient_gas = 100000;
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, insufficient_gas, db_interface, null);
    defer interpreter.deinit(allocator);
    
    // Use real EVM instance for proper gas handling
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = insufficient_gas,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute - should fail with OutOfGas
    const result = interpreter.interpret();
    try std.testing.expectError(frame_interpreter.FrameInterpreter(.{ .has_database = true }).Error.OutOfGas, result);
}

test "CREATE edge case - memory expansion overflow" {
    const allocator = std.testing.allocator;
    
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Bytecode: PUSH32 <small_size>, PUSH32 <huge_offset>, PUSH1 0, CREATE
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // PUSH32 100 (size)
    try bytecode.append(0x7F);
    const size_bytes = std.mem.toBytes(@as(u256, 100));
    try bytecode.appendSlice(&size_bytes);
    
    // PUSH32 MAX_U256 - 50 (offset that would overflow)
    try bytecode.append(0x7F);
    const offset_bytes = std.mem.toBytes(std.math.maxInt(u256) - 50);
    try bytecode.appendSlice(&offset_bytes);
    
    // PUSH1 0 (value)
    try bytecode.append(0x60);
    try bytecode.append(0x00);
    
    // CREATE
    try bytecode.append(0xF0);
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 10_000_000, db_interface, null);
    defer interpreter.deinit(allocator);
    
    // Use real EVM instance for proper overflow handling
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 10_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute - should fail with OutOfBounds due to overflow
    const result = interpreter.interpret();
    try std.testing.expectError(frame_interpreter.FrameInterpreter(.{ .has_database = true }).Error.OutOfBounds, result);
}

test "CREATE edge case - all gas consumed by subcall" {
    const allocator = std.testing.allocator;
    
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Simple init code that consumes all gas
    const init_code = [_]u8{
        0x5B, // JUMPDEST
        0x60, 0x00, // PUSH1 0
        0x56, // JUMP (infinite loop)
    };
    
    // Bytecode to CREATE with this init code
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Store init code at memory[0]
    for (init_code) |byte| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(byte);
    }
    
    // MSTORE8 operations to store init code
    var offset: u8 = init_code.len - 1;
    while (offset > 0) : (offset -= 1) {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(offset);
        try bytecode.append(0x53); // MSTORE8
    }
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00);
    try bytecode.append(0x53); // MSTORE8
    
    // CREATE with the init code
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(@intCast(init_code.len)); // size
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00); // offset
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00); // value
    try bytecode.append(0xF0); // CREATE
    try bytecode.append(0x00); // STOP
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 1_000_000, db_interface, null);
    defer interpreter.deinit(allocator);
    
    // Use real EVM instance for realistic behavior
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 1_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute - CREATE should return 0 (failure) but not error
    try interpreter.interpret();
    
    // Stack should have 0 (failed creation)
    const result = interpreter.frame.stack.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "CREATE edge case - nested CREATE depth limit" {
    const allocator = std.testing.allocator;
    
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Init code that creates another contract (nested CREATE)
    const nested_init_code = [_]u8{
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xF0,       // CREATE (nested)
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    };
    
    // Store init code and CREATE
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Store nested init code in memory
    for (nested_init_code) |byte| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(byte);
    }
    
    var offset: u8 = nested_init_code.len - 1;
    while (offset > 0) : (offset -= 1) {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(offset);
        try bytecode.append(0x53); // MSTORE8
    }
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00);
    try bytecode.append(0x53); // MSTORE8
    
    // CREATE
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(@intCast(nested_init_code.len));
    try bytecode.append(0x60); // PUSH1 0
    try bytecode.append(0x00);
    try bytecode.append(0x60); // PUSH1 0
    try bytecode.append(0x00);
    try bytecode.append(0xF0); // CREATE
    try bytecode.append(0x00); // STOP
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 10_000_000, db_interface, null);
    defer interpreter.deinit(allocator);
    
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 10_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute - nested CREATE should work up to depth limit
    try interpreter.interpret();
    
    // Verify a contract was created
    const result = interpreter.frame.stack.peek_unsafe();
    try std.testing.expect(result != 0);
}

// ============================================================================
// Real-world Scenario Tests
// ============================================================================

test "CREATE real scenario - deploy ERC20 token contract" {
    const allocator = std.testing.allocator;
    
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Simplified ERC20 constructor bytecode
    // This would normally set initial supply, name, symbol, etc.
    const erc20_init_code = [_]u8{
        // Constructor logic (simplified)
        0x60, 0x80, // PUSH1 0x80 (free memory pointer)
        0x60, 0x40, // PUSH1 0x40
        0x52,       // MSTORE
        
        // Store total supply (1000000 * 10^18)
        0x69, 0x03, 0x63, 0x5C, 0x9A, 0xDC, 0x5D, 0xEA, 0x00, 0x00, // PUSH10 (1M tokens)
        0x60, 0x00, // PUSH1 0 (storage slot)
        0x55,       // SSTORE
        
        // Return runtime code (simplified - just return empty for test)
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xF3,       // RETURN
    };
    
    // Deploy the ERC20 contract
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Store init code in memory
    for (erc20_init_code) |byte| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(byte);
    }
    
    var offset: u8 = erc20_init_code.len - 1;
    while (offset > 0) : (offset -= 1) {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(offset);
        try bytecode.append(0x53); // MSTORE8
    }
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00);
    try bytecode.append(0x53); // MSTORE8
    
    // CREATE with no value
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(@intCast(erc20_init_code.len));
    try bytecode.append(0x60); // PUSH1 0
    try bytecode.append(0x00);
    try bytecode.append(0x60); // PUSH1 0
    try bytecode.append(0x00);
    try bytecode.append(0xF0); // CREATE
    
    // Store the created address
    try bytecode.append(0x60); // PUSH1 0
    try bytecode.append(0x00);
    try bytecode.append(0x55); // SSTORE (store at slot 0)
    try bytecode.append(0x00); // STOP
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 10_000_000, db_interface, null);
    defer interpreter.deinit(allocator);
    
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 15_000_000, // Recent block
            .timestamp = 1_700_000_000,
            .difficulty = 0, // Post-merge
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 25_000_000_000, // 25 gwei
            .prev_randao = [_]u8{0xAB} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 5,
            .gas_price = 30_000_000_000, // 30 gwei
            .gas_limit = 10_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        30_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute deployment
    try interpreter.interpret();
    
    // Verify contract was deployed and address was stored
    const stored_address = evm_instance.get_storage(Address{0x01} ** 20, 0);
    try std.testing.expect(stored_address != 0);
}

test "CREATE real scenario - factory pattern deployment" {
    const allocator = std.testing.allocator;
    
    var memory_db = memory_database.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Factory deploys multiple identical contracts
    const template_init_code = [_]u8{
        // Simple contract that stores deployer address
        0x33,       // CALLER
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (store caller at slot 0)
        
        // Return runtime code
        0x60, 0x10, // PUSH1 16 (runtime code size)
        0x60, 0x0C, // PUSH1 12 (runtime code offset)
        0xF3,       // RETURN
        
        // Runtime code (simplified)
        0x60, 0x00, 0x54, // PUSH1 0, SLOAD
        0x60, 0x00, 0x52, // PUSH1 0, MSTORE
        0x60, 0x20, 0x60, 0x00, 0xF3, // PUSH1 32, PUSH1 0, RETURN
    };
    
    // Deploy 3 instances
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Loop 3 times
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        // Store init code in memory
        for (template_init_code) |byte| {
            try bytecode.append(0x60); // PUSH1
            try bytecode.append(byte);
        }
        
        var offset: u8 = template_init_code.len - 1;
        while (offset > 0) : (offset -= 1) {
            try bytecode.append(0x60); // PUSH1
            try bytecode.append(offset);
            try bytecode.append(0x53); // MSTORE8
        }
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(0x00);
        try bytecode.append(0x53); // MSTORE8
        
        // CREATE
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(template_init_code.len));
        try bytecode.append(0x60); // PUSH1 0
        try bytecode.append(0x00);
        try bytecode.append(0x60); // PUSH1 0
        try bytecode.append(0x00);
        try bytecode.append(0xF0); // CREATE
        
        // Store address in storage slot i+1
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(i + 1);  // slot
        try bytecode.append(0x55); // SSTORE
    }
    
    try bytecode.append(0x00); // STOP
    
    const FrameInterpreterType = frame_interpreter.FrameInterpreter(.{ .has_database = true });
    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 10_000_000, db_interface, null);
    defer interpreter.deinit(allocator);
    
    var evm_instance = try evm.Evm(evm.DefaultEvmConfig).init(
        allocator,
        db_interface,
        block_info.DefaultBlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address{0} ** 20,
            .base_fee = 1_000_000_000,
            .prev_randao = [_]u8{0} ** 32,
        },
        transaction_context.TransactionContext{
            .nonce = 0,
            .gas_price = 20_000_000_000,
            .gas_limit = 10_000_000,
            .to = null,
            .value = 0,
            .data = &[_]u8{},
            .chain_id = 1,
            .origin = Address{0x01} ** 20,
            .blob_hashes = &[_][32]u8{},
            .max_fee_per_blob_gas = null,
        },
        20_000_000_000,
        Address{0x01} ** 20,
        .CANCUN,
    );
    defer evm_instance.deinit();
    
    interpreter.frame.host = evm_instance.to_host();
    interpreter.frame.contract_address = Address{0x01} ** 20;
    
    // Execute factory deployment
    try interpreter.interpret();
    
    // Verify 3 contracts were deployed
    const addr1 = evm_instance.get_storage(Address{0x01} ** 20, 1);
    const addr2 = evm_instance.get_storage(Address{0x01} ** 20, 2);
    const addr3 = evm_instance.get_storage(Address{0x01} ** 20, 3);
    
    try std.testing.expect(addr1 != 0);
    try std.testing.expect(addr2 != 0);
    try std.testing.expect(addr3 != 0);
    try std.testing.expect(addr1 != addr2);
    try std.testing.expect(addr2 != addr3);
}
